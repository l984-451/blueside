import json
import math
import os
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(os.environ.get("CHARTPIPE_SMALL_RUN") != "1", reason="needs GDAL and network")

WORK = Path(os.environ.get("CHARTPIPE_TEST_WORK", "/work/small"))
AIRPORTS = {"KDFW": (32.8968, -97.0380), "KHOU": (29.6454, -95.2789)}


def tile_at(lat, lon, zoom):
    n = 2**zoom
    x = int((lon + 180) / 360 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return x, y


def has_tile(pmtiles, zoom, x, y):
    result = subprocess.run(["pmtiles", "tile", str(pmtiles), str(zoom), str(x), str(y)], capture_output=True)
    return result.returncode == 0 and result.stdout[:4] == b"RIFF"


@pytest.fixture(scope="module")
def packs():
    from chartpipe import faa
    editions = faa.parse_editions(faa.fetch(faa.VFR_PAGE).decode("utf-8", "replace"))
    cycle = sorted(editions)[0]
    subprocess.run(["python3", "-m", "chartpipe", "--work", str(WORK), "--no-publish", "--cycle", cycle,
                    "--only", "Dallas-Ft_Worth,Houston,Dallas-Ft_Worth_TAC"], check=True)
    return WORK / "out" / cycle


def test_texas_pack_covers_both_airports_at_full_detail(packs):
    for lat, lon in AIRPORTS.values():
        assert has_tile(packs / "vfr" / "TX.pmtiles", 12, *tile_at(lat, lon, 12))


def test_terminal_layer_covers_dfw_only(packs):
    tac = packs / "vfr-tac" / "TX.pmtiles"
    assert has_tile(tac, 13, *tile_at(*AIRPORTS["KDFW"], 13))
    assert not has_tile(tac, 13, *tile_at(*AIRPORTS["KHOU"], 13))


def test_no_gap_where_the_two_sectionals_meet(packs):
    # The charts overlap between 31.8 and 32.4 north. Every tile across that band must exist.
    y = tile_at(32.1, -96.0, 12)[1]
    x_from, x_to = tile_at(32.1, -96.9, 12)[0], tile_at(32.1, -95.0, 12)[0]
    missing = [x for x in range(x_from, x_to + 1) if not has_tile(packs / "vfr" / "TX.pmtiles", 12, x, y)]
    assert missing == []


def test_overview_stops_at_zoom_7(packs):
    header = json.loads(subprocess.run(["pmtiles", "show", "--header-json", str(packs / "vfr" / "overview.pmtiles")],
                                       check=True, capture_output=True, text=True).stdout)
    assert (header["minzoom"], header["maxzoom"]) == (4, 7)


def test_only_states_with_tiles_get_a_pack(packs):
    states = sorted(p.stem for p in (packs / "vfr").glob("*.pmtiles") if p.stem != "overview")
    # Zoom 4 tiles from these charts reach as far as Utah; only states with zoom 12 tiles count.
    assert states == ["LA", "MS", "OK", "TX"]
