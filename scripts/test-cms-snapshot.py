#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import sqlite3
import tempfile

spec = importlib.util.spec_from_file_location("snapshot", Path(__file__).with_name("cms-snapshot.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    source = root / "source"
    source.mkdir()
    (source / "media").mkdir()
    (source / "media" / "sample.txt").write_text("fixture")
    with sqlite3.connect(source / "aegis-content.db") as db:
        db.execute("CREATE TABLE example (id INTEGER)")
        db.execute("INSERT INTO example VALUES (42)")
    module.snapshot(source, root / "backup")
    module.snapshot(root / "backup", root / "restored")
    with sqlite3.connect(root / "restored" / "aegis-content.db") as db:
        assert db.execute("SELECT id FROM example").fetchone() == (42,)
        assert db.execute("PRAGMA integrity_check").fetchone() == ("ok",)
    assert (root / "restored" / "media" / "sample.txt").read_text() == "fixture"
    try:
        module.snapshot(source, root / "restored")
        raise AssertionError("Must reject overwriting existing data")
    except ValueError:
        pass
print("CMS backup/restore passed: database, media and overwrite protection.")
