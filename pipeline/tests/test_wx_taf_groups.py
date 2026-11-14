import gzip
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from wxpipe import awc

FIX = Path(__file__).parent / "fixtures" / "wx"
READ = awc.offline(FIX)
NOW = datetime(2026, 10, 13, 0, 35, tzinfo=timezone.utc)
GROUP_KEYS = {"from", "to", "kind", "prob", "becoming", "wdir", "vrb", "wspd", "gust", "vis", "visp", "wx", "sky",
              "vv", "ws"}


@pytest.fixture(scope="module")
def tafs():
    us = awc.us_ids(READ(awc.CACHE + "stations.cache.json.gz"))
    rows = json.loads(awc.tafs_json(READ(awc.CACHE + "tafs.cache.xml.gz"), us))
    return {row["id"]: row for row in rows}


def test_every_us_taf_carries_its_forecast_periods_in_time_order(tafs):
    assert len(tafs) == 768
    assert all(taf.get("groups") for taf in tafs.values())
    assert sum(len(taf["groups"]) for taf in tafs.values()) == 2894
    for taf in tafs.values():
        starts = [group["from"] for group in taf["groups"]]
        assert starts == sorted(starts), taf["id"]
        assert len([group for group in taf["groups"] if "kind" not in group]) == 1, taf["id"]
        for group in taf["groups"]:
            assert set(group) <= GROUP_KEYS, taf["id"]
            assert None not in group.values(), taf["id"]
            assert taf["from"] <= group["from"] < group["to"] <= taf["to"], taf["id"]


def test_groups_keep_what_each_period_states(tafs):
    kaus = tafs["KAUS"]["groups"]
    assert [group.get("kind") for group in kaus] == [None, "FM", "FM", "FM", "FM", "FM"]
    assert kaus[0] == {"from": "2026-10-13T00:00:00Z", "to": "2026-10-13T01:00:00Z", "wdir": 140, "wspd": 12,
                       "vis": 6, "visp": True,
                       "sky": [{"cover": "SCT", "base": 4500}, {"cover": "SCT", "base": 10000},
                               {"cover": "BKN", "base": 20000}]}
    assert kaus[4] == {"from": "2026-10-13T18:00:00Z", "to": "2026-10-14T00:00:00Z", "kind": "FM", "wdir": 180,
                       "wspd": 11, "gust": 21, "vis": 6, "visp": True,
                       "sky": [{"cover": "BKN", "base": 4000}, {"cover": "BKN", "base": 15000}]}
    # A TEMPO group states only what changes. No wind and no sky here, and none is made up.
    assert tafs["KABE"]["groups"][2] == {"from": "2026-10-13T10:00:00Z", "to": "2026-10-13T13:00:00Z",
                                         "kind": "TEMPO", "vis": 2, "wx": "BR"}
    # Calm is a real zero.
    assert tafs["KABE"]["groups"][1]["wdir"] == 0 and tafs["KABE"]["groups"][1]["wspd"] == 0
    assert tafs["KBOS"]["groups"][4] == {"from": "2026-10-13T08:00:00Z", "to": "2026-10-13T11:00:00Z",
                                         "kind": "PROB", "prob": 30, "vis": 4, "wx": "-SHRA BR",
                                         "sky": [{"cover": "OVC", "base": 600}]}
    kdov = tafs["KDOV"]["groups"]
    assert kdov[1] == {"from": "2026-10-13T10:00:00Z", "to": "2026-10-13T13:00:00Z", "kind": "BECMG",
                       "becoming": "2026-10-13T12:00:00Z", "wdir": 240, "wspd": 6, "vis": 2.98, "wx": "BR",
                       "sky": [{"cover": "FEW", "base": 1500}]}
    assert kdov[2]["sky"] == [{"cover": "SKC"}] and kdov[2]["wx"] == "NSW"
    assert tafs["KCRW"]["groups"][2] == {"from": "2026-10-13T05:00:00Z", "to": "2026-10-13T13:00:00Z", "kind": "FM",
                                         "wdir": 0, "wspd": 0, "vis": 0.25, "wx": "FG",
                                         "sky": [{"cover": "OVX"}], "vv": 100}


