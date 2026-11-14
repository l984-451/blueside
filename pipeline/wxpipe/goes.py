"""GOES satellite pictures and lightning from NOAA's open buckets on AWS."""
import io
import json
import re
import shutil
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

from chartpipe import faa, pack
from chartpipe.build import run, tile

from . import awc

# East first; West is warped over it, so the West Coast comes from the satellite that sees it squarely.
SATELLITES = ("goes19", "goes18")
CMI = "ABI-L2-CMIPC/"
GLM = "GLM-L2-LCFA/"
# Raster tiles; zoom 6 pixels (2.4 km) hold the 2 km infrared grid, the app overzooms with linear resampling.
ZOOMS = (3, 6)
# The radar mosaic's box, in degrees: west, south, east, north.
CONUS = (-130.0, 20.0, -60.0, 55.0)
# Lightning kept, by when its 20 s file began.
FLASH_SPAN = timedelta(minutes=30)
# GLM writes a file every 20 s; none this recent means the feed stopped.
FLASH_GAP = timedelta(minutes=10)
# Cloud-top temperature (K) to color and alpha: warm ground clear, cold tops through the enhanced IR colors.
RAMP = """nv 0 0 0 0
330 0 0 0 0
280 0 0 0 0
268 150 150 150 70
253 195 195 195 150
238 235 235 235 190
233 90 190 255 205
223 20 90 235 215
213 30 190 70 220
205 250 230 20 230
198 250 130 0 235
192 220 20 20 240
185 200 0 200 240
170 255 255 255 240
"""
_START = re.compile(r"_s(\d{4})(\d{3})(\d{2})(\d{2})(\d{2})\d")


def bucket(satellite: str) -> str:
    return f"https://noaa-{satellite}.s3.amazonaws.com/"


def started(key: str) -> datetime:
    """Scan start from a GOES file name (year, day of year, hour, minute, second)."""
    y, doy, h, m, s = map(int, _START.search(key).groups())
    return datetime(y, 1, 1, h, m, s, tzinfo=timezone.utc) + timedelta(days=doy - 1)


def keys(fetch, satellite: str, product: str, hour: datetime) -> list[str]:
    """Every key of one product hour. An hour holds under 1000 keys, one page."""
    prefix = f"{product}{hour:%Y/%j/%H}/"
    text = fetch(f"{bucket(satellite)}?list-type=2&prefix={prefix}").decode("utf-8", errors="replace")
    if "<ListBucketResult" not in text or "<IsTruncated>true</IsTruncated>" in text:
        raise awc.BadSource(f"{satellite}: not a complete bucket listing")
    tag = "_G" + satellite[-2:] + "_"
    return sorted(k for k in re.findall(r"<Key>([^<]+\.nc)</Key>", text) if k.startswith(prefix) and tag in k)


def newest_ir(fetch, satellite: str, now: datetime):
    """Key of the newest CONUS band 13 (10.3 µm) picture, this hour or the last."""
    for hour in (now, now - timedelta(hours=1)):
        found = [k for k in keys(fetch, satellite, CMI, hour) if re.search(r"-M\dC13_", k)]
        if found:
            return max(found, key=started)
    return None


def _values(var):
    """A netCDF variable with its packing undone: unsigned view, fill to NaN, scale and offset."""
    import numpy as np
    raw = var[()]
    attrs = var.attrs
    if attrs.get("_Unsigned", b"") in (b"true", "true"):
        raw = raw.view(np.dtype(raw.dtype.str.replace("i", "u")))
    out = raw.astype(np.float64)
    if "_FillValue" in attrs:
        fill = np.asarray(attrs["_FillValue"]).astype(raw.dtype)
        out[raw == fill] = np.nan
    return out * float(np.ravel(attrs.get("scale_factor", [1]))[0]) + float(np.ravel(attrs.get("add_offset", [0]))[0])


def _geotiff(nc: Path, out: Path) -> None:
    """Brightness temperature on the satellite's fixed grid, as a GeoTIFF GDAL can warp."""
    import h5py
    import numpy as np
    from osgeo import gdal
    gdal.UseExceptions()
    with h5py.File(nc) as f:
        temp = _values(f["CMI"]).astype(np.float32)
        p = {k: (v.decode() if isinstance(v, bytes) else float(np.ravel(v)[0])) for k, v in f["goes_imager_projection"].attrs.items()}
        x, y = _values(f["x"]) * p["perspective_point_height"], _values(f["y"]) * p["perspective_point_height"]
    dx, dy = x[1] - x[0], y[1] - y[0]
    ds = gdal.GetDriverByName("GTiff").Create(str(out), len(x), len(y), 1, gdal.GDT_Float32, ["COMPRESS=ZSTD"])
    ds.SetGeoTransform((x[0] - dx / 2, dx, 0, y[0] - dy / 2, 0, dy))
    ds.SetProjection(f"+proj=geos +h={p['perspective_point_height']} +lon_0={p['longitude_of_projection_origin']} "
                     f"+sweep={p['sweep_angle_axis']} +a={p['semi_major_axis']} +b={p['semi_minor_axis']} +units=m +no_defs")
    band = ds.GetRasterBand(1)
    band.SetNoDataValue(float("nan"))
    band.WriteArray(temp)
    ds = None


