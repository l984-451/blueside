import array
import json
import shutil
import subprocess
from pathlib import Path

import pytest

from chartpipe import __main__ as cli
from chartpipe import faa, pack, terrain

gdal = pytest.importorskip("osgeo.gdal")
osr = pytest.importorskip("osgeo.osr")
needs_tools = pytest.mark.skipif(not (shutil.which("pmtiles") and shutil.which("ogr2ogr") and shutil.which("gdal")),
                                 reason="needs pmtiles, ogr2ogr and gdal")


def states(tmp_path, *boxes):
    def feature(code, parts):
        rings = [[[[w, s], [e, s], [e, n], [w, n], [w, s]]] for w, s, e, n in parts]
        return {"type": "Feature", "properties": {"STUSPS": code}, "geometry": {"type": "MultiPolygon", "coordinates": rings}}
    path = tmp_path / "states.geojson"
    path.write_text(json.dumps({"type": "FeatureCollection", "features": [feature(c, p) for c, p in boxes]}))
    return path


def dem(x, y, metres):
    """A 512 px zoom 10 source tile: a ramp up to metres from its west edge, sea on the west tenth."""
    size = 2 * 20037508.342789244 / 2 ** terrain.DEM_ZOOM
    west, north = -20037508.342789244 + x * size, 20037508.342789244 - y * size
    path = f"/vsimem/{x}_{y}.tif"
    ds = gdal.GetDriverByName("GTiff").Create(path, 512, 512, 1, gdal.GDT_Int16)
    ds.SetGeoTransform([west, size / 512, 0, north, 0, -size / 512])
    srs = osr.SpatialReference()
    srs.ImportFromEPSG(3857)
    ds.SetProjection(srs.ExportToWkt())
    row = array.array("h", [-50 if i < 51 else i * metres // 512 for i in range(512)])
    ds.GetRasterBand(1).WriteRaster(0, 0, 512, 512, bytes(row) * 512)
    ds = None
    data = gdal.VSIFOpenL(path, "rb")
    gdal.VSIFSeekL(data, 0, 2)
    length = gdal.VSIFTellL(data)
    gdal.VSIFSeekL(data, 0, 0)
    out = gdal.VSIFReadL(1, length, data)
    gdal.VSIFCloseL(data)
    gdal.Unlink(path)
    return out


def test_tiles_cover_each_part_with_a_margin_and_not_the_world_between(tmp_path):
    # Two islands either side of 180 must not become a box round the world.
    shp = states(tmp_path, ("AK", [(-150.1, 61.1, -150.0, 61.2), (179.5, 51.5, 179.6, 51.6)]))
    tiles = terrain.state_tiles(shp, "AK")
    assert len(tiles) < 30
    assert {x for x, _ in tiles} == {84, 85, 86, 1021, 1022, 1023}


def test_the_relief_scale_follows_latitude():
    # Rows 511 and 512 meet at the equator, where Mercator metres are ground metres; at 60 degrees they are half.
    assert terrain.relief_scale([Path("10/0/511.tif"), Path("10/0/512.tif")]) == pytest.approx(1 / terrain.EXAGGERATION)
    north = terrain.tile_range(0, 60, 0, 60, 10)[1].start
    assert terrain.relief_scale([Path(f"10/0/{north}.tif")]) == pytest.approx(0.5 / terrain.EXAGGERATION, rel=0.01)


def pixel(path, x, y):
    return tuple(gdal.Open(str(path)).ReadRaster(x, y, 1, 1, band_list=[1, 2, 3]))


@needs_tools
def test_a_state_pack_is_tinted_shaded_cut_and_reused(monkeypatch, tmp_path):
    shp = states(tmp_path, ("AL", [(-86.9, 33.4, -86.7, 33.6)]))
    fetched = []

    def fake_fetch(url):
        x, y = (int(p) for p in url.rsplit(".", 1)[0].split("/")[-2:])
        fetched.append(url)
        return dem(x, y, 1500)
    monkeypatch.setattr(faa, "fetch", fake_fetch)
    made = terrain.state_pack("AL", shp, tmp_path / "out", tmp_path / "work", tmp_path / "cache")
    target = tmp_path / "out" / "terrain" / "AL.pmtiles"
    assert made["region"] == "AL" and made["bytes"] == target.stat().st_size
    assert pack.zoom_range(target) == terrain.ZOOMS

    # Each source tile starts at sea on its west edge and climbs to 1500 m: blue, then tan.
    # Tile x 530 is the west half of source tile 265.
    y = terrain.tile_range(-86.8, 33.5, -86.8, 33.5, 11)[1].start
    west = tmp_path / "west.webp"
    west.write_bytes(subprocess.run(["pmtiles", "tile", str(target), "11", "530", str(y)],
                                    check=True, capture_output=True).stdout)
    r, g, b = pixel(west, 5, 128)
    assert b > r
    r, g, b = pixel(west, 200, 128)
    assert r > g > b

    count = len(fetched)
    again = terrain.state_pack("AL", shp, tmp_path / "out2", tmp_path / "work2", tmp_path / "cache")
    assert again["sha256"] == made["sha256"] and len(fetched) == count


def test_a_terrain_layer_builds_the_states_named(monkeypatch, tmp_path):
    made = []
    monkeypatch.setattr(terrain, "state_pack", lambda code, *a: made.append(code) or
                        {"layer": "terrain", "region": code, "bytes": 1, "sha256": code.lower() * 8})
    urls = {"terrain": [u for u in cli.base_urls()["terrain"] if u.endswith(("/AL.dem", "/CO.dem"))]}
    packs, files = cli.build_base(urls, tmp_path / "work", tmp_path / "out")
    assert made == ["AL", "CO"]
    assert list(files) == ["charts/base/terrain/AL-alalalalalalalal.pmtiles", "charts/base/terrain/CO-cocococococococo.pmtiles"]
    assert {p["version"] for p in packs} == {terrain.VERSION}
