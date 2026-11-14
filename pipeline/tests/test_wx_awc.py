import gzip
import json
import os
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from wxpipe import awc

FIX = Path(__file__).parent / "fixtures" / "wx"
READ = awc.offline(FIX)
NOW = datetime(2026, 10, 13, 0, 35, tzinfo=timezone.utc)


@pytest.fixture(scope="module")
def us():
    return awc.us_ids(READ(awc.CACHE + "stations.cache.json.gz"))


@pytest.fixture(scope="module")
def metars(us):
    rows = json.loads(awc.metars_json(READ(awc.CACHE + "metars.cache.csv.gz"), us))
    return {row["id"]: row for row in rows}


def test_times_are_utc_without_fractions():
    assert awc.iso("2026-10-13T00:23:00.000Z") == "2026-10-13T00:23:00Z"
    # A time with no zone is UTC, never the local time of the machine.
    assert awc.iso("2026-10-14T22:30:00") == "2026-10-14T22:30:00Z"


def test_every_request_names_the_project(monkeypatch):
    seen = []

    class Reply:
        def __enter__(self):
            return self

        def __exit__(self, *error):
            return False

        def read(self):
            return b"ok"

    def answer(request, timeout):
        seen.append(request)
        return Reply()

    monkeypatch.setattr(awc.urllib.request, "urlopen", answer)
    assert awc.fetch("https://example.org/x") == b"ok"
    assert seen[0].get_header("User-agent") == (
        "BluesideWeatherMirror/1.0 (https://pub-b4d06f1c406b4312b314d87c67ecf862.r2.dev)")


def test_a_dropped_connection_is_tried_once_more(monkeypatch):
    calls = []

    def answer(request, timeout):
        calls.append(request.full_url)
        raise OSError("reset")

    monkeypatch.setattr(awc.urllib.request, "urlopen", answer)
    monkeypatch.setattr(awc.time, "sleep", lambda seconds: None)
    with pytest.raises(OSError):
        awc.fetch("https://example.org/x")
    assert len(calls) == 2


def test_dead_hosts_cannot_use_up_a_whole_turn():
    # Two station tries, five weather files, the notice list and the radar listing, each tried twice.
    assert 9 * (2 * awc.TIMEOUT + 1) < 240


def test_station_list_is_reused_for_a_day_and_survives_a_failed_refresh(tmp_path):
    calls = []

    def fetch(url):
        calls.append(url)
        return READ(url)

    def down(url):
        raise OSError("no answer")

    assert "KTVF" in awc.stations(fetch, tmp_path)
    assert "KTVF" in awc.stations(down, tmp_path)
    assert len(calls) == 1
    saved = tmp_path / "stations.cache.json.gz"
    two_days_ago = time.time() - 2 * 86400
    os.utime(saved, (two_days_ago, two_days_ago))
    assert "KTVF" in awc.stations(down, tmp_path)
    assert "KTVF" in awc.stations(fetch, tmp_path) and len(calls) == 2
    with pytest.raises(OSError):
        awc.stations(down, tmp_path / "empty")


@pytest.mark.parametrize("kept", [0, 500])
def test_a_station_list_cut_short_on_disk_is_fetched_again(tmp_path, kept):
    calls = []

    def fetch(url):
        calls.append(url)
        return READ(url)

    awc.stations(fetch, tmp_path)
    saved = tmp_path / "stations.cache.json.gz"
    whole = saved.read_bytes()
    saved.write_bytes(whole[:kept])
    assert "KTVF" in awc.stations(fetch, tmp_path)
    assert len(calls) == 2 and saved.read_bytes() == whole


class Reply:
    """A server answer with a body and a last-written time."""

    def __init__(self, written):
        self.headers = {} if written is None else {"Last-Modified": written}

    def __enter__(self):
        return self

    def __exit__(self, *error):
        return False

    def read(self):
        return b"ok"


def written(minutes_back):
    from email.utils import format_datetime
    return format_datetime(datetime.now(timezone.utc) - timedelta(minutes=minutes_back), usegmt=True)


def test_a_live_file_the_server_stopped_rewriting_is_refused(monkeypatch):
    stamp = []
    monkeypatch.setattr(awc.urllib.request, "urlopen", lambda request, timeout: Reply(stamp[0]))
    live = awc.CACHE + "airsigmets.cache.xml.gz"
    stamp[:] = [written(1)]
    assert awc.fetch(live) == b"ok"
    for old in (written(21), None):
        stamp[:] = [old]
        with pytest.raises(awc.BadSource, match="last written"):
            awc.fetch(live)
    # The station list is rewritten once a day.
    stamp[:] = [written(12 * 60)]
    assert awc.fetch(awc.CACHE + "stations.cache.json.gz") == b"ok"


