import gzip
import json
import math
import urllib.error
import urllib.parse
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import pytest
from osgeo import gdal, osr

from wxpipe import __main__ as wx
from wxpipe import awc, fb, tfr

gdal.UseExceptions()
FIX = Path(__file__).parent / "fixtures" / "wx"
RUN =datetime(2026, 11, 13, 6, tzinfo=timezone.utc)
# Old enough that the 06Z run is the newest posted; the 06 h forecast's window has ended.
NOW = datetime(2026, 11, 13, 15, 32, tzinfo=timezone.utc)
HNL = {"id": "HNL", "lat": 21.3083, "lon": -157.9304, "region": "hawaii", "wind_from": 1000, "temp_from": 6000}
# Product category and number of each element in GRIB2 table 4.2.
CODES = {"UGRD": (2, 2), "VGRD": (2, 3), "TMP": (0, 0), "HGT": (3, 5)}
STANDARD_M = {p: (1 - (p / 1013.25) ** (1 / 5.25588)) / 2.25577e-5 for p in fb.PRESSURES if p >= 250}
STANDARD_M |= {p: 11000 - 6341.62 * math.log(p / 226.32) for p in fb.PRESSURES if p < 250}


def column(p):
    """A made-up atmosphere: standard heights and temperatures, wind from the west at 1 m/s per km."""
    z = STANDARD_M[p]
    return {"UGRD": z / 1000, "VGRD": 0.0, "TMP": 15 - 6.5 * min(z, 11000) / 1000, "HGT": z}


def fake_grib(run, hour, box) -> bytes:
    """What the filter sends for one box, on a 1 degree grid, with every value from column()."""
    left, right, top, bottom = box
    cols, rows = int(right - left) + 1, int(top - bottom) + 1
    names = [(element, p) for element in fb.UNITS for p in fb.PRESSURES]
    mem = gdal.GetDriverByName("MEM").Create("", cols, rows, len(names), gdal.GDT_Float32)
    mem.SetGeoTransform((left - 0.5, 1, 0, top + 0.5, 0, -1))
    mem.SetSpatialRef(osr.SpatialReference(osr.SRS_WKT_WGS84_LAT_LONG))
    options = ["DISCIPLINE=0", "IDS_CENTER=7", f"IDS_REF_TIME={run:%Y-%m-%dT%H:%M:%SZ}", "PDS_PDTN=0",
               "DATA_ENCODING=IEEE_FLOATING_POINT", "INPUT_UNIT=C"]
    for n, (element, p) in enumerate(names, 1):
        mem.GetRasterBand(n).WriteArray(np.full((rows, cols), column(p)[element]))
        category, number = CODES[element]
        options.append(f"BAND_{n}_PDS_TEMPLATE_ASSEMBLED_VALUES={category} {number} 2 0 96 0 0 1 {hour} 100 0 {p * 100} 255 0 0")
    path = f"/vsimem/{run:%H}-{hour}-{left}.grib2"
    gdal.GetDriverByName("GRIB").CreateCopy(path, mem, options=options)
    handle = gdal.VSIFOpenL(path, "rb")
    body = bytes(gdal.VSIFReadL(1, gdal.VSIStatL(path).size, handle))
    gdal.VSIFCloseL(handle)
    gdal.Unlink(path)
    return body


def nomads(url, posted=lambda run: True):
    """A filter that answers from fake_grib, and like NOMADS for a run not posted yet."""
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
    run = datetime.strptime(query["dir"][0][5:16], "%Y%m%d/%H").replace(tzinfo=timezone.utc)
    if not posted(run):
        raise urllib.error.HTTPError(url, 403, "Forbidden", {}, None)
    box = tuple(float(query[key][0]) for key in ("leftlon", "rightlon", "toplat", "bottomlat"))
    return fake_grib(run, int(query["file"][0][-3:]), box)


