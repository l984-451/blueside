import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import pytest

from navpipe import __main__ as cli

FIXTURES = Path(__file__).parent / "fixtures" / "nav"
TOOLS = ("tippecanoe", "tippecanoe-decode", "ogr2ogr", "pmtiles")
ONE_CYCLE = b'<a href="./../NASR_Subscription/2026-10-01">Subscription effective October 01, 2026</a>'
COMING_CYCLE = b'<a href="./../NASR_Subscription/2099-01-01">Subscription effective January 01, 2099</a>'
BUILT_AT = datetime(2026, 10, 13, 4, 0, tzinfo=timezone.utc)


def refuse_to_build(*args):
    raise AssertionError("a build was started")


def refuse_to_go_on(*args):
    raise AssertionError("the run went on after a failed check")


@pytest.fixture(autouse=True)
def small_builds_pass(monkeypatch):
    monkeypatch.setattr(cli.surface, "fetch", lambda cache, now: None)
    monkeypatch.setattr(cli.nasr, "fetch_obstacles", lambda work: FIXTURES / "DOF.CSV")
    monkeypatch.setattr(cli.navtiles, "check_national", lambda counts: None)


def test_build_time_is_read_as_utc():
    assert cli.parse_time("2026-10-13T04:00:00Z") == BUILT_AT


def test_a_cycle_that_is_not_on_the_faa_page_is_an_error(monkeypatch, tmp_path):
    monkeypatch.setattr(cli.faa, "fetch", lambda url: ONE_CYCLE)
    with pytest.raises(SystemExit):
        cli.main(["--work", str(tmp_path), "--no-publish", "--cycle", "2026-11-26"])


def test_a_page_with_no_cycles_stops_the_run(monkeypatch, tmp_path):
    monkeypatch.setattr(cli.faa, "fetch", lambda url: b"<html>maintenance</html>")
    with pytest.raises(SystemExit):
        cli.main(["--work", str(tmp_path), "--no-publish"])


def test_a_coming_cycle_whose_files_are_not_posted_is_skipped(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli.faa, "fetch", lambda url: COMING_CYCLE)
    monkeypatch.setattr(cli.nasr, "exists", lambda url: False)
    monkeypatch.setattr(cli, "build_cycle", refuse_to_build)
    assert cli.main(["--work", str(tmp_path), "--no-publish"]) == 0
    assert "not posted" in capsys.readouterr().out


def test_a_cycle_in_force_with_missing_files_fails_the_run(monkeypatch, tmp_path):
    monkeypatch.setattr(cli.faa, "fetch", lambda url: ONE_CYCLE)
    monkeypatch.setattr(cli.nasr, "exists", lambda url: False)
    monkeypatch.setattr(cli, "build_cycle", refuse_to_build)
    with pytest.raises(SystemExit) as stopped:
        cli.main(["--work", str(tmp_path), "--no-publish"])
    assert cli.nasr.csv_url("2026-10-01") in str(stopped.value)
    assert cli.nasr.airspace_url("2026-10-01") in str(stopped.value)


def test_a_later_cycle_is_still_built_before_the_run_fails(monkeypatch, tmp_path):
    built = []
    gone = (cli.nasr.csv_url("2026-10-01"), cli.nasr.airspace_url("2026-10-01"))
    monkeypatch.setattr(cli.faa, "fetch", lambda url: ONE_CYCLE + COMING_CYCLE)
    monkeypatch.setattr(cli.nasr, "exists", lambda url: url not in gone)

    def fake_build(cycle_id, work, out, built_at):
        built.append(cycle_id)
        return {"id": cycle_id}, {}

    monkeypatch.setattr(cli, "build_cycle", fake_build)
    with pytest.raises(SystemExit):
        cli.main(["--work", str(tmp_path), "--no-publish"])
    assert built == ["2099-01-01"]


def test_a_cycle_already_in_the_nav_manifest_is_not_rebuilt(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli.faa, "fetch", lambda url: ONE_CYCLE)
    monkeypatch.setattr(cli.chart_publish, "r2_store_from_env", lambda: object())
    monkeypatch.setattr(cli.publish, "read_manifest", lambda store: {"version": 1, "cycles": [{"id": "2026-10-01"}]})
    monkeypatch.setattr(cli, "build_cycle", refuse_to_build)
    assert cli.main(["--work", str(tmp_path)]) == 0
    assert "nothing new to build" in capsys.readouterr().out


def test_rebuild_builds_a_live_cycle_again_and_publishes_it(monkeypatch, tmp_path):
    published = []
    monkeypatch.setattr(cli.faa, "fetch", lambda url: ONE_CYCLE)
    monkeypatch.setattr(cli.nasr, "exists", lambda url: True)
    monkeypatch.setattr(cli.chart_publish, "r2_store_from_env", lambda: "store")
    monkeypatch.setattr(cli.publish, "read_manifest", lambda store: {"version": 1, "cycles": [{"id": "2026-10-01"}]})
    monkeypatch.setattr(cli, "build_cycle", lambda cycle_id, work, out, built_at: ({"id": cycle_id}, {}))
    monkeypatch.setattr(cli.publish, "publish_nav", lambda store, entry, files, now: published.append(entry["id"]))
    assert cli.main(["--work", str(tmp_path), "--rebuild"]) == 0
    assert published == ["2026-10-01"]