def test_us_stations_only_with_the_agreed_keys(metars):
    assert len(metars) == 2547
    assert "CYPR" not in metars
    # Territories are coded apart from the states in the station list.
    assert "TJSJ" in metars and "PGUM" in metars
    assert metars["KTVF"] == {
        "id": "KTVF", "lat": 48.0597, "lon": -96.1787, "cat": "MVFR", "ceil": 1400,
        "sky": [{"cover": "SCT", "base": 700}, {"cover": "OVC", "base": 1400}],
        "vis": 10.0, "visp": True, "wdir": 40, "wspd": 11, "gust": None,
        "temp": 7, "dewp": 6, "altim": 29.8, "t": "2026-10-13T00:23:00Z",
        "raw": "SPECI KTVF 130023Z AUTO 04011KT 10SM -RA SCT007 OVC014 07/06 A2980 RMK AO2 PNO $",
    }
    always = {"id", "lat", "lon", "cat", "ceil", "sky", "vis", "wdir", "wspd", "gust", "temp", "dewp", "altim", "t", "raw"}
    assert all(always <= set(row) <= always | {"vrb", "visp"} for row in metars.values())


def test_ceiling_reads_every_cloud_layer(metars):
    # KAUS reports SCT040 SCT050 BKN100 BKN200: the ceiling is the third of four layers.
    assert metars["KAUS"]["ceil"] == 10000
    assert metars["KAUS"]["sky"] == [{"cover": "SCT", "base": 4000}, {"cover": "SCT", "base": 5000},
                                     {"cover": "BKN", "base": 10000}, {"cover": "BKN", "base": 20000}]
    assert metars["KMCI"]["ceil"] is None
    # Vertical visibility arrives as an OVX layer.
    assert metars["KPJC"]["ceil"] == 500


def test_variable_wind_comes_from_the_report_text(metars):
    for station in ("K40B", "KGWB", "KCPC"):
        assert metars[station]["wdir"] is None and metars[station]["vrb"] is True
    assert metars["KGWB"]["wspd"] == 1
    # Calm is direction zero at speed zero, and is not variable.
    assert metars["KEWB"]["wdir"] == 0 and metars["KEWB"]["wspd"] == 0 and "vrb" not in metars["KEWB"]
    assert all(row["wdir"] is None and " VRB" in row["raw"] for row in metars.values() if row.get("vrb"))


def test_missing_flight_category_stays_missing(metars):
    assert metars["K40B"]["cat"] is None
    assert sum(1 for row in metars.values() if row["cat"] is None) == 72
    assert {row["cat"] for row in metars.values()} == {"VFR", "MVFR", "IFR", "LIFR", None}


def test_visibility_or_more_is_a_number_and_a_flag(metars):
    assert metars["KTVF"]["vis"] == 10 and metars["KTVF"]["visp"] is True
    assert metars["KEWB"]["vis"] == 2 and "visp" not in metars["KEWB"]
    assert metars["K40B"]["vis"] is None


def test_a_changed_column_layout_is_refused(us):
    text = gzip.decompress(READ(awc.CACHE + "metars.cache.csv.gz")).decode()
    moved = text.replace("raw_text,station_id", "station_id,raw_text", 1)
    with pytest.raises(awc.BadSource, match="layout"):
        awc.metars_json(gzip.compress(moved.encode()), us)


def test_a_cut_off_metar_file_is_refused(us):
    text = gzip.decompress(READ(awc.CACHE + "metars.cache.csv.gz")).decode()
    short = "\n".join(text.split("\n")[:200])
    with pytest.raises(awc.BadSource, match="only"):
        awc.metars_json(gzip.compress(short.encode()), us)


def test_a_metar_file_that_stopped_changing_is_refused(us):
    body = READ(awc.CACHE + "metars.cache.csv.gz")
    assert len(json.loads(awc.metars_json(body, us, NOW))) == 2547
    with pytest.raises(awc.BadSource, match="newest"):
        awc.metars_json(body, us, NOW + timedelta(days=2))


def test_us_tafs_keep_raw_text_and_three_times(us):
    tafs = {taf["id"]: taf for taf in json.loads(awc.tafs_json(READ(awc.CACHE + "tafs.cache.xml.gz"), us))}
    assert len(tafs) == 768
    assert "CYPR" not in tafs
    kaus = tafs["KAUS"]
    assert set(kaus) == {"id", "issued", "from", "to", "raw", "groups"}
    assert (kaus["issued"], kaus["from"], kaus["to"]) == (
        "2026-10-12T23:38:00Z", "2026-10-13T00:00:00Z", "2026-10-14T06:00:00Z")
    assert kaus["raw"].startswith("TAF KAUS 122338Z 1300/1406 14012KT P6SM")


def test_a_bad_envelope_is_refused(us):
    one = "<TAF><raw_text>TAF KAUS</raw_text><station_id>KAUS</station_id></TAF>"
    for body in (
        "<html>Service Unavailable</html>",
        f"<response><errors><error>busy</error></errors><data num_results='1'>{one}</data></response>",
        f"<response><errors/><data num_results='2'>{one}</data></response>",
        "<response><errors/></response>",
    ):
        with pytest.raises(awc.BadSource):
            awc.tafs_json(gzip.compress(body.encode()), us)
