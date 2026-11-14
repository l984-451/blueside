import http.client
import io
import json
import urllib.error
import zipfile

import pytest

from chartpipe import faa
from navpipe import nasr

INDEX_HTML = """
<h2>Preview</h2>
<ul>
    <li><a href="./../NASR_Subscription/2026-10-29">Subscription effective October 29, 2026</a></li>
</ul>
<h2>Current</h2>
<ul>
    <li><a href="./../NASR_Subscription/2026-10-01">Subscription effective October 01, 2026</a></li>
    <li><a href="./../NASR_Subscription/2026-10-01">the same cycle again</a></li>
</ul>
"""


def test_cycles_are_found_once_each_in_date_order():
    assert nasr.parse_cycles(INDEX_HTML) == ["2026-10-01", "2026-10-29"]


def test_page_with_no_cycle_links_gives_nothing():
    assert nasr.parse_cycles("<html>maintenance</html>") == []


def test_a_cycle_lasts_28_days_from_0901_utc():
    effective, expires = nasr.cycle_dates("2026-10-01")
    assert faa.iso(effective) == "2026-10-01T09:01:00Z"
    assert faa.iso(expires) == "2026-10-29T09:01:00Z"


def test_cycle_length_can_be_given():
    assert faa.iso(nasr.cycle_dates("2026-09-03", days=56)[1]) == "2026-10-29T09:01:00Z"


def test_file_addresses_use_each_files_own_date_format():
    assert nasr.csv_url("2026-10-01") == "https://nfdc.faa.gov/webContent/28DaySub/extra/01_Oct_2026_CSV.zip"
    assert nasr.csv_url("2026-10-29") == "https://nfdc.faa.gov/webContent/28DaySub/extra/29_Oct_2026_CSV.zip"
    assert nasr.airspace_url("2026-10-01") == (
        "https://nfdc.faa.gov/webContent/28DaySub/2026-10-01/class_airspace_shape_files.zip")


class Reply:
    def __init__(self, status):
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *error):
        return False


def test_exists_asks_for_one_byte_with_get(monkeypatch):
    seen = []

    def fake(request, timeout):
        seen.append(request)
        return Reply(206)

    monkeypatch.setattr(nasr.urllib.request, "urlopen", fake)
    assert nasr.exists(nasr.csv_url("2026-10-01")) is True
    assert seen[0].get_method() == "GET"
    assert seen[0].get_header("Range") == "bytes=0-0"


def test_a_missing_file_is_reported_as_absent(monkeypatch):
    def fake(request, timeout):
        raise urllib.error.HTTPError(request.full_url, 404, "Not Found", None, None)

    monkeypatch.setattr(nasr.urllib.request, "urlopen", fake)
    assert nasr.exists(nasr.csv_url("2026-11-26")) is False


def test_a_server_error_is_not_mistaken_for_absent(monkeypatch):
    def fake(request, timeout):
        raise urllib.error.HTTPError(request.full_url, 503, "Service Unavailable", None, None)

    monkeypatch.setattr(nasr.urllib.request, "urlopen", fake)
    with pytest.raises(urllib.error.HTTPError):
        nasr.exists(nasr.csv_url("2026-10-01"))


def test_download_retries_a_failure_and_keeps_a_finished_file(tmp_path, monkeypatch):
    calls = []

    def fake(url):
        calls.append(url)
        if len(calls) == 1:
            raise OSError("connection reset")
        return b"PK\x03\x04data"

    monkeypatch.setattr(nasr.faa, "fetch", fake)
    monkeypatch.setattr(nasr.time, "sleep", lambda seconds: None)
    target = tmp_path / "zips" / "a.zip"
    assert nasr.download("https://example.invalid/a.zip", target).read_bytes() == b"PK\x03\x04data"
    assert len(calls) == 2
    nasr.download("https://example.invalid/a.zip", target)
    assert len(calls) == 2
    assert list(target.parent.iterdir()) == [target]



def test_an_error_page_in_place_of_a_file_is_never_kept(tmp_path, monkeypatch):
    monkeypatch.setattr(nasr.faa, "fetch", lambda url: b"<html>Service Unavailable</html>")
    for name in ("a.zip", "05396AD.PDF", "meta.xml"):
        with pytest.raises(ValueError, match="not a"):
            nasr.download(f"https://example.invalid/{name}", tmp_path / name)
    assert list(tmp_path.iterdir()) == []
    monkeypatch.setattr(nasr.faa, "fetch", lambda url: b"\xef\xbb\xbf<?xml version='1.0'?><digital_tpp/>")
    assert nasr.download("https://example.invalid/meta.xml", tmp_path / "meta.xml").exists()

