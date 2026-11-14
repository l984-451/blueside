import json
import sqlite3
import subprocess
import zipfile
import zlib
from datetime import datetime, timezone
from pathlib import Path

import pytest

from tppipe import __main__ as tpp_main
from tppipe import dtpp, pack, publish

from test_nav_publish import FakeStore

META = b"""<?xml version="1.0" encoding="utf-8"?>
<digital_tpp cycle="2611" from_edate="0901Z  10/29/26" to_edate="0901Z  11/26/26">
  <state_code ID="TX" state_fullname="TEXAS">
    <city_name ID="AUSTIN" volume="SC-3">
      <airport_name ID="AUSTIN-BERGSTROM INTL" military="N" apt_ident="AUS" icao_ident="KAUS" alnum="556">
        <record><chart_code>MIN</chart_code><chart_name>TAKEOFF MINIMUMS</chart_name>
          <useraction></useraction><pdf_name>SC3TO.PDF</pdf_name></record>
        <record><chart_code>APD</chart_code><chart_name>AIRPORT DIAGRAM</chart_name>
          <useraction></useraction><pdf_name>00556AD.PDF</pdf_name></record>
        <record><chart_code>IAP</chart_code><chart_name>ILS OR LOC RWY 18R</chart_name>
          <useraction></useraction><pdf_name>00556IL18R.PDF</pdf_name></record>
        <record><chart_code>IAP</chart_code><chart_name>VOR RWY 17L</chart_name>
          <useraction>D</useraction><pdf_name>DELETED_JOB.PDF</pdf_name></record>
      </airport_name>
      <airport_name ID="AUSTIN EXEC" military="N" apt_ident="EDC" icao_ident="" alnum="1">
        <record><chart_code>MIN</chart_code><chart_name>TAKEOFF MINIMUMS</chart_name>
          <useraction></useraction><pdf_name>SC3TO.PDF</pdf_name></record>
      </airport_name>
    </city_name>
  </state_code>
  <state_code ID="RI" state_fullname="RHODE ISLAND"></state_code>
</digital_tpp>"""


def pdf(pages: int = 1) -> bytes:
    kids = b"".join(b"%d 0 obj << /Type /Page /Parent 2 0 R >> endobj\n" % (3 + i) for i in range(pages))
    return b"%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\n2 0 obj << /Type /Pages /Count 1 >> endobj\n" + kids


def test_cycle_numbers_count_from_the_years_first_cycle():
    assert [dtpp.cycle_number(d) for d in ("2026-01-22", "2026-10-01", "2026-10-29", "2027-01-21")] == \
        ["2601", "2610", "2611", "2701"]
    html = '<a href="https://aeronav.faa.gov/upload_313-d/terminal/DDTPPA_261029.zip">x</a> DDTPPB_261029.zip ' \
           '"https://aeronav.faa.gov/upload_313-d/terminal/DDTPPA_261001.zip"'
    assert dtpp.parse_cycles(html) == ["2026-10-01", "2026-10-29"]
    assert dtpp.metafile_url("2026-10-29") == "https://aeronav.faa.gov/d-tpp/2611/xml_data/d-tpp_Metafile.xml"


def test_the_metafile_gives_live_charts_per_state():
    effective, states = dtpp.parse_metafile(META)
    assert effective == "0901Z  10/29/26"
    assert states["RI"] == []
    assert [(c["airport"], c["icao"], c["code"], c["file"]) for c in states["TX"]] == [
        ("AUS", "KAUS", "MIN", "SC3TO.PDF"), ("AUS", "KAUS", "APD", "00556AD.PDF"),
        ("AUS", "KAUS", "IAP", "00556IL18R.PDF"), ("EDC", "", "MIN", "SC3TO.PDF")]


def test_a_pack_holds_each_pdf_once_and_an_index_with_page_counts(tmp_path):
    _, states = dtpp.parse_metafile(META)
    files = {}
    for name, pages in (("SC3TO.PDF", 3), ("00556AD.PDF", 1), ("00556IL18R.PDF", 1)):
        files[name] = tmp_path / name
        files[name].write_bytes(pdf(pages))
    out = tmp_path / "TX.sqlite"
    assert pack.build(states["TX"], files, out, "2026-10-29") == 4
    db = sqlite3.connect(out)
    assert db.execute("SELECT count(*) FROM pdfs").fetchone() == (3,)
    assert db.execute("SELECT data FROM pdfs WHERE file='00556AD.PDF'").fetchone()[0] == pdf(1)
    index = json.loads(db.execute("SELECT value FROM meta WHERE name='index'").fetchone()[0])
    assert index[0] == {"airport": "AUS", "icao": "KAUS", "name": "TAKEOFF MINIMUMS", "code": "MIN",
                        "file": "SC3TO.PDF", "pages": 3}
    assert db.execute("SELECT value FROM meta WHERE name='cycle'").fetchone() == ("2026-10-29",)