def test_a_real_file_reads_as_an_independent_grib_reader_reads_it():
    cube, transform = fb.read(FIX / "gfs-hnl-2026111306-f012.grib2", RUN, RUN + timedelta(hours=12))
    levels = fb.levels(HNL, fb.sample(cube, transform, HNL["lat"], HNL["lon"]))
    # ecCodes on the full global fields of the same run gives these to within rounding.
    assert [(lv["ft"], lv["dir"], lv["kt"], lv["temp"]) for lv in levels] == [
        (1000, 70, 27, None), (1500, 71, 28, None), (2000, 71, 29, None), (3000, 74, 30, None),
        (6000, 84, 24, 14), (9000, 81, 19, 14), (12000, 71, 14, 10), (15000, 62, 20, 7),
        (18000, 54, 17, -3), (24000, 37, 14, -18)]


def test_a_file_of_another_time_fails():
    with pytest.raises(awc.BadSource, match="band 1"):
        fb.read(FIX / "gfs-hnl-2026111306-f012.grib2", RUN, RUN + timedelta(hours=18))


def test_flight_levels_are_standard_pressures():
    assert [round(fb.pressure_hpa(ft), 1) for ft in (0, 18000, 24000, 34000, 39000)] == [1013.2, 506.0, 392.7, 250.0, 196.8]


def test_levels_by_height_up_to_15000_ft_and_by_pressure_above():
    profile = np.array([column(p)[element] for element in fb.UNITS for p in fb.PRESSURES])
    station = {"region": "us", "wind_from": 6000, "temp_from": 9000}
    levels = {lv["ft"]: lv for lv in fb.levels(station, profile)}
    assert list(levels) == [6000, 9000, 12000, 18000, 24000, 30000, 34000, 39000]
    # 1829 m: 1.8 m/s from the west is under 5 kt, so light and variable; no temperature below temp_from.
    assert levels[6000] == {"ft": 6000, "dir": None, "kt": 0, "temp": None}
    assert levels[9000] == {"ft": 9000, "dir": 270, "kt": 5, "temp": -3}
    # A flight level sits at its standard height in this atmosphere: FL240 is 7315 m, FL390 11887 m.
    assert levels[24000] == {"ft": 24000, "dir": 270, "kt": 14, "temp": -33}
    assert levels[39000] == {"ft": 39000, "dir": 270, "kt": 23, "temp": -56}


def test_a_point_is_read_between_its_four_grid_points_even_across_180_degrees():
    cube = np.arange(12.0).reshape(1, 3, 4)
    # Grid points 175 to 178 east, 52 to 50 north; the transform names 360-degree longitudes.
    transform = (174.5, 1, 0, 52.5, 0, -1)
    assert fb.sample(cube, transform, 51.5, 176.5)[0] == pytest.approx((1 + 2 + 5 + 6) / 4)
    assert fb.sample(cube, transform, 51.5, 176.5 - 360)[0] == pytest.approx(3.5)
    with pytest.raises(awc.BadSource, match="outside"):
        fb.sample(cube, transform, 51.5, 178.5)


def test_the_newest_posted_run_gives_one_forecast_per_window_still_open(tmp_path):
    asked = []
    data = json.loads(fb.build(lambda url: asked.append(url) or nomads(url), tmp_path, NOW))
    assert [(f["valid"], f["from"], f["to"]) for f in data["forecasts"]] == [
        ("2026-11-13T18:00:00Z", "2026-11-13T15:00:00Z", "2026-11-13T21:00:00Z"),
        ("2026-11-14T00:00:00Z", "2026-11-13T21:00:00Z", "2026-11-14T03:00:00Z"),
        ("2026-11-14T06:00:00Z", "2026-11-14T03:00:00Z", "2026-11-14T09:00:00Z"),
        ("2026-11-14T12:00:00Z", "2026-11-14T09:00:00Z", "2026-11-14T15:00:00Z"),
        ("2026-11-14T18:00:00Z", "2026-11-14T15:00:00Z", "2026-11-14T21:00:00Z")]
    assert {f["based"] for f in data["forecasts"]} == {"2026-11-13T06:00:00Z"}
    assert len(asked) == 15 and all("gfs.t06z" in url for url in asked)
    first = {s["id"]: s for s in data["forecasts"][0]["stations"]}
    assert len(first) == 218
    # Levels near the ground stay out as the bulletins left them out.
    assert [lv["ft"] for lv in first["ABQ"]["levels"]][:2] == [9000, 12000]
    assert [lv["ft"] for lv in first["HNL"]["levels"]] == [1000, 1500, 2000, 3000, 6000, 9000, 12000, 15000, 18000, 24000]
    assert (first["H52"]["lat"], first["H52"]["lon"]) == (26.0, -89.5)


