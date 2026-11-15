#!/usr/bin/python3
"""Compresses files into a tar.gz archive and reports the progress.

The progress is written to stdout as a line per change:

    PROGRESS <bytes-done> <bytes-total>

The source is read in chunks, so the number of source bytes that have been
handled is known at any moment — even for a single large file, which the
`tar` command cannot report on until the whole file has been read.

This is the standard library only, so it runs on every Mac.
"""

import os
import sys
import tarfile


CHUNK = 1024 * 1024


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


class CountingReader(object):
    """Wraps a file and counts the bytes that have been read from it."""

    def __init__(self, source, done, total, state):
        self.source = source
        self.done = done
        self.total = total
        self.state = state

    def read(self, size=-1):
        chunk = self.source.read(size)
        if chunk:
            self.done[0] += len(chunk)
            report(self.done[0], self.total, self.state)
        return chunk


def main():
    if len(sys.argv) < 3:
        print("usage: progress_tar.py <archive> <file> [file...]", file=sys.stderr)
        return 2

    archive = sys.argv[1]
    items = sys.argv[2:]

    entries = collect_files(items)
    total = 0
    for full, _ in entries:
        try:
            total += os.path.getsize(full)
        except OSError:
            pass

    done = [0]
    state = {"percent": -1}

    with tarfile.open(archive, "w:gz") as tar:
        for full, name in entries:
            try:
                source = open(full, "rb")
            except OSError as error:
                print("skip %s: %s" % (full, error), file=sys.stderr)
                continue

            info = tarfile.TarInfo(name=name)
            try:
                info.size = os.path.getsize(full)
            except OSError:
                info.size = 0
            info.mode = 0o644

            # The file is added through the counting reader, so the number of
            # bytes that have been handled is known while it is written.
            reader = CountingReader(source, done, total, state)
            tar.addfile(info, reader)
            source.close()

    report(total, total, state)
    print("PROGRESS %d %d" % (total, total), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
