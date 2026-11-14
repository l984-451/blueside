"""Winds and temperatures aloft at the FB stations, from the NOAA GFS on NOMADS."""
import csv
import http.client
import math
import sys
from datetime import datetime, timedelta
from pathlib import Path

from chartpipe import faa

from . import awc

FILTER = "https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25_1hr.pl"
# Unit of each field as GDAL reports it, in the order they are stacked.
UNITS = {"UGRD": "[m/s]", "VGRD": "[m/s]", "TMP": "[C]", "HGT": "[gpm]"}
PRESSURES = (1000, 975, 950, 925, 900, 850, 800, 750, 700, 650, 600, 550, 500, 400, 350, 300, 250, 200, 150)
# Region: box (left, right, top, bottom) reaching a grid point past every station, and the levels its bulletin carried.
REGIONS = {
    "us": ((-126, -67, 50, 23), (3000, 6000, 9000, 12000, 18000, 24000, 30000, 34000, 39000)),
    "alaska": ((175, 232, 72, 51), (3000, 6000, 9000, 12000, 18000, 24000, 30000, 34000, 39000)),
    "hawaii": ((-160, -154, 23, 19), (1000, 1500, 2000, 3000, 6000, 9000, 12000, 15000, 18000, 24000)),
}
# Levels up to here are true altitudes; higher ones are pressure altitudes, as in the bulletins.
TRUE_ALTITUDE_TOP = 15000
# Forecast hours of each run. Each one is used from 3 hours before its valid time to 3 hours after.
HOURS = (6, 12, 18, 24, 30, 36)
HALF_WINDOW = timedelta(hours=3)
# GFS runs every 6 hours, and NOMADS has a run's first 36 hours about 3 h 45 min after it starts.
RUN_STEP = timedelta(hours=6)
POSTED = timedelta(hours=4)
# Checked once an hour; a new run's files are fetched once, then kept until the run is replaced.
REFETCH = timedelta(minutes=60)
# Slower winds are light and variable, which the bulletins wrote as 9900.
LIGHT_KT = 5
KT_PER_MS = 3600 / 1852
FT = 0.3048


def stations() -> list[dict]:
    """Station positions (NASR, or NWSI 10-812 for the few NASR no longer lists), region, and the lowest
    levels the bulletins gave a wind and a temperature at: they left lower ones out near the ground."""
    with open(Path(__file__).parent / "fb_stations.csv", newline="") as file:
        return [{"id": row["ident"], "lat": float(row["lat"]), "lon": float(row["lon"]), "region": row["region"],
                 "wind_from": int(row["wind_from"]), "temp_from": int(row["temp_from"])}
                for row in csv.DictReader(file)]


def pressure_hpa(ft: float) -> float:
    """Standard atmosphere pressure at a pressure altitude."""
    m = ft * FT
    if m <= 11000:
        return 1013.25 * (1 - 2.25577e-5 * m) ** 5.25588
    return 226.32 * math.exp(-(m - 11000) / 6341.62)


def url(run: datetime, hour: int, region: str) -> str:
    left, right, top, bottom = REGIONS[region][0]
    fields = "&".join([f"var_{element}=on" for element in UNITS] + [f"lev_{p}_mb=on" for p in PRESSURES])
    return (f"{FILTER}?dir=%2Fgfs.{run:%Y%m%d}%2F{run:%H}%2Fatmos&file=gfs.t{run:%H}z.pgrb2.0p25.f{hour:03d}&{fields}"
            f"&subregion=&leftlon={left}&rightlon={right}&toplat={top}&bottomlat={bottom}")


def download(fetch, work: Path, run: datetime, hour: int, region: str) -> Path:
    """One region's fields for one forecast hour, kept on disk until the run is replaced."""
    path = Path(work) / "gfs" / f"{run:%Y%m%d%H}-f{hour:03d}-{region}.grib2"
    if not path.exists():
        body = fetch(url(run, hour, region))
        # An error page or a cut-off answer is never kept.
        if not (body.startswith(b"GRIB") and body.endswith(b"7777")):
            raise awc.BadSource(f"winds: {path.name} is not a whole GRIB file")
        path.parent.mkdir(parents=True, exist_ok=True)
        part = path.with_name(path.name + ".part")
        part.write_bytes(body)
        part.replace(path)
    return path


