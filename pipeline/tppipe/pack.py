import json
import re
import sqlite3
import zlib
from pathlib import Path

from tppipe import diagram, geo

_PAGE = re.compile(rb"/Type\s*/Page(?![a-zA-Z])")
_OBJSTM = re.compile(rb"<<[^<>]*/Type\s*/ObjStm[^<>]*>>\s*stream\r?\n")


def page_count(pdf: bytes) -> int:
    """Page objects in the file, including those packed in compressed object streams."""
    count = len(_PAGE.findall(pdf))
    for match in _OBJSTM.finditer(pdf):
        try:
            count += len(_PAGE.findall(zlib.decompressobj().decompress(pdf[match.end():])))
        except zlib.error:
            pass
    return max(count, 1)


def build(charts: list[dict], files: dict[str, Path], out: Path, cycle_id: str,
          runways: dict[str, list] | None = None, report: list | None = None) -> int:
    """Write one state's pack: every PDF once, plus the JSON index in meta. Returns the chart count.
    Airport diagrams are placed from their printed graticule, checked against runways; report gets
    (airport, file, outcome, runway miss in meters) for each."""
    diagrams = {c["file"]: c["airport"] for c in charts if c["code"] == "APD"}
    out.unlink(missing_ok=True)
    db = sqlite3.connect(out)
    db.executescript("CREATE TABLE meta (name TEXT PRIMARY KEY, value TEXT);"
                     "CREATE TABLE pdfs (file TEXT PRIMARY KEY, data BLOB NOT NULL);")
    pages, geos = {}, {}
    for name in sorted({c["file"] for c in charts}):
        data = files[name].read_bytes()
        if not data.startswith(b"%PDF"):
            db.close()
            out.unlink()
            raise ValueError(f"{name} is not a PDF")
        pages[name] = page_count(data)
        if name in diagrams:
            geos[name], outcome, miss = diagram.georef(files[name], (runways or {}).get(diagrams[name], []))
            if report is not None:
                report.append((diagrams[name], name, outcome, miss))
        else:
            geos[name] = geo.georef(data)
        db.execute("INSERT INTO pdfs VALUES (?, ?)", (name, data))
    index = [{**c, "pages": pages[c["file"]], **({"geo": geos[c["file"]]} if geos[c["file"]] else {})} for c in charts]
    db.executemany("INSERT INTO meta VALUES (?, ?)",
                   [("cycle", cycle_id), ("index", json.dumps(index, separators=(",", ":")))])
    db.commit()
    db.execute("VACUUM")
    db.close()
    return len(index)
