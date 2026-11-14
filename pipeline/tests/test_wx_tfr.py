import json
from pathlib import Path

import pytest

from wxpipe import awc, tfr

FIX = Path(__file__).parent / "fixtures" / "wx"
READ = awc.offline(FIX)
LISTED = {item["notam_id"]: item for item in json.loads((FIX / "getTfrList").read_text())}
FLOOR = tfr.MIN_NOTICES


@pytest.fixture(autouse=True)
def short_list_allowed(monkeypatch):
    # The saved list holds three notices. The real floor has its own test below.
    monkeypatch.setattr(tfr, "MIN_NOTICES", 1)


def detail(notam):
    return tfr.features(LISTED[notam], (FIX / f"detail_{notam.replace('/', '_')}.xml").read_bytes())


def test_coordinates_carry_their_hemisphere():
    assert tfr.degrees("114.08W") == -114.08
    assert tfr.degrees("46.95109625N") == 46.95109625
    assert tfr.degrees("144.5E") == 144.5
    assert tfr.degrees("13.25S") == -13.25
    with pytest.raises(ValueError):
        tfr.degrees("114.08")


@pytest.mark.parametrize("body", [
    b"[]", b'{"error": "busy"}', b"<html>Service Unavailable</html>",
    b'[{"notam_id": "6/9020"}]', b'[{"notam_id": "../../x", "mod_abs_time": "202610121625"}]',
    b'[{"notam_id": "6/9020", "mod_abs_time": "../x"}]',
])
def test_a_list_of_the_wrong_shape_is_refused(body):
    with pytest.raises(awc.BadSource):
        tfr.parse_list(body)


def test_a_list_cut_to_a_few_notices_is_refused(monkeypatch):
    monkeypatch.setattr(tfr, "MIN_NOTICES", FLOOR)
    assert FLOOR >= 20
    with pytest.raises(awc.BadSource, match="only 3"):
        tfr.parse_list((FIX / "getTfrList").read_bytes())


def test_each_drawn_area_is_one_feature_with_its_own_times_and_altitudes():
    areas = detail("6/8927")
    assert [a["properties"]["name"] for a in areas] == ["Area A", "Area B", "Area C", "Area D"]
    assert all(a["geometry"]["type"] == "Polygon" for a in areas)
    first = areas[0]["properties"]
    assert first == {
        "notam": "6/8927", "kind": "VIP", "facility": "ZSE", "state": "MT",
        "title": "Kalispell, MT, Wednesday, October 14, 2026 through Wednesday, October 14, 2026 Local",
        "rule": "91.141", "issued": "2026-10-12T10:55:57Z", "name": "Area A",
        "upper_value": 17999, "upper_unit": "FT", "upper_ref": "MSL",
        "lower_value": 0, "lower_unit": "FT", "lower_ref": "AGL",
        "effective": "2026-10-14T22:30:00Z", "expires": "2026-10-15T02:30:00Z",
    }
    assert (areas[2]["properties"]["effective"], areas[2]["properties"]["expires"]) == (
        "2026-10-15T01:00:00Z", "2026-10-15T04:00:00Z")
    ring = areas[0]["geometry"]["coordinates"][0]
    assert len(ring) == 73 and ring[0] == ring[-1] == [-114.29305556, 48.83099901]
    assert len(areas[3]["geometry"]["coordinates"][0]) == 37


def test_times_are_utc_whatever_zone_the_notice_names():
    # This notice says MDT, and its times are still UTC.
    area = detail("6/9020")[0]["properties"]
    assert (area["effective"], area["expires"]) == ("2026-10-15T00:55:00Z", "2026-10-15T03:05:00Z")
    assert (area["upper_value"], area["upper_unit"], area["upper_ref"]) == (2000, "FT", "AGL")


def test_a_notice_with_no_drawn_area_and_no_expiry_is_still_listed():
    found = detail("0/0367")
    assert len(found) == 1 and found[0]["geometry"] is None
    assert found[0]["properties"]["effective"] == "2020-01-15T00:01:00Z"
    assert found[0]["properties"]["expires"] is None
    assert found[0]["properties"]["upper_value"] is None and found[0]["properties"]["name"] is None


def test_a_vertex_that_is_not_a_plain_point_is_refused():
    xml = (FIX / "detail_6_9020.xml").read_bytes().replace(b"<codeType>GRC</codeType>", b"<codeType>CWA</codeType>", 1)
    with pytest.raises(awc.BadSource, match="CWA"):
        tfr.features(LISTED["6/9020"], xml)
    with pytest.raises(awc.BadSource):
        tfr.features(LISTED["6/9020"], b"<html>gone</html>")