def test_the_file_keeps_the_shape_the_apps_read(tmp_path):
    ours = json.loads(fb.build(nomads, tmp_path, NOW))
    # The committed sample was mirrored from the FB bulletins, the format both apps decode.
    theirs = json.loads(gzip.decompress((FIX / "out" / "winds.json.gz").read_bytes()))

    def shape(data):
        forecast = data["forecasts"][0]
        return sorted(data), sorted(forecast), {
            s["id"]: (sorted(s), s["lat"], s["lon"], [(sorted(lv), lv["ft"], lv["temp"] is None) for lv in s["levels"]])
            for s in forecast["stations"]}

    assert shape(ours) == shape(theirs)
    values = {type(lv[key]) for f in ours["forecasts"] for s in f["stations"] for lv in s["levels"] for key in lv}
    assert values == {int, type(None)}


def test_a_run_not_yet_posted_leaves_the_one_before_in_use(tmp_path):
    fb.build(nomads, tmp_path, NOW)
    later = NOW + timedelta(hours=1)
    data = json.loads(fb.build(lambda url: nomads(url, lambda run: run == RUN), tmp_path, later))
    assert {f["based"] for f in data["forecasts"]} == {"2026-11-13T06:00:00Z"}
    # Once posted, the new run replaces it and the old run's files go.
    data = json.loads(fb.build(nomads, tmp_path, later))
    assert {f["based"] for f in data["forecasts"]} == {"2026-11-13T12:00:00Z"}
    assert {p.name[:10] for p in (tmp_path / "gfs").iterdir()} == {"2026111312"}


def test_an_error_page_is_never_kept_and_fails_the_source(tmp_path):
    with pytest.raises(awc.BadSource, match="not a whole GRIB file"):
        fb.build(lambda url: b"<!doctype html><p>This data is not yet available.</p>", tmp_path, NOW)
    assert list((tmp_path / "gfs").glob("*")) == []


def test_winds_are_checked_once_an_hour_and_a_run_is_fetched_once(tmp_path, monkeypatch):
    monkeypatch.setattr(tfr, "MIN_NOTICES", 1)
    read, asked = awc.offline(FIX), []

    def fetch(url):
        if url.startswith(fb.FILTER):
            asked.append(url)
            return nomads(url)
        return read(url)
    frame = lambda grib, out: out.write_bytes(b"frame")
    start = datetime(2026, 11, 13, 14, tzinfo=timezone.utc)
    assert "winds" not in wx.run(tmp_path, fetch, start, None, frame)
    assert len(asked) == 18
    for minutes in (55, 60):
        assert "winds" not in wx.run(tmp_path, fetch, start + timedelta(minutes=minutes), None, frame)
    # Within the hour nothing is asked; on the hour the same run is built again from the files on disk.
    assert len(asked) == 18
    index = json.loads((tmp_path / "out" / "wx" / "index.json").read_text())
    assert index["checked_at"]["winds"] == "2026-11-13T15:00:00Z"
    body = json.loads(gzip.decompress((tmp_path / "out" / "wx" / "winds.json.gz").read_bytes()))
    assert body["version"] == 1 and len(body["forecasts"]) == 5
