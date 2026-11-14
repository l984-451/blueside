import json
import shutil

import pytest

np = pytest.importorskip("numpy")
gdal = pytest.importorskip("osgeo.gdal")

from chartpipe import build

pytestmark = pytest.mark.skipif(shutil.which("gdalwarp") is None, reason="needs the GDAL tools")
gdal.UseExceptions()


def source(path, seed=0, west=-97.0, north=33.0):
    """A small RGB chart in degrees, about 11 km a side."""
    pixels = np.random.default_rng(seed).integers(0, 255, (3, 120, 120), np.uint8)
    data = gdal.GetDriverByName("GTiff").Create(str(path), 120, 120, 3, gdal.GDT_Byte)
    data.SetGeoTransform((west, 0.1 / 120, 0, north, 0, -0.1 / 120))
    data.SetProjection('GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563]],'
                       'PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433],AUTHORITY["EPSG","4326"]]')
    data.WriteArray(pixels)
    data.Close()
    return path


def outline(path, inset=0.01, west=-97.0, north=33.0):
    w, e, s, n = west + inset, west + 0.1 - inset, north - 0.1 + inset, north - inset
    ring = [[w, s], [e, s], [e, n], [w, n], [w, s]]
    path.write_text(json.dumps({"type": "FeatureCollection", "features": [
        {"type": "Feature", "properties": {}, "geometry": {"type": "Polygon", "coordinates": [ring]}}]}))
    return path


def test_the_same_inputs_hit_the_cache(tmp_path):
    src, cut, cache = source(tmp_path / "a.tif"), outline(tmp_path / "a.geojson"), tmp_path / "cache"
    assert not build.cached_warp(src, cut, tmp_path / "one.tif", build.Z12, cache)
    assert build.cached_warp(src, cut, tmp_path / "two.tif", build.Z12, cache)
    assert (tmp_path / "one.tif").read_bytes() == (tmp_path / "two.tif").read_bytes()


def test_a_changed_outline_or_source_misses(tmp_path):
    src, cut, cache = source(tmp_path / "a.tif"), outline(tmp_path / "a.geojson"), tmp_path / "cache"
    build.cached_warp(src, cut, tmp_path / "one.tif", build.Z12, cache)
    assert not build.cached_warp(src, outline(tmp_path / "b.geojson", inset=0.02), tmp_path / "two.tif", build.Z12, cache)
    assert not build.cached_warp(source(tmp_path / "b.tif", seed=1), cut, tmp_path / "three.tif", build.Z12, cache)


def test_a_corrupt_cached_sheet_is_rebuilt(tmp_path):
    src, cut, cache = source(tmp_path / "a.tif"), outline(tmp_path / "a.geojson"), tmp_path / "cache"
    build.cached_warp(src, cut, tmp_path / "one.tif", build.Z12, cache)
    good = (tmp_path / "one.tif").read_bytes()
    [cached] = cache.glob("*.tif")
    # Replaced, not edited, as a hard link would carry the damage to one.tif too.
    cached.unlink()
    cached.write_bytes(good[:len(good) // 2])
    assert not build.cached_warp(src, cut, tmp_path / "two.tif", build.Z12, cache)
    assert (tmp_path / "two.tif").read_bytes() == good
    assert build.cached_warp(src, cut, tmp_path / "three.tif", build.Z12, cache)


def test_parallel_warps_match_the_serial_run_byte_for_byte(tmp_path):
    jobs = []
    for i in range(3):
        west = -97.0 + 0.1 * i
        jobs.append((source(tmp_path / f"s{i}.tif", seed=i, west=west),
                     outline(tmp_path / f"s{i}.geojson", west=west), None))
    runs = {}
    for name, size in (("old", (1, 0)), ("serial", (1, 12)), ("parallel", (3, 2))):
        (tmp_path / name).mkdir()
        outs = build.warp_all([(s, c, tmp_path / name / s.name) for s, c, _ in jobs], build.Z12, size=size)
        runs[name] = [out.read_bytes() for out in outs]
    assert runs["old"] == runs["serial"] == runs["parallel"]


def test_pool_fits_the_container():
    assert build.pool_size(12, 24) == (4, 3)
    assert build.pool_size(12, 8) == (2, 6)
    assert build.pool_size(1, 1) == (1, 1)
