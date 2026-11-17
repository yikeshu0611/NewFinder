#!/usr/bin/python3
"""Extracts files from a zip archive and reports the progress.

The progress is written to stdout as a line per change:

    PROGRESS <bytes-done> <bytes-total>

The state of every single file is written as a line of its own:

    FILE <name> <original-bytes> <extracted-bytes>

    FILEPROGRESS <name> <bytes-done> <extracted-bytes>

The first line of a file is sent when the file is started, so the window
can show the list of files right away. The second line is sent as the file
is being written, so the window can show how far along each file is.

The list of the files and their sizes is read from the archive before
anything is written, so the window can draw the whole list at once.

Files that cannot be read — a zip that was cut short, or one whose
password is wrong — are skipped, and the ones that were read are still
left on disk. The archive that is being read is never overwritten.

This is the standard library only, so it runs on any Mac.
"""

import os
import sys
import zipfile

CHUNK = 1024 * 1024


def report(done, total, state):
    """Prints the progress when the percentage has changed."""
    percent = int(done * 100 / total) if total else 100
    if percent != state["percent"]:
        state["percent"] = percent
        print("PROGRESS %d %d" % (done, total), flush=True)


def report_file(name, original, extracted):
    """Prints the state of one file in the archive."""
    print(
        "FILE %s %d %d" % (name, original, extracted),
        flush=True,
    )


def report_file_progress(name, done, original, compressed):
    """Prints how far along one file is, and how big it is on disk.

    The four numbers are the bytes that have been read, the bytes the file
    had before it was compressed and the bytes it takes in the archive.
    """
    print(
        "FILEPROGRESS %s %d %d %d" % (name, done, original, compressed),
        flush=True,
    )


def safe_name(name):
    """Keeps the name of a file from escaping the folder it belongs in.

    A zip can hold a name like `../something`, and writing that outside
    the folder would be wrong. The parts that would climb out are dropped,
    and the rest of the path is kept, so the folders inside the archive
    are made again.
    """
    parts = []
    for part in name.replace("\\", "/").split("/"):
        if part in ("", ".", ".."):
            continue
        parts.append(part)
    return "/".join(parts) or name


def main():
    if len(sys.argv) < 3:
        print("usage: progress_unzip.py <archive> <folder> [password]", file=sys.stderr)
        return 2

    archive_path = sys.argv[1]
    destination = sys.argv[2]
    password = sys.argv[3] if len(sys.argv) > 3 else None

    try:
        zf = zipfile.ZipFile(archive_path, "r")
    except zipfile.BadZipFile as error:
        print("cannot read the archive: %s" % error, file=sys.stderr)
        return 3

    entries = zf.infolist()
    # Only the files count towards the progress; a folder has no bytes.
    files = [info for info in entries if not info.is_dir()]
    total = sum(info.file_size for info in files)

    done = 0
    state = {"percent": -1}

    # The name of every file and how big it is, sent before the work
    # starts, so the window can draw the whole list at once. The second
    # number is how big the file was before it was compressed, and the
    # third is how much of it the archive holds.
    for info in files:
        report_file(safe_name(info.filename), info.file_size, info.compress_size)

    os.makedirs(destination, exist_ok=True)

    for info in files:
        name = safe_name(info.filename)
        # The folders inside the archive are made again, so the files land
        # where they belong.
        target = os.path.join(destination, name)
        folder = os.path.dirname(target)
        if folder:
            os.makedirs(folder, exist_ok=True)
        original = info.file_size
        in_archive = info.compress_size
        written = 0
        last_reported = -1

        try:
            with zf.open(info, "r", pwd=password.encode() if password else None) as source:
                with open(target, "wb") as sink:
                    while True:
                        chunk = source.read(CHUNK)
                        if not chunk:
                            break
                        sink.write(chunk)
                        written += len(chunk)
                        done += len(chunk)

                        # The state of the file is sent every few percent,
                        # so the window does not have to be updated too
                        # often.
                        percent = int(written * 100 / original) if original else 100
                        if percent != last_reported:
                            last_reported = percent
                            report_file_progress(name, written, original, in_archive)
                        report(done, total, state)
        except (zipfile.BadZipFile, RuntimeError, OSError, NotImplementedError) as error:
            # A file that cannot be read — the archive was cut short, or
            # the password is wrong. The files that were read are kept.
            print("skip %s: %s" % (name, error), file=sys.stderr)
            continue

        report_file(name, original, in_archive)

    report(total, total, state)
    print("PROGRESS %d %d" % (total, total), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