def test_a_file_that_is_not_a_pdf_stops_the_pack(tmp_path):
    (tmp_path / "A.PDF").write_bytes(b"<html>error</html>")
    with pytest.raises(ValueError, match="not a PDF"):
        pack.build([{"airport": "A", "icao": "", "name": "n", "code": "APD", "file": "A.PDF"}],
                   {"A.PDF": tmp_path / "A.PDF"}, tmp_path / "X.sqlite", "2026-10-29")
    assert not (tmp_path / "X.sqlite").exists()


@pytest.fixture
def faa_site(monkeypatch):
    fetched = []

    def download(url, target, attempts=3):
        fetched.append(url)
        target.parent.mkdir(parents=True, exist_ok=True)
        if url.endswith("_CSV.zip"):
            with zipfile.ZipFile(target, "w") as archive:
                archive.writestr("APT_RWY_END.csv", "ARPT_ID,RWY_ID,RWY_END_ID,LAT_DECIMAL,LONG_DECIMAL\n")
        else:
            target.write_bytes(META if url.endswith(".xml") else pdf())
        return target

    monkeypatch.setattr(tpp_main.faa, "fetch", lambda url: b"DDTPPA_261029.zip")
    monkeypatch.setattr(tpp_main.nasr, "exists", lambda url: True)
    monkeypatch.setattr(tpp_main.nasr, "download", download)
    monkeypatch.setattr(dtpp.nasr, "download", download)
    return fetched


def test_one_state_builds_without_publishing(tmp_path, faa_site, capsys):
    assert tpp_main.main(["--work", str(tmp_path), "--state", "TX", "--no-publish"]) == 0
    assert (tmp_path / "out/2026-10-29/TX.sqlite").exists()
    assert sorted(u.rsplit("/", 1)[1] for u in faa_site) == ["00556AD.PDF", "00556IL18R.PDF", "29_Oct_2026_CSV.zip",
                                                            "SC3TO.PDF", "d-tpp_Metafile.xml"]
    assert "TX 4 charts" in capsys.readouterr().out


def test_a_part_cycle_is_never_published_and_a_national_build_needs_every_state(tmp_path, faa_site):
    with pytest.raises(SystemExit):
        tpp_main.main(["--work", str(tmp_path), "--state", "TX"])
    with pytest.raises(SystemExit, match="no charts for"):
        tpp_main.main(["--work", str(tmp_path), "--no-publish"])


def test_publishing_uploads_state_packs_then_the_plates_manifest_only(tmp_path):
    (tmp_path / "TX.sqlite").write_bytes(b"x")
    entry, files = publish.cycle_entry("2026-10-29", {"TX": tmp_path / "TX.sqlite"})
    assert entry["packs"][0]["path"] == "plates/2026-10-29/TX.sqlite"
    assert (entry["effective"], entry["expires"]) == ("2026-10-29T09:01:00Z", "2026-11-26T09:01:00Z")
    store = FakeStore()
    merged = publish.publish_plates(store, entry, files, datetime(2026, 10, 14, tzinfo=timezone.utc))
    assert store.client.calls == [("get", "plates/manifest.json"), ("upload", "plates/2026-10-29/TX.sqlite"),
                                  ("get", "plates/manifest.json"), ("put", "plates/manifest.json")]
    assert merged["cycles"] == [entry]


def test_a_state_pack_far_from_its_size_last_cycle_waits_for_force_size(tmp_path):
    (tmp_path / "TX.sqlite").write_bytes(b"x" * 70)
    entry, files = publish.cycle_entry("2026-11-26", {"TX": tmp_path / "TX.sqlite"})
    live, _ = publish.cycle_entry("2026-10-29", {"TX": tmp_path / "TX.sqlite"})
    live["packs"][0]["bytes"] = 100
    store = FakeStore({"version": 1, "cycles": [live]})
    with pytest.raises(ValueError, match="plates/TX 100 -> 70 bytes"):
        publish.publish_plates(store, entry, files, datetime(2026, 11, 13, tzinfo=timezone.utc))
    assert ("upload", "plates/2026-11-26/TX.sqlite") not in store.client.calls
    publish.publish_plates(store, entry, files, datetime(2026, 11, 13, tzinfo=timezone.utc), force_size=True)
    assert ("upload", "plates/2026-11-26/TX.sqlite") in store.client.calls


def test_the_job_script_parses_and_runs_the_plates_build():
    script = Path(__file__).parent.parent / "deploy" / "tpp-run.sh"
    assert "--entrypoint python3 chartpipe -m tppipe --work /work/tpp" in script.read_text()
    assert subprocess.run(["bash", "-n", str(script)]).returncode == 0


def test_pages_packed_in_compressed_object_streams_are_counted():
    packed = zlib.compress(b"3 0 4 40 << /Type /Page >> << /Type /Page >>")
    data = b"%PDF-1.6\n9 0 obj\n<</Filter/FlateDecode/N 2/Type/ObjStm>>stream\n" + packed + b"\nendstream"
    assert pack.page_count(data) == 2
    assert pack.page_count(pdf(3)) == 3