def test_wind_shear_is_read_from_the_report_text_onto_its_period(tafs):
    # FM130300 33003KT P6SM BKN090 WS019/25025KT FM130600 VRB03KT P6SM BKN045 WS020/26025KT
    kgrb = {group["from"]: group for group in tafs["KGRB"]["groups"] if group.get("kind") == "FM"}
    assert kgrb["2026-10-13T03:00:00Z"] == {"from": "2026-10-13T03:00:00Z", "to": "2026-10-13T06:00:00Z",
                                            "kind": "FM", "wdir": 330, "wspd": 3, "vis": 6, "visp": True,
                                            "sky": [{"cover": "BKN", "base": 9000}],
                                            "ws": {"hgt": 1900, "dir": 250, "spd": 25}}
    assert kgrb["2026-10-13T06:00:00Z"]["ws"] == {"hgt": 2000, "dir": 260, "spd": 25}
    assert "ws" not in kgrb["2026-10-13T08:00:00Z"]
    # BECMG 1302/1303 21006KT 9999 FEW150 WS020/24035KT
    kblv = tafs["KBLV"]["groups"]
    assert kblv[1]["kind"] == "BECMG" and kblv[1]["ws"] == {"hgt": 2000, "dir": 240, "spd": 35}
    assert [("ws" in group) for group in kblv] == [False, True, False, False]
    assert not any("ws" in group for group in tafs["KAUS"]["groups"])
    # Every wind shear token in the saved file is on a period, and none sits in a TEMPO or PROB period.
    tokens = sum(taf["raw"].count(" WS0") for taf in tafs.values())
    carried = [group for taf in tafs.values() for group in taf["groups"] if "ws" in group]
    assert tokens == len(carried) == 59
    assert {group.get("kind") for group in carried} == {None, "FM", "BECMG"}


def test_a_cumulonimbus_layer_keeps_its_mark(tafs):
    # TEMPO 1302/1305 6SM -TSRA SCT040 BKN060CB OVC090
    assert tafs["KFNT"]["groups"][1]["sky"] == [{"cover": "SCT", "base": 4000},
                                                {"cover": "BKN", "base": 6000, "type": "CB"},
                                                {"cover": "OVC", "base": 9000}]
    layers = [layer for taf in tafs.values() for group in taf["groups"] for layer in group.get("sky", [])]
    assert [layer["type"] for layer in layers if "type" in layer] == ["CB"] * 59


def forecast(start, end, inner=""):
    return (f"<forecast><fcst_time_from>2026-10-13T{start}:00:00Z</fcst_time_from>"
            f"<fcst_time_to>2026-10-13T{end}:00:00Z</fcst_time_to>{inner}</forecast>")


def one(monkeypatch, *forecasts, raw="TAF KAUS 122338Z"):
    """The published object for one hand-made TAF."""
    monkeypatch.setattr(awc, "MIN_TAFS", 1)
    taf = (f"<TAF><raw_text>{raw}</raw_text><station_id>KAUS</station_id>"
           "<issue_time>2026-10-12T23:38:00Z</issue_time><valid_time_from>2026-10-13T00:00:00Z</valid_time_from>"
           "<valid_time_to>2026-10-14T06:00:00Z</valid_time_to>" + "".join(forecasts) + "</TAF>")
    body = gzip.compress(f"<response><errors/><data num_results='1'>{taf}</data></response>".encode())
    return json.loads(awc.tafs_json(body, {"KAUS"}))[0]


SHEAR_PERIODS = (forecast("00", "06"),
                 forecast("02", "04", "<change_indicator>TEMPO</change_indicator><wx_string>-RA</wx_string>"),
                 forecast("06", "12", "<change_indicator>FM</change_indicator>"))


def test_wind_shear_goes_to_the_opening_period_or_the_from_period_that_states_it(monkeypatch):
    raw = ("TAF KAUS 122338Z 1300/1312 18005KT P6SM SKC WS015/20040KT TEMPO 1302/1304 -RA "
           "FM130600 VRB03KT WS008/090125KT")
    groups = one(monkeypatch, *SHEAR_PERIODS, raw=raw)["groups"]
    assert [group.get("ws") for group in groups] == [{"hgt": 1500, "dir": 200, "spd": 40}, None,
                                                     {"hgt": 800, "dir": 90, "spd": 125}]
    assert all("ws" not in group for group in one(monkeypatch, *SHEAR_PERIODS)["groups"])
    # A BECMG period is found by its start hour, however the text is spaced.
    becoming = forecast("06", "09", "<change_indicator>BECMG</change_indicator>"
                        "<time_becoming>2026-10-13T08:00:00Z</time_becoming>")
    raw = "TAF KAUS 122338Z 1300/1312 18005KT BECMG\n 1306/1308 VRB03KT WS015/20040KT"
    groups = one(monkeypatch, forecast("00", "06"), becoming, raw=raw)["groups"]
    assert [group.get("ws") for group in groups] == [None, {"hgt": 1500, "dir": 200, "spd": 40}]


@pytest.mark.parametrize("raw", [
    "TAF KAUS 122338Z 1300/1312 18005KT TEMPO 1302/1304 -RA WS015/20040KT FM130600 VRB03KT",
    "TAF KAUS 122338Z 1300/1312 18005KT PROB30 1302/1304 -RA WS015/20040KT FM130600 VRB03KT",
    "TAF KAUS 122338Z 1300/1312 18005KT FM130700 VRB03KT WS015/20040KT",
    "TAF KAUS 122338Z 1300/1312 18005KT BECMG 1306/1307 VRB03KT WS015/20040KT",
    "TAF KAUS 122338Z 1300/1312 18005KT WS015/VRB40KT FM130600 VRB03KT",
    "TAF KAUS 122338Z 1300/1312 18005KT WS015/20040KT WS020/21045KT FM130600 VRB03KT",
    "TAF KAUS 122338Z 1300/1312 18005KT FM1306 VRB03KT WS015/20040KT",
], ids=["in a tempo period", "in a prob period", "from period not in the file", "becoming period not in the file",
        "form not known", "stated twice", "a period start the text does not show"])