def zip_bytes(files):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, body in files.items():
            archive.writestr(name, body)
    return buffer.getvalue()


def test_fetch_cycle_unpacks_tables_and_shapes(tmp_path, monkeypatch):
    bodies = {
        nasr.csv_url("2026-10-01"): zip_bytes({"APT_BASE.csv": "x", "APT DATA LAYOUT.pdf": "y"}),
        nasr.airspace_url("2026-10-01"): zip_bytes({"Shape_Files/Class_Airspace.shp": "z"}),
    }
    monkeypatch.setattr(nasr.faa, "fetch", lambda url: bodies[url])
    csv_dir, shp = nasr.fetch_cycle("2026-10-01", tmp_path)
    assert [p.name for p in csv_dir.iterdir()] == ["APT_BASE.csv"]
    assert shp.name == "Class_Airspace.shp" and shp.read_text() == "z"


def sua_replies(count, features):
    def fake(url):
        if url.endswith("?f=json"):
            return json.dumps({"editingInfo": {"dataLastEditDate": 1790603666108}}).encode()
        if "returnCountOnly=true" in url:
            return json.dumps({"count": count}).encode()
        return json.dumps({"type": "FeatureCollection", "features": [{}] * features}).encode()

    return fake


def test_sua_is_saved_with_the_time_its_source_last_changed(tmp_path, monkeypatch):
    monkeypatch.setattr(nasr.faa, "fetch", sua_replies(1542, 1542))
    assert nasr.fetch_sua(tmp_path / "sua.geojson") == "2026-09-28T13:54:26Z"
    assert len(json.loads((tmp_path / "sua.geojson").read_text())["features"]) == 1542


def test_a_cut_off_sua_answer_is_refused(tmp_path, monkeypatch):
    monkeypatch.setattr(nasr.faa, "fetch", sua_replies(2400, 2000))
    monkeypatch.setattr(nasr.time, "sleep", lambda seconds: None)
    with pytest.raises(ValueError):
        nasr.fetch_sua(tmp_path / "sua.geojson")
    assert not (tmp_path / "sua.geojson").exists()


def test_a_nearly_empty_sua_answer_is_refused(tmp_path, monkeypatch):
    monkeypatch.setattr(nasr.faa, "fetch", sua_replies(3, 3))
    with pytest.raises(ValueError):
        nasr.fetch_sua(tmp_path / "sua.geojson")


def test_sua_download_is_retried_after_a_cut_connection(tmp_path, monkeypatch):
    answer, cut = sua_replies(1542, 1542), []

    def fake(url):
        if url.endswith("f=geojson") and not cut:
            cut.append(url)
            raise http.client.IncompleteRead(b"")
        return answer(url)

    monkeypatch.setattr(nasr.faa, "fetch", fake)
    monkeypatch.setattr(nasr.time, "sleep", lambda seconds: None)
    assert nasr.fetch_sua(tmp_path / "sua.geojson") == "2026-09-28T13:54:26Z"
    assert len(json.loads((tmp_path / "sua.geojson").read_text())["features"]) == 1542
    assert len(cut) == 1


def test_an_error_body_is_asked_again_before_the_cycle_fails(tmp_path, monkeypatch):
    answer, errors = sua_replies(1542, 1542), []

    def fake(url):
        if url.endswith("f=geojson") and not errors:
            errors.append(url)
            return json.dumps({"error": {"code": 500}}).encode()
        return answer(url)

    monkeypatch.setattr(nasr.faa, "fetch", fake)
    monkeypatch.setattr(nasr.time, "sleep", lambda seconds: None)
    assert nasr.fetch_sua(tmp_path / "sua.geojson") == "2026-09-28T13:54:26Z"
    assert len(errors) == 1


def test_pending_sua_is_read_from_the_pending_service_only(tmp_path, monkeypatch):
    answer, asked = sua_replies(1545, 1545), []

    def fake(url):
        asked.append(url)
        return answer(url)

    monkeypatch.setattr(nasr.faa, "fetch", fake)
    nasr.fetch_sua(tmp_path / "sua.geojson", pending=True)
    assert len(asked) == 3
    assert all("/Pending_Special_Use_Airspace/FeatureServer/0" in url for url in asked)
