import re
import shutil
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

from chartpipe import pack
from chartpipe.build import run

from . import awc

BUCKET = "https://noaa-mrms-pds.s3.amazonaws.com/"
PRODUCT = "CONUS/MergedReflectivityQCComposite_00.50/"
FRAMES = 12
# A frame further than this behind the newest one would show storms where they no longer are.
SPAN = timedelta(minutes=70)
# Vector bands overzoom sharp; zoom 5 tiles already hold the 1 km grid.
ZOOMS = (3, 5)
# Band floors in dBZ. The app's colors (core RadarStyle) use the same floors.
STEP = 5
LEVELS = range(5, 75, STEP)
# MRMS writes -999 where no radar reaches.
NO_COVERAGE = -1000
# Gaussian kernel width in grid pixels (1 km each).
BLUR = 5
# Chaikin passes over the echo outlines; each one doubles their points.
CORNER_PASSES = 2
_KEY = re.compile(r"<Key>(" + re.escape(PRODUCT)
                  + r"\d{8}/MRMS_MergedReflectivityQCComposite_00\.50_(\d{8})-(\d{6})\.grib2\.gz)</Key>")


def listing_url(day: datetime) -> str:
    return f"{BUCKET}?list-type=2&prefix={PRODUCT}{day:%Y%m%d}/"


def newest(listing_xml: bytes):
    """Key and valid time of the newest frame in one day's listing, or None when the day is empty."""
    text = listing_xml.decode("utf-8", errors="replace")
    # File names carry irregular seconds, so the folder is listed. A day holds about 720 frames, under one page.
    if "<ListBucketResult" not in text or "<IsTruncated>true</IsTruncated>" in text:
        raise awc.BadSource("radar: not a complete bucket listing")
    found = sorted(_KEY.findall(text))
    if not found:
        return None
    key, day, clock = found[-1]
    return key, datetime.strptime(day + clock, "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc)


def latest(fetch, now: datetime):
    """Newest frame today. Just after midnight UTC today's folder is empty, so yesterday's is read."""
    return newest(fetch(listing_url(now))) or newest(fetch(listing_url(now - timedelta(days=1))))


def _at_least(grid: Path, low: float, high: float, out: Path) -> None:
    run(["gdal_contour", "-q", "-p", "-amin", "dbz", "-f", "FlatGeobuf", "-fl", low, high, grid, out])


def chaikin(ring, times: int = CORNER_PASSES):
    """Cuts every corner of a closed ring (first point repeated last) at a quarter and three quarters."""
    import numpy as np
    p = np.asarray(ring, dtype=float)[:-1]
    for _ in range(times):
        q = np.roll(p, -1, axis=0)
        p = np.stack([0.75 * p + 0.25 * q, 0.25 * p + 0.75 * q], axis=1).reshape(-1, 2)
    return np.vstack([p, p[:1]])


def _round_corners(areas: Path) -> None:
    """Rounds the echo areas in place. Bands are cut from them afterwards, so neighbors never overlap."""
    from osgeo import ogr
    ogr.UseExceptions()
    source = ogr.Open(str(areas), update=1)
    layer = source.GetLayer("areas")
    layer.SetAttributeFilter(f"dbz <> {NO_COVERAGE}")
    for feature in layer:
        shape = feature.GetGeometryRef()
        out = ogr.Geometry(ogr.wkbMultiPolygon)
        polygons = [shape] if shape.GetGeometryType() == ogr.wkbPolygon else [shape.GetGeometryRef(i) for i in range(shape.GetGeometryCount())]
        for polygon in polygons:
            rounded = ogr.Geometry(ogr.wkbPolygon)
            for r in range(polygon.GetGeometryCount()):
                ring = ogr.Geometry(ogr.wkbLinearRing)
                for x, y in chaikin(polygon.GetGeometryRef(r).GetPoints()):
                    ring.AddPoint_2D(x, y)
                rounded.AddGeometry(ring)
            out.AddGeometry(rounded)
        # Rounding can pull a hole across its outline where the two nearly touch.
        feature.SetGeometry(out if out.IsValid() else out.MakeValid())
        layer.SetFeature(feature)
    source = None


def build_frame(grib_gz: Path, out: Path) -> None:
    """One grib frame to a vector PMTiles of filled dBZ bands, layer radar, attribute dbz (the band's floor)."""
    scratch = out.parent / (out.stem + ".build")
    shutil.rmtree(scratch, ignore_errors=True)
    scratch.mkdir(parents=True)
    try:
        grid = scratch / "grid.tif"
        run(["gdal_translate", "-q", f"/vsigzip/{grib_gz}", grid])
        # Echo edges come from a blurred grid so they curve instead of tracing every 1 km pixel.
        # No echo and no coverage count as 0 dBZ there, or the blur would drag edges down to -999.
        smooth = scratch / "smooth.tif"
        run(["gdal", "raster", "pipeline", "-q", "!", "read", grid,
             "!", "reclassify", "-m", "[-inf,0)=0; DEFAULT=PASS_THROUGH", "--ot", "Float32",
             "!", "neighbors", "--kernel", "gaussian", "--size", BLUR, "--ot", "Float32",
             "!", "write", smooth])
        # One area per level, everything at or above it: a run with many levels is several times slower.
        floors = [(grid, NO_COVERAGE, -900)] + [(smooth, level, 1000) for level in LEVELS]
        parts = {low: scratch / f"{low}.fgb" for _, low, _ in floors}
        # The wx job gets 2 CPUs.
        with ThreadPoolExecutor(2) as pool:
            list(pool.map(lambda f: _at_least(*f, parts[f[1]]), floors))
        areas = scratch / "areas.gpkg"
        for low, part in parts.items():
            run(["ogr2ogr", "-q", "-append", "-nln", "areas", "-where", f"dbz = {low}", areas, part])
        _round_corners(areas)
        # A band is its level's area less the next level's. No coverage has no next level.
        bands = scratch / "bands.fgb"
        run(["ogr2ogr", "-q", "-dialect", "sqlite", "-nln", "radar", "-nlt", "MULTIPOLYGON", "-sql",
             "SELECT a.dbz AS dbz, coalesce(ST_Difference(a.geom, b.geom), a.geom) AS geom "
             f"FROM areas a LEFT JOIN areas b ON b.dbz = a.dbz + {STEP}",
             bands, areas])
        # Detail 14 keeps shared band edges from splitting into slivers when overzoomed.
        # Simplification 2 keeps most of the rounded corners; 4 straightened them again.
        run(["tippecanoe", "-q", "-o", out, "--force", "-l", "radar", f"-Z{ZOOMS[0]}", f"-z{ZOOMS[1]}",
             "--full-detail=14", "-S", "2", "--coalesce", "--detect-shared-borders", "-y", "dbz", bands])
        pack.check_zooms(out, ZOOMS)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
