#!/usr/bin/env python3
"""Writes nav/manifest.json for a folder laid out as nav/<cycle>/nav.sqlite and nav.pmtiles.

usage: nav_manifest.py <folder>
Cycle dates are read from each database. nav/bad-manifest.json lists the same files with a
database hash that cannot match, so a checksum failure can be shown. nav/old-manifest.json
lists one small cycle that ended on 1 October 2026, so an expired pack can be shown.
"""
import copy
import hashlib
import json
import os
import shutil
import sqlite3
import sys

folder = sys.argv[1]
nav = os.path.join(folder, "nav")
FILES = (("nav-db", "nav.sqlite"), ("nav-tiles", "nav.pmtiles"))


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def entry(top, cycle):
    """One cycle of the list, or None when either file is missing. Dates come from the database."""
    paths = [os.path.join(folder, top, cycle, name) for _, name in FILES]
    if not all(os.path.isfile(path) for path in paths):
        return None
    db = sqlite3.connect("file:%s?mode=ro" % paths[0], uri=True)
    meta = dict(db.execute("SELECT key, value FROM meta"))
    db.close()
    packs = [{"layer": layer, "region": "US", "path": "%s/%s/%s" % (top, cycle, name),
              "bytes": os.path.getsize(path), "sha256": sha256(path)}
             for (layer, name), path in zip(FILES, paths)]
    return {"id": cycle, "effective": meta["effective"], "expires": meta["expires"], "packs": packs}


def write(name, cycles):
    with open(os.path.join(nav, name), "w") as f:
        json.dump({"version": 1, "cycles": cycles}, f, indent=1)


names = sorted(os.listdir(nav)) if os.path.isdir(nav) else []
cycles = [found for found in (entry("nav", name) for name in names) if found]
if not cycles:
    sys.exit("no navigation files under %s" % nav)
bad = copy.deepcopy(cycles)
for cycle in bad:
    cycle["packs"][0]["sha256"] = "0" * 64
write("manifest.json", cycles)
write("bad-manifest.json", bad)

# The past cycle is the small bundled files with the dates in the database moved back one cycle.
assets = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "MapAssets")
past = {"cycle": "2026-09-03", "effective": "2026-09-03T09:01:00Z", "expires": "2026-10-01T09:01:00Z"}
old = os.path.join(folder, "nav-old", past["cycle"])
os.makedirs(old, exist_ok=True)
shutil.copyfile(os.path.join(assets, "nav-test.sqlite"), os.path.join(old, "nav.sqlite"))
shutil.copyfile(os.path.join(assets, "nav-tiles.pmtiles"), os.path.join(old, "nav.pmtiles"))
db = sqlite3.connect(os.path.join(old, "nav.sqlite"))
for key, value in past.items():
    db.execute("UPDATE meta SET value = ? WHERE key = ?", (value, key))
db.commit()
db.close()
write("old-manifest.json", [entry("nav-old", past["cycle"])])

# A current cycle whose database carries a schema number the app does not read.
refused = os.path.join(folder, "nav-refused", "2026-10-01")
os.makedirs(refused, exist_ok=True)
shutil.copyfile(os.path.join(assets, "nav-test.sqlite"), os.path.join(refused, "nav.sqlite"))
shutil.copyfile(os.path.join(assets, "nav-tiles.pmtiles"), os.path.join(refused, "nav.pmtiles"))
db = sqlite3.connect(os.path.join(refused, "nav.sqlite"))
db.execute("UPDATE meta SET value = '2' WHERE key = 'schema_version'")
db.commit()
db.close()
write("refused-manifest.json", [entry("nav-refused", "2026-10-01")])
# The chart list without the two regions that exist only to fail, for pictures.
with open(os.path.join(folder, "manifest.json")) as f:
    charts = json.load(f)
for cycle in charts["cycles"]:
    cycle["packs"] = [pack for pack in cycle["packs"] if pack["region"] not in ("XX", "ZZ")]
with open(os.path.join(folder, "clean-manifest.json"), "w") as f:
    json.dump(charts, f, indent=1)
print("wrote nav manifest with", len(cycles), "cycle(s) and one past cycle")
