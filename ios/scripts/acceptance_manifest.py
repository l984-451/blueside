#!/usr/bin/env python3
"""Writes manifest.json for a folder laid out as charts/<cycle>/<layer>/<region>.pmtiles.

usage: acceptance_manifest.py <folder> [--prefix slow/]
Two rows are added that cannot succeed, so the download list can show its failure states:
region XX is a real file with a hash it cannot match, region ZZ claims more room than any device has.
"""
import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "pipeline"))
from chartpipe import manifest  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("folder")
parser.add_argument("--prefix", default="")
args = parser.parse_args()


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


now = datetime.now(timezone.utc)
result = None
charts = os.path.join(args.folder, "charts")
for cycle in sorted(os.listdir(charts)):
    packs = []
    for layer in sorted(os.listdir(os.path.join(charts, cycle))):
        for name in sorted(os.listdir(os.path.join(charts, cycle, layer))):
            if name.endswith(".pmtiles"):
                path = os.path.join(charts, cycle, layer, name)
                packs.append({"layer": layer, "region": name[:-len(".pmtiles")],
                              "bytes": os.path.getsize(path), "sha256": sha256(path)})
    result = manifest.merge(result, manifest.cycle_entry(cycle, packs), now)

if not result or not result["cycles"]:
    sys.exit("no cycle in %s is still in effect" % charts)
for cycle in result["cycles"]:
    for pack in cycle["packs"]:
        pack["path"] = args.prefix + pack["path"]
first = result["cycles"][0]
# The smallest real file under a path of its own, so the checksum fails twice and quickly.
small = min(first["packs"], key=lambda p: p["bytes"])
first["packs"].append({"layer": "vfr", "region": "XX", "path": "once/" + small["path"][len(args.prefix):],
                       "bytes": small["bytes"], "sha256": "0" * 64})
first["packs"].append({"layer": "vfr", "region": "ZZ", "path": args.prefix + "charts/missing-ZZ.pmtiles",
                       "bytes": 9_000_000_000_000_000, "sha256": "0" * 64})
with open(os.path.join(args.folder, "manifest.json"), "w") as f:
    json.dump(result, f, indent=1)
print("wrote manifest with", sum(len(c["packs"]) for c in result["cycles"]), "packs")