def build_ir(pictures: list[Path], out: Path) -> None:
    """Infrared pictures, East first, to a raster PMTiles of enhanced IR colors over the CONUS box."""
    scratch = out.parent / (out.stem + ".build")
    shutil.rmtree(scratch, ignore_errors=True)
    scratch.mkdir(parents=True)
    try:
        tifs = []
        for i, nc in enumerate(pictures):
            tifs.append(scratch / f"{i}.tif")
            _geotiff(nc, tifs[-1])
        res = 2 * 20037508.342789244 / 256 / 2 ** ZOOMS[1]
        west, south = _mercator(CONUS[0], CONUS[1])
        east, north = _mercator(CONUS[2], CONUS[3])
        warped = scratch / "warped.tif"
        run(["gdalwarp", "-q", "-t_srs", "EPSG:3857", "-te", west, south, east, north, "-tr", res, res, "-tap",
             "-r", "bilinear", "-dstnodata", "nan", "-wo", "NUM_THREADS=2", "-co", "COMPRESS=ZSTD", *tifs, warped])
        ramp = scratch / "ramp.txt"
        ramp.write_text(RAMP)
        colored = scratch / "colored.tif"
        run(["gdaldem", "color-relief", "-q", "-alpha", warped, ramp, colored])
        tiles = scratch / "tiles"
        tile(colored, tiles, *ZOOMS)
        mbtiles = scratch / "satellite.mbtiles"
        pack.tiles_to_mbtiles(tiles, mbtiles, "satellite")
        out.unlink(missing_ok=True)
        pack.to_pmtiles(mbtiles, out)
        pack.check_zooms(out, ZOOMS)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def _mercator(lon: float, lat: float) -> tuple[float, float]:
    import math
    r = 6378137.0
    return r * math.radians(lon), r * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))


def latest_ir(fetch, now: datetime):
    """The newest picture of each satellite that has one, East first, and the older scan time. None when none."""
    found = [(s, k) for s in SATELLITES if (k := newest_ir(fetch, s, now))]
    if not found:
        return None
    return found, min(started(k) for _, k in found)


def _flashes(body: bytes) -> list[list[float]]:
    """Good-quality flashes inside the CONUS box, as [lat, lon] to 0.01 degree (GLM pixels are 8 km)."""
    import h5py
    import numpy as np
    with h5py.File(io.BytesIO(body)) as f:
        lat, lon = f["flash_lat"][()], f["flash_lon"][()]
        quality = f["flash_quality_flag"][()] if "flash_quality_flag" in f else np.zeros(len(lat), dtype=int)
    west, south, east, north = CONUS
    keep = (quality == 0) & (lon >= west) & (lon <= east) & (lat >= south) & (lat <= north)
    return [[round(float(a), 2), round(float(o), 2)] for a, o in zip(lat[keep], lon[keep])]


def lightning_json(fetch, work: Path, now: datetime) -> bytes:
    """GOES-East GLM flashes of the last half hour, one group per 20 s file: [{"t", "p": [[lat, lon], ...]}].
    Files already read are kept under the work folder, so a run downloads only the new ones."""
    satellite = SATELLITES[0]
    cache_file = work / "lightning-cache.json"
    try:
        cache = json.loads(cache_file.read_text())
    except (OSError, ValueError):
        cache = {}
    cutoff = now - FLASH_SPAN
    wanted = [k for hour in (now - timedelta(hours=1), now) for k in keys(fetch, satellite, GLM, hour)
              if cutoff <= started(k) <= now]
    if not wanted or now - max(map(started, wanted)) > FLASH_GAP:
        raise awc.BadSource("lightning: no recent GLM files")
    missing = [k for k in wanted if k not in cache]
    with ThreadPoolExecutor(8) as pool:
        for key, points in zip(missing, pool.map(lambda k: _flashes(fetch(bucket(satellite) + k)), missing)):
            cache[key] = points
    cache = {k: cache[k] for k in wanted}
    scratch = work / "lightning-cache.json.new"
    scratch.write_text(json.dumps(cache))
    scratch.replace(cache_file)
    return json.dumps([{"t": faa.iso(started(k)), "p": p} for k, p in sorted(cache.items()) if p],
                      separators=(",", ":")).encode()
