import gzip
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from wxpipe import awc

FIX = Path(__file__).parent / "fixtures" / "wx"
READ = awc.offline(FIX)
NOW = datetime(2026, 10, 13, 0, 35, tzinfo=timezone.utc)


def features(body):
    value = json.loads(body)
    assert value["type"] == "FeatureCollection"
    return value["features"]


def test_sigmets_become_closed_areas_with_their_period():
    found = features(awc.sigmets_geojson(READ(awc.CACHE + "airsigmets.cache.xml.gz")))
    assert len(found) == 6
    first = found[0]
    ring = first["geometry"]["coordinates"][0]
    assert first["geometry"]["type"] == "Polygon" and len(ring) == 5
    assert ring[0] == ring[-1] == [-112.275, 41.894]
    raw = first["properties"].pop("raw")
    assert raw.startswith("WSUS33 KKCI 122355") and "CONVECTIVE SIGMET 54W" in raw
    assert first["properties"] == {
        "hazard": "CONVECTIVE", "severity": "SEV", "kind": "SIGMET",
        "from": "2026-10-12T23:55:00Z", "to": "2026-10-13T01:55:00Z", "base_ft": None, "top_ft": 28000}


def test_no_sigmets_is_an_empty_collection_and_a_broken_answer_is_refused():
    quiet = gzip.compress(b'<response><errors/><data num_results="0"/></response>')
    assert features(awc.sigmets_geojson(quiet)) == []
    for broken in (
        b"<html>busy</html>",
        b'<response><errors><error>x</error></errors><data num_results="0"/></response>',
        b'<response><errors/><data num_results="3"/></response>',
        b'<response><errors/><data num_results="1"><AIRSIGMET><raw_text>x</raw_text></AIRSIGMET></data></response>',
    ):
        with pytest.raises(awc.BadSource):
            awc.sigmets_geojson(gzip.compress(broken))


def test_gairmets_keep_areas_and_lines_apart_and_carry_their_valid_time():
    found = features(awc.gairmets_geojson(READ(awc.CACHE + "gairmets.cache.xml.gz")))
    assert len(found) == 148
    kinds = [f["geometry"]["type"] for f in found]
    assert kinds.count("Polygon") == 117 and kinds.count("LineString") == 31
    by_time = {}
    for f in found:
        by_time[f["properties"]["valid"]] = by_time.get(f["properties"]["valid"], 0) + 1
    assert by_time == {"2026-10-12T21:00:00Z": 31, "2026-10-13T00:00:00Z": 29, "2026-10-13T03:00:00Z": 27,
                       "2026-10-13T06:00:00Z": 29, "2026-10-13T09:00:00Z": 32}
    area = found[0]
    assert area["properties"] == {
        "product": "TANGO", "tag": "4W", "hazard": "TURB-HI", "severity": "MOD",
        "issued": "2026-10-12T22:18:00Z", "valid": "2026-10-13T00:00:00Z", "expires": "2026-10-13T03:00:00Z",
        "due_to": "MTN WAVE", "base": "34000", "top": "45000", "level": None, "fzl_base": None, "fzl_top": None}
    ring = area["geometry"]["coordinates"][0]
    assert len(ring) == 9 and ring[0] == ring[-1] == [-102.4055, 42.7358]
    line = next(f for f in found if f["geometry"]["type"] == "LineString")
    assert line["properties"]["hazard"] == "FZLVL" and line["properties"]["level"] == "16000"
    assert line["properties"]["base"] is None and line["properties"]["severity"] is None
    points = line["geometry"]["coordinates"]
    assert len(points) == 15 and points[0] == [-63.5002, 20.2474] and points[0] != points[-1]


def test_a_gairmet_file_with_no_records_or_one_that_stopped_changing_is_refused():
    # Freezing level lines are part of every issue, so an empty file is a broken one.
    with pytest.raises(awc.BadSource, match="no records"):
        awc.gairmets_geojson(gzip.compress(b'<response><errors/><data num_results="0"/></response>'))
    body = READ(awc.CACHE + "gairmets.cache.xml.gz")
    assert len(features(awc.gairmets_geojson(body, NOW))) == 148
    with pytest.raises(awc.BadSource, match="newest"):
        awc.gairmets_geojson(body, NOW + timedelta(hours=8))


@pytest.mark.parametrize("text,expected", [
    ("04000", "4000"), ("SFC00", "SFC"), ("SFC", "SFC"), ("FZL", "FZL"),
    ("null00", None), ("-1", None), ("", None), (None, None)])
def test_altitude_text_is_cleaned(text, expected):
    assert awc._level(text) == expected


