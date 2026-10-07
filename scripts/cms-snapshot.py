#!/usr/bin/env python3
"""Copy a stopped CMS data volume or restore its snapshot to a NEW directory."""
import argparse
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile


def snapshot(source: Path, destination: Path):
    source = source.resolve()
    destination = destination.resolve()
    if destination.exists():
        raise ValueError("Destination must not exist; existing data is never overwritten")
    if source == destination or source in destination.parents:
        raise ValueError("Destination must be outside the source directory")
    database = source / "aegis-content.db"
    if not database.is_file():
        raise ValueError("Source must contain aegis-content.db")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".cms-snapshot-", dir=destination.parent))
    try:
        with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as src:
            if src.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise ValueError("Source database failed integrity check")
            with sqlite3.connect(temporary / "aegis-content.db") as dst:
                src.backup(dst)
        if (source / "media").exists():
            shutil.copytree(source / "media", temporary / "media")
        else:
            (temporary / "media").mkdir()
        os.chmod(temporary / "aegis-content.db", 0o600)
        temporary.rename(destination)
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    snapshot(args.source, args.destination)
    print("Snapshot complete. Keep PAYLOAD_SECRET backed up separately and securely.")