def test_a_built_cycle_is_published_only_without_no_publish(monkeypatch, tmp_path):
    published = []
    monkeypatch.setattr(cli.faa, "fetch", lambda url: ONE_CYCLE)
    monkeypatch.setattr(cli.nasr, "exists", lambda url: True)
    monkeypatch.setattr(cli, "build_cycle", lambda cycle_id, work, out, built_at: ({"id": cycle_id}, {}))
    monkeypatch.setattr(cli.chart_publish, "r2_store_from_env", lambda: "store")
    monkeypatch.setattr(cli.publish, "read_manifest", lambda store: None)
    monkeypatch.setattr(cli.publish, "publish_nav", lambda store, entry, files, now: published.append(entry["id"]))
    assert cli.main(["--work", str(tmp_path), "--no-publish"]) == 0
    assert published == []
    assert cli.main(["--work", str(tmp_path)]) == 0
    assert published == ["2026-10-01"]


def test_one_cycle_builds_both_files_and_records_the_build_time(monkeypatch, tmp_path):
    if not all(shutil.which(tool) for tool in TOOLS):
        pytest.skip("needs tippecanoe, ogr2ogr and pmtiles")

    def fake_sua(target, pending=False):
        shutil.copy(FIXTURES / "sua.geojson", target)
        return "2026-09-28T13:54:26Z"

    monkeypatch.setattr(cli.nasr, "fetch_cycle",
                        lambda cycle_id, work: (FIXTURES / "csv", FIXTURES / "shp" / "Class_Airspace.shp"))
    monkeypatch.setattr(cli.nasr, "fetch_sua", fake_sua)
    monkeypatch.setattr(cli.navdb, "check_national", lambda counts: None)
    entry, files = cli.build_cycle("2026-10-01", tmp_path / "work", tmp_path / "out", BUILT_AT)
    assert [p["layer"] for p in entry["packs"]] == ["nav-db", "nav-tiles"]
    assert entry["expires"] == "2026-10-29T09:01:00Z"
    for pack in entry["packs"]:
        assert files[pack["path"]].stat().st_size == pack["bytes"] > 0
    db = sqlite3.connect(tmp_path / "out" / "nav.sqlite")
    meta = dict(db.execute("SELECT key, value FROM meta"))
    db.close()
    assert meta["built_at"] == "2026-10-13T04:00:00Z"
    assert meta["sua_snapshot"] == "2026-09-28T13:54:26Z"


def test_a_short_airport_file_stops_the_run_before_tiles_and_upload(monkeypatch, tmp_path):
    monkeypatch.setattr(cli.faa, "fetch", lambda url: ONE_CYCLE)
    monkeypatch.setattr(cli.nasr, "exists", lambda url: True)
    monkeypatch.setattr(cli.nasr, "fetch_cycle",
                        lambda cycle_id, work: (FIXTURES / "csv", FIXTURES / "shp" / "Class_Airspace.shp"))
    monkeypatch.setattr(cli.nasr, "fetch_sua", lambda target, pending=False: "2026-09-28T13:54:26Z")
    monkeypatch.setattr(cli.navtiles, "build", refuse_to_go_on)
    monkeypatch.setattr(cli.chart_publish, "r2_store_from_env", lambda: "store")
    monkeypatch.setattr(cli.publish, "read_manifest", lambda store: None)
    monkeypatch.setattr(cli.publish, "publish_nav", refuse_to_go_on)
    with pytest.raises(ValueError):
        cli.main(["--work", str(tmp_path / "work")])


@pytest.mark.parametrize("cycle_id, pending", [("2026-10-01", False), ("2026-10-29", True)])
def test_a_cycle_not_yet_in_force_reads_the_pending_airspace(monkeypatch, tmp_path, cycle_id, pending):
    asked = []

    def fake_sua(target, pending=False):
        asked.append(pending)
        return "2026-10-09T00:00:00Z"

    monkeypatch.setattr(cli.nasr, "fetch_cycle", lambda cycle_id, work: (work / "csv", work / "a.shp"))
    monkeypatch.setattr(cli.nasr, "fetch_sua", fake_sua)
    monkeypatch.setattr(cli.navdb, "build", lambda *args: {})
    monkeypatch.setattr(cli.navdb, "check_national", lambda counts: None)
    monkeypatch.setattr(cli.navtiles, "build", lambda *args: {})
    monkeypatch.setattr(cli.publish, "cycle_entry", lambda cycle_id, out: ({"packs": []}, {}))
    cli.build_cycle(cycle_id, tmp_path / "work", tmp_path / "out", BUILT_AT)
    assert asked == [pending]


def test_a_leftover_download_is_thrown_away_before_a_rebuild(monkeypatch, tmp_path):
    seen = []
    stale = tmp_path / "work" / "zips" / "csv.zip"
    stale.parent.mkdir(parents=True)
    stale.write_bytes(b"<html>Access Denied</html>")

    def fake_fetch(cycle_id, work):
        seen.append((work / "zips" / "csv.zip").exists())
        raise RuntimeError("stop here")

    monkeypatch.setattr(cli.nasr, "fetch_cycle", fake_fetch)
    with pytest.raises(RuntimeError):
        cli.build_cycle("2026-10-01", tmp_path / "work", tmp_path / "out", BUILT_AT)
    assert seen == [False]
