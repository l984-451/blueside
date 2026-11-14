import json
import shutil
from pathlib import Path

import pytest

from chartpipe import __main__ as cli
from chartpipe import pack

FIXTURE = Path(__file__).parent / "fixtures" / "street-dallas.pmtiles"
pytestmark = pytest.mark.skipif(not (shutil.which("pmtiles") and shutil.which("ogr2ogr")), reason="needs pmtiles and ogr2ogr")


def box(code, west, south, east, north):
    ring = [[west, south], [east, south], [east, north], [west, north], [west, south]]
    return {"type": "Feature", "properties": {"STUSPS": code}, "geometry": {"type": "Polygon", "coordinates": [ring]}}


def test_a_street_pack_is_cut_for_each_state_the_planet_covers(monkeypatch, tmp_path):
    states = tmp_path / "states.geojson"
    states.write_text(json.dumps({"type": "FeatureCollection",
                                  "features": [box("TX", -98, 32, -96, 34), box("AL", -88, 31, -85, 35)]}))
    monkeypatch.setattr(cli, "STATES", states)
    monkeypatch.setattr(pack, "STATE_CODES", ["AL", "TX"])
    packs = cli.cut_packs("street", FIXTURE, (0, 6), tmp_path / "out", tmp_path)
    # The fixture holds Dallas only, so Alabama gets no pack.
    assert [(p["layer"], p["region"]) for p in packs] == [("street", "TX")]
    assert pack.zoom_range(tmp_path / "out" / "street" / "TX.pmtiles") == (0, 6)
    assert not (tmp_path / "out" / "street" / "AL.pmtiles").exists()