def test_pilot_reports_leave_out_the_oceanic_position_reports():
    reports = json.loads(awc.pireps_json(READ(awc.CACHE + "aircraftreports.cache.xml.gz")))
    assert len(reports) == 122 and sum(r["urgent"] for r in reports) == 5
    den = next(r for r in reports if r["raw"].startswith("DEN UA /OV DEN/TM 0024"))
    assert den == {"t": "2026-10-13T00:24:00Z", "lat": 39.8125, "lon": -104.6607, "alt": None, "urgent": False,
                   "acft": "B38M", "turb": "NEG", "ice": None, "raw": den["raw"]}
    apa = next(r for r in reports if r["raw"].startswith("APA UUA"))
    assert apa["urgent"] is True and apa["alt"] == 6800 and apa["turb"] == "LGT"
    # The feed writes 0 feet for "during descent" and "unknown".
    assert sum(1 for r in reports if r["alt"] is None) == 9


def test_pilot_reports_that_stopped_being_readable_are_refused():
    text = gzip.decompress(READ(awc.CACHE + "aircraftreports.cache.xml.gz"))
    for old, new in ((b"observation_time>", b"obs_time>"), (b"report_type>", b"kind>")):
        with pytest.raises(awc.BadSource):
            awc.pireps_json(gzip.compress(text.replace(old, new)))
    # Oceanic position reports arrive around the clock, so a file with no records is a broken one.
    with pytest.raises(awc.BadSource):
        awc.pireps_json(gzip.compress(b'<response><errors/><data num_results="0"></data></response>'))


def test_only_the_two_pilot_report_types_are_kept():
    text = gzip.decompress(READ(awc.CACHE + "aircraftreports.cache.xml.gz"))
    renamed = text.replace(b"<report_type>AIREP<", b"<report_type>POSITION<")
    assert len(json.loads(awc.pireps_json(gzip.compress(renamed)))) == 122
    only_oceanic = (b'<response><errors/><data num_results="1"><AircraftReport>'
                    b"<report_type>AIREP</report_type></AircraftReport></data></response>")
    assert json.loads(awc.pireps_json(gzip.compress(only_oceanic))) == []


def built_report(entries: str) -> dict:
    body = ('<response><errors/><data num_results="1"><AircraftReport>'
            "<raw_text>ABC UA /OV ABC/TM 0001/FL100/TP C172</raw_text>"
            "<observation_time>2026-10-13T00:01:00Z</observation_time>"
            "<latitude>40.0</latitude><longitude>-100.0</longitude><altitude_ft_msl>10000</altitude_ft_msl>"
            f"{entries}<report_type>PIREP</report_type></AircraftReport></data></response>")
    return json.loads(awc.pireps_json(gzip.compress(body.encode())))[0]


def test_a_pilot_report_with_two_intensities_shows_the_worse_one():
    reports = json.loads(awc.pireps_json(READ(awc.CACHE + "aircraftreports.cache.xml.gz")))
    vgt = next(r for r in reports if r["raw"].startswith("VGT UA /OV LAS303009/TM 2341"))
    assert vgt["raw"].endswith("/TB OCNL LGT - MOD") and vgt["turb"] == "MOD"
    two = built_report('<turbulence_condition turbulence_intensity="MOD"/>'
                       '<turbulence_condition turbulence_intensity="SEV"/>'
                       '<icing_condition icing_intensity="MOD"/><icing_condition icing_intensity="TRC"/>')
    assert two["turb"] == "SEV" and two["ice"] == "MOD"
    # An entry with no intensity hides nothing, and a word not seen before is never ranked below a known one.
    odd = built_report('<turbulence_condition turbulence_type="CHOP"/>'
                       '<turbulence_condition turbulence_intensity="LGT"/>'
                       '<icing_condition icing_intensity="NEW"/><icing_condition icing_intensity="SEV"/>')
    assert odd["turb"] == "LGT" and odd["ice"] == "NEW"
    none = built_report('<turbulence_condition turbulence_type="CHOP"/>')
    assert none["turb"] is None and none["ice"] is None


def test_cwas_become_areas_with_their_center_and_period(monkeypatch):
    found = features(awc.cwas_geojson(READ(awc.CWAS)))
    assert len(found) == 2
    first = found[0]
    assert first["geometry"]["type"] == "Polygon"
    ring = first["geometry"]["coordinates"][0]
    assert ring[0] == ring[-1] == [-102.362, 37.587] and len(ring) == 7
    assert first["properties"].pop("raw").startswith("FAUS21 KZAB 130023")
    assert first["properties"] == {"cwsu": "ZAB", "series": "107", "hazard": "IFR", "qualifier": "WDSPRD LIFR",
                                   "from": "2026-10-13T00:23:00Z", "to": "2026-10-13T02:15:00Z",
                                   "base_ft": None, "top_ft": None}
    # None out is a 204 with no body.
    assert features(awc.cwas_geojson(b"")) == []
    monkeypatch.setattr(awc, "DEGRADED", [])
    one = [{"cwsu": "ZFW", "validTimeFrom": 0, "validTimeTo": 60, "coords": [{"lat": "1", "lon": "2"}]}]
    assert features(awc.cwas_geojson(json.dumps(one).encode())) == [] and awc.DEGRADED == ["cwas"]