def test_wind_shear_that_cannot_be_put_on_a_period_leaves_the_text_and_no_groups(monkeypatch, raw):
    taf = one(monkeypatch, *SHEAR_PERIODS, raw=raw)
    assert "groups" not in taf
    assert taf["raw"] == raw


def renamed(old: bytes, new: bytes) -> bytes:
    """The saved TAF file with one element name changed, as after a format change at the source."""
    return gzip.compress(gzip.decompress(READ(awc.CACHE + "tafs.cache.xml.gz")).replace(old, new))


def test_periods_unreadable_in_most_forecasts_mark_the_source_as_degraded(monkeypatch):
    monkeypatch.setattr(awc, "DEGRADED", [])
    us = awc.us_ids(READ(awc.CACHE + "stations.cache.json.gz"))
    good = json.loads(awc.tafs_json(READ(awc.CACHE + "tafs.cache.xml.gz"), us))
    assert awc.DEGRADED == []
    rows = json.loads(awc.tafs_json(renamed(b"fcst_time_from>", b"fcst_from>"), us))
    # The report text still goes out, so the forecasts stay readable. Only the decoded periods are gone.
    assert len(rows) == 768 and not any("groups" in row for row in rows)
    assert [row["raw"] for row in rows] == [row["raw"] for row in good]
    assert awc.DEGRADED == ["tafs"]


def test_a_taf_file_that_stopped_changing_is_refused():
    us = awc.us_ids(READ(awc.CACHE + "stations.cache.json.gz"))
    body = READ(awc.CACHE + "tafs.cache.xml.gz")
    assert len(json.loads(awc.tafs_json(body, us, NOW))) == 768
    assert len(json.loads(awc.tafs_json(body, us, NOW + timedelta(hours=6)))) == 768
    with pytest.raises(awc.BadSource, match="newest"):
        awc.tafs_json(body, us, NOW + timedelta(hours=8))


def test_a_value_the_source_leaves_out_is_left_out(monkeypatch):
    taf = one(monkeypatch,
              forecast("02", "04", "<change_indicator>TEMPO</change_indicator><wx_string>-RA</wx_string>"),
              forecast("00", "06", "<wind_dir_degrees>VRB</wind_dir_degrees><wind_speed_kt>3</wind_speed_kt>"))
    assert taf["groups"] == [
        {"from": "2026-10-13T00:00:00Z", "to": "2026-10-13T06:00:00Z", "vrb": True, "wspd": 3},
        {"from": "2026-10-13T02:00:00Z", "to": "2026-10-13T04:00:00Z", "kind": "TEMPO", "wx": "-RA"}]


def test_a_change_that_starts_with_a_from_period_is_listed_after_it(monkeypatch):
    becoming = forecast("06", "09", "<change_indicator>BECMG</change_indicator>"
                        "<time_becoming>2026-10-13T08:00:00Z</time_becoming>")
    start = forecast("06", "12", "<change_indicator>FM</change_indicator>")
    for periods in [(becoming, start), (start, becoming)]:
        taf = one(monkeypatch, forecast("00", "06"), *periods)
        assert [group.get("kind") for group in taf["groups"]] == [None, "FM", "BECMG"]


@pytest.mark.parametrize("period", [
    forecast("02", "04", "<change_indicator>RAPID</change_indicator>"),
    forecast("02", "04", "<change_indicator>BECMG</change_indicator>"),
    forecast("02", "04", "<change_indicator>FM</change_indicator><wind_speed_kt>fast</wind_speed_kt>"),
    forecast("02", "04", "<change_indicator>FM</change_indicator><wind_speed_kt>inf</wind_speed_kt>"),
    forecast("02", "04", "<change_indicator>PROB</change_indicator>"),
    forecast("04", "02", "<change_indicator>TEMPO</change_indicator>"),
    forecast("02", "04", "<change_indicator>FM</change_indicator><sky_condition cloud_base_ft_agl='900'/>"),
], ids=["unknown change word", "becoming without a time", "speed not a number", "speed is infinite",
        "probability missing", "ends before it starts", "layer without a cover"])
def test_a_period_that_cannot_be_read_leaves_the_text_and_no_groups(monkeypatch, period):
    taf = one(monkeypatch, forecast("00", "06"), period)
    assert "groups" not in taf
    assert taf["raw"] == "TAF KAUS 122338Z"


def test_a_taf_without_exactly_one_opening_period_has_no_groups(monkeypatch):
    assert "groups" not in one(monkeypatch)
    assert "groups" not in one(monkeypatch, forecast("00", "06"), forecast("06", "12"))
    assert "groups" not in one(monkeypatch, forecast("00", "06", "<change_indicator>FM</change_indicator>"))
