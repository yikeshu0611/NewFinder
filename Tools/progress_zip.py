#!/usr/bin/python3
"""Compresses files into a zip archive and reports the progress.

The progress is written to stdout as a line per change:

    PROGRESS <bytes-done> <bytes-total>

The state of every single file is written as a line of its own:

    FILE <name> <original-bytes> <compressed-bytes>

    FILEPROGRESS <name> <bytes-done> <compressed-bytes>

The first line of a file is sent when the file is started, so the window
can show the list of files right away. The second line is sent as the file
is being read, so the window can show how far along each file is.

The source is read in chunks and the archive is written the same way, so
the number of source bytes that have been handled is known at any moment —
even for a single large file, which the `zip` command cannot report on
until the whole file has been read.

The number of bytes the entry takes in the archive is counted while the
entry is written, so the window can show how well the file compresses
before it is finished.

The files are compressed side by side. Each file is deflated by its own
worker, which reads the source and compresses it into a temporary file,
while the archive itself is written by the main thread in the order the
files were given. That way the archive is a normal zip file, but the work
is spread over several cores. The temporary files keep the memory use
small, because the compressed bytes do not all sit in memory at once.

The archive is written here rather than with the `zipfile` module, because
that module compresses and writes one entry at a time, and because it
cannot take bytes that are already compressed. The format that is written
here is the ordinary zip format, so any program can read the result.

This is the standard library only, so it runs on any Mac.
"""

import os
import queue
import signal
import struct
import sys
import tempfile
import threading
import time
import zipfile
import zlib

CHUNK = 1024 * 1024

# The temporary files that hold the compressed bytes. They are removed
# when the work is over, and also when the work is stopped.
temp_files = []


def remove_temp_files():
    """Removes the temporary files that hold the compressed bytes."""
    while temp_files:
        path = temp_files.pop()
        try:
            os.remove(path)
        except OSError:
            pass


def stop_work(signum, frame):
    """Cleans up when the work is stopped, and leaves."""
    remove_temp_files()
    sys.exit(143)


# The signature that marks the start of a local file header.
LOCAL_SIGNATURE = 0x04034B50
# The signature that marks the start of a central directory record.
CENTRAL_SIGNATURE = 0x02014B50
# The signature that marks the end of the central directory.
END_SIGNATURE = 0x06054B50
# The signature that marks the bigger end of the central directory.
END64_SIGNATURE = 0x06064B50
# The signature that marks the place where the bigger end is found.
END64_LOCATOR_SIGNATURE = 0x07064B50

# The version that is needed to read the entries. Version 2.0 is the one
# that introduced deflate.
VERSION = 20
# The version that is needed for the bigger form of the format.
VERSION64 = 45
# The version that made the zip file, which is 2.0 for deflate.
CREATED_BY = 0x031E

# The biggest number that fits in the small form of the format.
LIMIT32 = 0xFFFFFFFF