def test_an_area_with_corner_points_and_no_merged_outline_is_refused():
    xml = (FIX / "detail_6_9020.xml").read_bytes().replace(b"abdMergedArea", b"abdOther")
    with pytest.raises(awc.BadSource, match="outline"):
        tfr.features(LISTED["6/9020"], xml)


def test_details_are_fetched_once_and_a_dropped_notice_leaves_the_cache(tmp_path):
    calls = []

    def fetch(url):
        calls.append(url)
        return READ(url)

    first = json.loads(tfr.build(fetch, tmp_path))
    assert first["type"] == "FeatureCollection" and len(first["features"]) == 6
    assert [f["properties"]["notam"] for f in first["features"]] == ["6/9020"] + ["6/8927"] * 4 + ["0/0367"]
    assert len(calls) == 4
    (tmp_path / "tfr" / "1_0001_202601010000.xml").write_bytes(b"old")
    assert json.loads(tfr.build(fetch, tmp_path)) == first
    assert len(calls) == 5 and calls[-1] == tfr.LIST
    assert sorted(p.name for p in (tmp_path / "tfr").iterdir()) == [
        "0_0367_202001022307.xml", "6_8927_202610121055.xml", "6_9020_202610121625.xml"]


def test_a_detail_cut_short_on_disk_is_fetched_again(tmp_path):
    calls = []

    def fetch(url):
        calls.append(url)
        return READ(url)

    first = tfr.build(fetch, tmp_path)
    saved = tmp_path / "tfr" / "6_9020_202610121625.xml"
    whole = saved.read_bytes()
    saved.write_bytes(b"")
    calls.clear()
    assert tfr.build(fetch, tmp_path) == first
    assert calls == [tfr.LIST, tfr.DETAIL.format("6_9020")] and saved.read_bytes() == whole


def test_one_unreadable_notice_is_listed_without_a_shape_and_the_rest_still_go_out(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(awc, "DEGRADED", [])

    def fetch(url):
        body = READ(url)
        return body.replace(b"<codeType>GRC</codeType>", b"<codeType>CWA</codeType>") if "detail_6_9020" in url else body

    found = json.loads(tfr.build(fetch, tmp_path))["features"]
    assert [f["properties"]["notam"] for f in found] == ["6/9020"] + ["6/8927"] * 4 + ["0/0367"]
    odd = found[0]
    assert odd["geometry"] is None and odd["properties"]["unreadable"] is True
    assert odd["properties"]["issued"] == "2026-10-12T16:25:00Z" and odd["properties"]["expires"] is None
    assert all(f["geometry"] for f in found[1:5])
    assert awc.DEGRADED == ["tfrs"] and "tfr 6/9020 unreadable" in capsys.readouterr().err
    assert not (tmp_path / "tfr" / "6_9020_202610121625.xml").exists()


def test_most_notices_unreadable_fails_the_source(tmp_path):
    with pytest.raises(awc.BadSource, match="3 of 3"):
        tfr.build(lambda url: READ(url) if url == tfr.LIST else b"<html>busy</html>", tmp_path)


def test_one_failed_detail_download_is_listed_unread_and_the_rest_still_go_out(tmp_path, monkeypatch):
    monkeypatch.setattr(awc, "DEGRADED", [])

    def fetch(url):
        if "detail_6_8927" in url:
            raise OSError("no answer")
        return READ(url)

    found = json.loads(tfr.build(fetch, tmp_path))["features"]
    assert [f["properties"]["notam"] for f in found] == ["6/9020", "6/8927", "0/0367"]
    assert found[1]["geometry"] is None and found[1]["properties"]["unreadable"] is True
    assert found[0]["geometry"] and awc.DEGRADED == ["tfrs"]


def test_failing_detail_downloads_stop_being_tried_once_they_have_cost_a_minute(tmp_path, monkeypatch):
    clock = [0.0]
    monkeypatch.setattr(tfr.time, "monotonic", lambda: clock[0])
    asked = []

    def fetch(url):
        if url == tfr.LIST:
            return READ(url)
        asked.append(url)
        clock[0] += 61
        raise OSError("timed out")

    with pytest.raises(awc.BadSource, match="3 of 3"):
        tfr.build(fetch, tmp_path)
    assert len(asked) == 1
