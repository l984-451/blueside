import json
import math
import os
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(os.environ.get("CHARTPIPE_SMALL_RUN") != "1", reason="needs GDAL and network")

WORK = Path(os.environ.get("CHARTPIPE_TEST_WORK", "/work/small"))
AIRPORTS = {"KDFW": (32.8968, -97.0380), "KHOU": (29.6454, -95.2789), "KAUS": (30.1945, -97.6699)}


def tile_xy(lat, lon, zoom):
    """Tile column and row as fractions, so the pixel inside the tile is known too."""
    n = 2**zoom
    return (lon + 180) / 360 * n, (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n


def tile_bytes(pmtiles, zoom, x, y):
    result = subprocess.run(["pmtiles", "tile", str(pmtiles), str(zoom), str(x), str(y)], capture_output=True)
    return result.stdout if result.returncode == 0 and result.stdout[:4] == b"RIFF" else None


def has_tile(pmtiles, zoom, lat, lon):
    x, y = tile_xy(lat, lon, zoom)
    return tile_bytes(pmtiles, zoom, int(x), int(y)) is not None


def zooms(pmtiles):
    header = json.loads(subprocess.run(["pmtiles", "show", "--header-json", str(pmtiles)],
                                       check=True, capture_output=True, text=True).stdout)
    return header["minzoom"], header["maxzoom"]


def transparent_rows(pmtiles, lon, north, south, zoom=12):
    """Pixels with no chart in the one-pixel column at lon between two latitudes. A missing tile counts as 256."""
    from osgeo import gdal
    gdal.UseExceptions()
    fx, top = tile_xy(north, lon, zoom)
    bottom = tile_xy(south, lon, zoom)[1]
    column, count = int((fx % 1) * 256), 0
    for y in range(int(top) + 1, int(bottom)):
        data = tile_bytes(pmtiles, zoom, int(fx), y)
        if data is None:
            count += 256
            continue
        gdal.FileFromMemBuffer("/vsimem/tile.webp", data)
        tile = gdal.Open("/vsimem/tile.webp")
        # A tile stored without an alpha band is opaque everywhere.
        if tile.RasterCount == 4:
            count += int((tile.GetRasterBand(4).ReadAsArray()[:, column] == 0).sum())
        tile = None
        gdal.Unlink("/vsimem/tile.webp")
    return count


@pytest.fixture(scope="module")
def run():
    from chartpipe import faa
    editions = faa.parse_editions(faa.fetch(faa.VFR_PAGE).decode("utf-8", "replace"))
    cycle = sorted(editions)[0]
    result = subprocess.run(["python3", "-m", "chartpipe", "--work", str(WORK), "--no-publish", "--cycle", cycle,
                             "--only", "enr_l17,enr_l19,enr_a02"], check=True, stdout=subprocess.PIPE, text=True)
    return WORK / "out" / cycle, result.stdout


def test_frames_are_found_or_taken_from_the_hand_entered_list(run):
    log = run[1]
    assert "outline ENR_L17.tif: detected (4196, 256, 21805, 7745)" in log
    assert "outline ENR_L19.tif: detected (2196, 256, 21805, 7745)" in log
    assert "outline ENR_A02_DFW.tif: override (116, 197, 5884, 7804)" in log
    assert "FALLBACK" not in log


def test_texas_pack_covers_three_airports_at_full_detail(run):
    for lat, lon in AIRPORTS.values():
        assert has_tile(run[0] / "ifr-low" / "TX.pmtiles", 12, lat, lon)


def test_no_transparent_rows_where_the_two_sheets_meet(run):
    # The sheets meet near 32 north, from 101 west to 93.5 west. Every pixel down these columns must hold chart.
    low = run[0] / "ifr-low" / "TX.pmtiles"
    assert [transparent_rows(low, lon, 33.0, 31.0) for lon in (-100.5, -97.47, -95.0)] == [0, 0, 0]


def test_the_join_measure_counts_transparent_pixels_inside_a_tile(run):
    # The lower sheet ends near 28.9 north here. A whole missing tile adds 256, so a remainder
    # shows that pixels were counted inside a tile too.
    count = transparent_rows(run[0] / "ifr-low" / "TX.pmtiles", -97.47, 29.4, 28.4)
    assert count > 0 and count % 256 != 0


def test_area_layer_holds_zoom_13_around_dfw_only(run):
    area = run[0] / "ifr-area" / "TX.pmtiles"
    assert has_tile(area, 13, *AIRPORTS["KDFW"])
    assert not has_tile(area, 13, *AIRPORTS["KHOU"])
    assert zooms(area) == (13, 13)


def test_low_layer_and_its_overview_have_the_right_zooms(run):
    assert zooms(run[0] / "ifr-low" / "TX.pmtiles") == (4, 12)
    assert zooms(run[0] / "ifr-low" / "overview.pmtiles") == (4, 7)