def dos_time(date_time):
    """Turns a date and a time into the pair of numbers a zip file uses."""
    year, month, day, hour, minute, second = date_time
    # The zip format counts the years from 1980, so anything older is
    # treated as 1980.
    if year < 1980:
        year = 1980
    return (
        ((hour << 11) | (minute << 5) | (second // 2)),
        (((year - 1980) << 9) | (month << 5) | day),
    )


def needs_zip64(compressed_size, file_size, offset=0):
    """True when the numbers are too big for the small form of the format."""
    return compressed_size > LIMIT32 or file_size > LIMIT32 or offset > LIMIT32


def local_header(name_bytes, crc, compressed_size, file_size, date_time,
                 use_zip64=False):
    """The header that comes before the data of one entry.

    The file is compressed before it is written, so the sizes and the
    checksum are known and can go straight into the header. That keeps the
    archive simple, with no descriptor after the data.
    """
    time_value, date_value = dos_time(date_time)
    # A name that is not plain ASCII needs the flag that says the name is
    # written in UTF-8. Without it the name comes out garbled.
    flags = 0x0800 if not name_bytes.isascii() else 0x00
    method = zipfile.ZIP_DEFLATED
    extra = b""
    version = VERSION
    if use_zip64:
        # The real sizes go into the extra field, and the small fields
        # are filled with the biggest number they can hold.
        extra = struct.pack("<HHQQ", 0x0001, 16, file_size, compressed_size)
        version = VERSION64

    # The header is written field by field, so it is clear which number
    # belongs where. The layout is the one the zip format describes.
    header = struct.pack("<I", LOCAL_SIGNATURE)
    # The version needed to read the entry, the flags and the method.
    header += struct.pack("<HHH", version, flags, method)
    # The time the entry was made.
    header += struct.pack("<HH", time_value, date_value)
    # The checksum and the two sizes.
    if use_zip64:
        header += struct.pack("<III", crc, LIMIT32, LIMIT32)
    else:
        header += struct.pack("<III", crc, compressed_size, file_size)
    # The length of the name and of the extra field.
    header += struct.pack("<HH", len(name_bytes), len(extra))
    return header + name_bytes + extra


def central_record(name_bytes, crc, compressed_size, file_size, date_time,
                   offset, use_zip64=False):
    """The record of one entry in the central directory."""
    time_value, date_value = dos_time(date_time)
    # The flag has to be the same as the one in the local header.
    flags = 0x0800 if not name_bytes.isascii() else 0x00
    method = zipfile.ZIP_DEFLATED
    extra = b""
    version = VERSION
    if use_zip64:
        # The real sizes and the real place go into the extra field, and
        # the small fields are filled with the biggest number they hold.
        extra = struct.pack("<HHQQQ", 0x0001, 24, file_size, compressed_size, offset)
        version = VERSION64

    # The record is written field by field, so it is clear which number
    # belongs where. The layout is the one the zip format describes.
    record = struct.pack("<I", CENTRAL_SIGNATURE)
    # The version that made the file, and the version needed to read it.
    record += struct.pack("<HH", CREATED_BY, version)
    # The flags, the way the data is stored and the time it was made.
    record += struct.pack("<HHH", flags, method, time_value)
    record += struct.pack("<H", date_value)
    # The checksum and the two sizes.
    if use_zip64:
        record += struct.pack("<III", crc, LIMIT32, LIMIT32)
    else:
        record += struct.pack("<III", crc, compressed_size, file_size)
    # The length of the name, of the extra field and of the comment.
    record += struct.pack("<HHH", len(name_bytes), len(extra), 0)
    # The disk the entry starts on, and the two attributes.
    record += struct.pack("<HH", 0, 0)
    record += struct.pack("<I", 0o644 << 16)
    # The place the entry starts in the archive.
    if use_zip64:
        record += struct.pack("<I", LIMIT32)
    else:
        record += struct.pack("<I", offset)
    return record + name_bytes + extra


def end_of_directory(count, directory_size, directory_offset, comment=b"",
                     use_zip64=False):
    """The record that closes the central directory.

    When the numbers are too big for the small form, a bigger record is
    written before it, and the small one points at it.
    """
    if use_zip64:
        bigger = struct.pack(
            "<IQHHIIQQQQ",
            END64_SIGNATURE,
            44,  # The size of this record, without the first eight bytes.
            CREATED_BY,
            VERSION64,
            0,
            0,
            count,
            count,
            directory_size,
            directory_offset,
        )
        # The small record that says where the bigger one is.
        locator = struct.pack(
            "<IIQI",
            END64_LOCATOR_SIGNATURE,
            0,
            directory_offset + directory_size,
            1,
        )
        # The small record, with the numbers that are still small enough.
        small = struct.pack(
            "<IHHHHIIH",
            END_SIGNATURE,
            0,
            0,
            min(count, 0xFFFF),
            min(count, 0xFFFF),
            min(directory_size, LIMIT32),
            min(directory_offset, LIMIT32),
            len(comment),
        )
        return bigger + locator + small + comment

    return (
        struct.pack(
            "<IHHHHIIH",
            END_SIGNATURE,
            0,
            0,
            count,
            count,
            directory_size,
            directory_offset,
            len(comment),
        )
        + comment
    )


def collect_files(items):
    """The files to compress, with the name each one gets in the archive."""
    entries = []
    for item in items:
        if os.path.isdir(item):
            base = os.path.basename(item.rstrip("/"))
            for root, dirs, files in os.walk(item):
                dirs.sort()
                for name in sorted(files):
                    full = os.path.join(root, name)
                    rel = os.path.relpath(full, item)
                    entries.append((full, os.path.join(base, rel)))
        else:
            entries.append((item, os.path.basename(item)))
    return entries


def report(done, total, state):
    """Prints the progress when the percentage has changed."""
    percent = int(done * 100 / total) if total else 100
    if percent != state["percent"]:
        state["percent"] = percent
        print("PROGRESS %d %d" % (done, total), flush=True)


def report_file(name, original, compressed):
    """Prints the state of one file in the archive."""
    print(
        "FILE %s %d %d" % (name, original, compressed),
        flush=True,
    )


def report_file_progress(name, done, original, compressed):
    """Prints how far along one file is, and how big it is in the archive.

    The four numbers are the bytes that have been read, the bytes the file
    had before it was compressed and the bytes it takes in the archive.
    """
    print(
        "FILEPROGRESS %s %d %d %d" % (name, done, original, compressed),
        flush=True,
    )


class Job:
    """One file that is being compressed.

    The worker fills in `compressed` as it goes and puts the compressed
    bytes in `temp_path`. The main thread takes them and writes them into
    the archive.
    """

    def __init__(self, full, name):
        self.full = full
        self.name = name
        self.original = 0
        self.compressed = 0
        self.done = 0
        self.crc = 0
        # Where the compressed bytes wait for the main thread.
        self.temp_path = None
        # Set when the worker is finished with this file.
        self.finished = threading.Event()
        # Set when the worker hit a problem.
        self.error = None


def compress_job(job):
    """Deflates one file into a temporary file, and reports the progress."""
    try:
        job.original = os.path.getsize(job.full)
    except OSError:
        job.original = 0

    compressor = zlib.compressobj(6, zlib.DEFLATED, -zlib.MAX_WBITS)
    crc = 0
    last_reported = -1
    handle, path = tempfile.mkstemp(prefix="nfzip-", suffix=".part")
    job.temp_path = path
    temp_files.append(path)
    try:
        with os.fdopen(handle, "wb") as sink:
            with open(job.full, "rb") as source:
                while True:
                    chunk = source.read(CHUNK)
                    if not chunk:
                        break
                    crc = zlib.crc32(chunk, crc)
                    piece = compressor.compress(chunk)
                    if piece:
                        sink.write(piece)
                    job.done += len(chunk)
                    job.compressed += len(piece)

                    # The state of the file is sent every few percent, so
                    # the window does not have to be updated too often.
                    percent = int(job.done * 100 / job.original) if job.original else 100
                    if percent != last_reported:
                        last_reported = percent
                        report_file_progress(job.name, job.done, job.original, job.compressed)

            # The tail of the deflate stream has to be flushed.
            piece = compressor.flush()
            if piece:
                sink.write(piece)
                job.compressed += len(piece)
        job.crc = crc & 0xFFFFFFFF
    except Exception as error:  # noqa: BLE001 — the message goes to the log
        job.error = error
    finally:
        job.finished.set()


def worker_count(count):
    """How many workers to use for the given number of files."""
    if count <= 1:
        return 1
    cores = os.cpu_count() or 2
    # The main thread writes the archive, so a few workers are enough to
    # keep the cores busy without making the disk work harder.
    return max(2, min(count, cores, 8))


def run_worker(pending):
    """Takes jobs from the queue and compresses them, one after another."""
    while True:
        try:
            job = pending.get_nowait()
        except queue.Empty:
            return
        try:
            compress_job(job)
        finally:
            pending.task_done()


def write_entry(archive, job, done, total, state):
    """Puts one finished file into the archive."""
    name_bytes = job.name.encode("utf-8")
    date_time = time.localtime()[:6]

    # A file that is bigger than four gigabytes needs the bigger form of
    # the format, which keeps the sizes in a separate part of the header.
    big = needs_zip64(job.compressed, job.original)

    offset = archive.tell()
    archive.write(
        local_header(
            name_bytes,
            job.crc,
            job.compressed,
            job.original,
            date_time,
            use_zip64=big,
        )
    )

    with open(job.temp_path, "rb") as source:
        while True:
            piece = source.read(CHUNK)
            if not piece:
                break
            archive.write(piece)
            done += len(piece)
            report(done, total, state)

    return done, offset, name_bytes, date_time, big


def main():
    if len(sys.argv) < 3:
        print("usage: progress_zip.py <archive> <file> [file...]", file=sys.stderr)
        return 2

    # When the work is stopped, the temporary files are removed first, so
    # they do not stay behind in the temporary folder.
    signal.signal(signal.SIGTERM, stop_work)
    signal.signal(signal.SIGINT, stop_work)

    archive_path = sys.argv[1]
    items = sys.argv[2:]

    entries = collect_files(items)
    total = 0
    for full, _ in entries:
        try:
            total += os.path.getsize(full)
        except OSError:
            pass

    done = 0
    state = {"percent": -1}

    # The name of the file and how big it is, sent before the work starts,
    # so the window can draw the whole list at once.
    for full, name in entries:
        try:
            size = os.path.getsize(full)
        except OSError:
            size = 0
        report_file(name, size, 0)

    jobs = [Job(full, name) for full, name in entries]

    # The workers take the jobs from this queue. The queue is filled with
    # the files in order, so the archive keeps that order too.
    pending = queue.Queue()
    for job in jobs:
        pending.put(job)

    workers = worker_count(len(jobs))
    threads = []
    for _ in range(workers):
        thread = threading.Thread(target=run_worker, args=(pending,), daemon=True)
        thread.start()
        threads.append(thread)

    records = []
    try:
        with open(archive_path, "wb") as archive:
            for job in jobs:
                # The file is compressed by a worker, so the main thread
                # waits for it and then writes it into the archive.
                job.finished.wait()
                if job.error is not None:
                    print("skip %s: %s" % (job.full, job.error), file=sys.stderr)
                    continue

                done, offset, name_bytes, date_time, big = write_entry(
                    archive, job, done, total, state
                )

                # The entry is closed, so its real size in the archive is
                # known. The `compress_size` is the number of bytes the
                # entry takes in the archive, while `file_size` is the
                # size of the file before it was compressed.
                report_file(job.name, job.original, job.compressed)
                records.append((name_bytes, job, offset, date_time, big))

            # The central directory comes after all the entries, and it
            # holds one record for each of them.
            directory_offset = archive.tell()
            directory = []
            for name_bytes, job, offset, date_time, big in records:
                directory.append(
                    central_record(
                        name_bytes,
                        job.crc,
                        job.compressed,
                        job.original,
                        date_time,
                        offset,
                        use_zip64=big,
                    )
                )
            directory_bytes = b"".join(directory)
            archive.write(directory_bytes)
            # The end of the archive needs the bigger form when any of
            # the numbers are too big for the small one.
            big_end = (
                len(directory) > 0xFFFF
                or len(directory_bytes) > LIMIT32
                or directory_offset > LIMIT32
            )
            archive.write(
                end_of_directory(
                    len(directory),
                    len(directory_bytes),
                    directory_offset,
                    use_zip64=big_end,
                )
            )
    finally:
        # Every worker is done, so the threads can end.
        for thread in threads:
            thread.join()
        # The temporary files are not needed any more.
        remove_temp_files()

    report(total, total, state)
    print("PROGRESS %d %d" % (total, total), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