def read(path: Path, run: datetime, valid: datetime):
    """The file's fields stacked by UNITS then PRESSURES, and its geotransform. A field missing or of another time fails."""
    import numpy as np
    from osgeo import gdal
    gdal.UseExceptions()
    data = gdal.Open(str(path))
    found = {}
    for i in range(1, data.RasterCount + 1):
        band = data.GetRasterBand(i)
        meta = band.GetMetadata()
        element = meta.get("GRIB_ELEMENT")
        times = (int(meta["GRIB_REF_TIME"].split()[0]), int(meta["GRIB_VALID_TIME"].split()[0]))
        if UNITS.get(element) != meta.get("GRIB_UNIT") or times != (int(run.timestamp()), int(valid.timestamp())):
            raise awc.BadSource(f"winds: {path.name} band {i} is {element} {meta.get('GRIB_UNIT')} at {times}")
        found[(element, meta.get("GRIB_SHORT_NAME"))] = band.ReadAsArray()
    try:
        cube = np.stack([found[(element, f"{p * 100}-ISBL")] for element in UNITS for p in PRESSURES])
    except KeyError as missing:
        raise awc.BadSource(f"winds: {path.name} lacks {missing}")
    return cube, data.GetGeoTransform()


def sample(cube, transform, lat: float, lon: float):
    """Every field at one point, bilinear between the four grid points around it."""
    x0, dx, _, y0, _, dy = transform
    # Grid point centers sit half a cell in from the edge; longitudes may run past 180.
    col, row = ((lon - x0) % 360) / dx - 0.5, (lat - y0) / dy - 0.5
    c, r = math.floor(col), math.floor(row)
    if not (0 <= c < cube.shape[2] - 1 and 0 <= r < cube.shape[1] - 1):
        raise awc.BadSource(f"winds: {lat}, {lon} is outside the grid")
    fx, fy = col - c, row - r
    g = cube[:, r:r + 2, c:c + 2]
    return (g[:, 0, 0] * (1 - fx) + g[:, 0, 1] * fx) * (1 - fy) + (g[:, 1, 0] * (1 - fx) + g[:, 1, 1] * fx) * fy


def levels(station: dict, profile) -> list[dict]:
    """A station's levels from its column of u, v, temperature and height, lowest pressure level first."""
    import numpy as np
    u, v, t, z = profile.reshape(len(UNITS), len(PRESSURES))
    out = []
    for ft in REGIONS[station["region"]][1]:
        if ft < station["wind_from"]:
            continue
        # Linear in height for a true altitude, in log pressure for a pressure altitude.
        x, at = (z, ft * FT) if ft <= TRUE_ALTITUDE_TOP else (-np.log(PRESSURES), -math.log(pressure_hpa(ft)))
        east, north, temp = (float(np.interp(at, x, values)) for values in (u, v, t))
        kt = round(math.hypot(east, north) * KT_PER_MS)
        light = kt < LIGHT_KT
        out.append({"ft": ft, "dir": None if light else round(math.degrees(math.atan2(-east, -north))) % 360 or 360,
                    "kt": 0 if light else kt, "temp": round(temp) if ft >= station["temp_from"] else None})
    return out


def forecast(run: datetime, hour: int, files: dict[str, Path], where: list[dict]) -> dict:
    valid = run + timedelta(hours=hour)
    grids = {region: read(path, run, valid) for region, path in files.items()}
    found = []
    for station in where:
        profile = sample(*grids[station["region"]], station["lat"], station["lon"])
        found.append({"id": station["id"], "lat": station["lat"], "lon": station["lon"], "levels": levels(station, profile)})
    return {"based": faa.iso(run), "valid": faa.iso(valid), "from": faa.iso(valid - HALF_WINDOW),
            "to": faa.iso(valid + HALF_WINDOW), "stations": sorted(found, key=lambda s: s["id"])}


def newest_run(now: datetime) -> datetime:
    start = now - POSTED
    return start.replace(hour=start.hour // 6 * 6, minute=0, second=0, microsecond=0)


def build(fetch, work: Path, now: datetime) -> bytes:
    """The forecasts of the newest run whose use window has not ended. While that run is not all posted,
    the run before it is used."""
    newest, failure = newest_run(now), None
    for run in (newest, newest - RUN_STEP):
        hours = [hour for hour in HOURS if run + timedelta(hours=hour) + HALF_WINDOW > now]
        try:
            files = {hour: {region: download(fetch, work, run, hour, region) for region in REGIONS} for hour in hours}
            break
        except (OSError, http.client.HTTPException, awc.BadSource) as error:
            print(f"winds: run {faa.iso(run)} not fetched: {error}", file=sys.stderr)
            failure = failure or error
    else:
        raise failure
    # Files of older runs are not needed again.
    keep = (f"{newest:%Y%m%d%H}-", f"{run:%Y%m%d%H}-")
    for old in (Path(work) / "gfs").glob("*"):
        if not old.name.startswith(keep):
            old.unlink()
    if not hours:
        raise awc.BadSource("winds: every forecast has expired")
    where = stations()
    return awc._dump({"version": 1, "forecasts": [forecast(run, hour, files[hour], where) for hour in hours]})
