"""Helpers shared by the nav tests."""
import csv
import json
import shutil
import sqlite3
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from navpipe import navdb

FIXTURES = Path(__file__).parent / "fixtures" / "nav"
BUILT_AT = datetime(2026, 10, 13, 4, 0, tzinfo=timezone.utc)
TOOLS = ("tippecanoe", "tippecanoe-decode", "ogr2ogr", "pmtiles")
AIRSPACE_FIELDS = ("IDENT", "NAME", "CLASS", "LOCAL_TYPE", "UPPER_VAL", "UPPER_UOM", "UPPER_CODE", "LOWER_VAL",
                   "LOWER_UOM", "LOWER_CODE", "UPPER_DESC", "LOWER_DESC", "SECTOR", "WKHR_CODE")


def database(folder: Path, changes: dict | None = None, *extra) -> sqlite3.Connection:
    """Build from the fixture tables. changes maps a table name to a function over its rows."""
    tables = folder / "csv"
    shutil.copytree(FIXTURES / "csv", tables)
    for table, change in (changes or {}).items():
        with open(tables / f"{table}.csv", newline="", encoding="latin-1") as handle:
            reader = csv.DictReader(handle)
            fields, rows = reader.fieldnames, list(reader)
        with open(tables / f"{table}.csv", "w", newline="", encoding="latin-1") as handle:
            writer = csv.DictWriter(handle, fields, quoting=csv.QUOTE_ALL)
            writer.writeheader()
            writer.writerows(change(rows))
    navdb.build(tables, folder / "nav.sqlite", "2026-10-01", BUILT_AT, "2026-09-28T13:54:26Z", *extra)
    return sqlite3.connect(folder / "nav.sqlite")


def square(west: float, south: float, size: float) -> dict:
    ring = [[west, south], [west + size, south], [west + size, south + size], [west, south + size], [west, south]]
    return {"type": "Polygon", "coordinates": [ring]}


def shapefile(folder: Path, shapes: list[tuple[dict, dict]]) -> Path:
    """A Class_Airspace shapefile from (attributes, geometry) pairs. An attribute left out is null."""
    features = [{"type": "Feature", "geometry": geometry,
                 "properties": {field: attributes.get(field) for field in AIRSPACE_FIELDS}}
                for attributes, geometry in shapes]
    source = folder / "in.geojson"
    source.write_text(json.dumps({"type": "FeatureCollection", "features": features}))
    target = folder / "shp"
    target.mkdir()
    subprocess.run(["ogr2ogr", "-f", "ESRI Shapefile", str(target / "Class_Airspace.shp"), str(source),
                    "-nln", "Class_Airspace"], check=True)
    return target / "Class_Airspace.shp"


def lines(path: Path, features: list[dict]) -> Path:
    """One GeoJSON feature per line, the form the tile builder reads."""
    path.write_text("".join(json.dumps(feature) + "\n" for feature in features))
    return path
