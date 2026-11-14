import gzip
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from chartpipe.publish import R2Store
from wxpipe import __main__ as wx
from wxpipe import awc, tfr

FIX = Path(__file__).parent / "fixtures" / "wx"
READ = awc.offline(FIX)
NOW = datetime(2026, 10, 13, 0, 35, tzinfo=timezone.utc)
LATER = NOW + timedelta(minutes=5)


@pytest.fixture(autouse=True)
def short_list_allowed(monkeypatch):
    # The saved notice list holds three notices.
    monkeypatch.setattr(tfr, "MIN_NOTICES", 1)


@pytest.fixture(autouse=True)
def saved_winds(monkeypatch):
    # Model files are too big to save here, so winds come from the committed sample; test_wx_winds runs the builder.
    sample = gzip.decompress((FIX / "out" / "winds.json.gz").read_bytes())
    monkeypatch.setitem(wx.SOURCES, "winds", ("winds.json.gz", lambda fetch, work, now: sample))


class FakeClient:
    """Records writes and deletes. Any other bucket call, such as a listing, fails the test."""

    def __init__(self):
        self.objects, self.calls = {}, []

    def put_object(self, Bucket, Key, Body, **extra):
        self.calls.append(("put", Key))
        self.objects[Key] = Body

    def delete_object(self, Bucket, Key):
        self.calls.append(("delete", Key))
        self.objects.pop(Key, None)

    def __getattr__(self, name):
        raise AssertionError(f"unexpected bucket call: {name}")


def failing(*parts):
    """A fetch that fails for any address containing one of the parts."""
    def fetch(url):
        if any(part in url for part in parts):
            raise OSError(f"no answer from {url}")
        return READ(url)
    return fetch


def garbled(part):
    """A fetch that answers one address with a body of the wrong shape."""
    def fetch(url):
        return gzip.compress(b"raw_text\n") if part in url else READ(url)
    return fetch


def fake_frame(grib, out):
    out.write_bytes(b"frame " + grib.read_bytes()[:4])


def fake_ir(pictures, out):
    out.write_bytes(b"ir " + b" ".join(p.name[:30].encode() for p in pictures))


def go(work, fetch=READ, now=NOW, store=None):
    return wx.run(work, fetch, now, store, fake_frame, fake_ir)


def index_of(client):
    return json.loads(client.objects["wx/index.json"])


def test_every_source_is_written_and_the_index_goes_last(tmp_path):
    client = FakeClient()
    assert go(tmp_path, store=R2Store(client, "bucket")) == []
    data_keys = {key for key in client.objects if not key.startswith(("wx/radar/", "wx/satellite/"))}
    assert data_keys == {"wx/index.json"} | {"wx/" + name for name, _ in wx.SOURCES.values()}
    assert client.calls[-1] == ("put", "wx/index.json")
    index = index_of(client)
    assert index["version"] == 1 and set(index["checked_at"]) == set(wx.NAMES)
    assert index["checked_at"]["metars"] == index["checked_at"]["tafs"] == "2026-10-13T00:35:00Z"
    assert len(json.loads(gzip.decompress(client.objects["wx/metars.json.gz"]))) == 2547


def test_a_publishing_run_needs_no_local_copy(tmp_path):
    # A work disk that cannot take the copy must not turn a good upload into a failed source.
    (tmp_path / "out").write_text("in the way")
    client = FakeClient()
    assert go(tmp_path, store=R2Store(client, "bucket")) == []
    assert index_of(client)["checked_at"]["metars"] == "2026-10-13T00:35:00Z"


def test_unreadable_pilot_reports_keep_the_last_good_object_and_time(tmp_path):
    def renamed(url):
        body = READ(url)
        if "aircraftreports" in url:
            body = gzip.compress(gzip.decompress(body).replace(b"observation_time>", b"obs_time>"))
        return body

    client = FakeClient()
    store = R2Store(client, "bucket")
    go(tmp_path, store=store)
    before = client.objects["wx/pireps.json.gz"]
    assert go(tmp_path, renamed, LATER, store) == ["pireps"]
    assert client.objects["wx/pireps.json.gz"] is before
    assert index_of(client)["checked_at"]["pireps"] == "2026-10-13T00:35:00Z"


def test_one_failing_source_keeps_its_object_and_time(tmp_path):
    client = FakeClient()
    store = R2Store(client, "bucket")
    go(tmp_path, store=store)
    before = client.objects["wx/tafs.json.gz"]
    client.calls.clear()
    assert go(tmp_path, failing("tafs.cache"), LATER, store) == ["tafs"]
    assert client.objects["wx/tafs.json.gz"] is before
    assert ("put", "wx/tafs.json.gz") not in client.calls
    index = index_of(client)
    assert index["checked_at"]["tafs"] == "2026-10-13T00:35:00Z"
    assert index["checked_at"]["metars"] == "2026-10-13T00:40:00Z"
    assert client.calls[-1] == ("put", "wx/index.json")
    assert not [call for call in client.calls if call[0] == "delete"]


@pytest.mark.parametrize("fetch", [failing("metars.cache"), garbled("metars.cache")], ids=["no answer", "wrong shape"])
def test_a_source_that_never_worked_writes_nothing(tmp_path, fetch):
    client = FakeClient()
    assert go(tmp_path, fetch, store=R2Store(client, "bucket")) == ["metars"]
    assert "wx/metars.json.gz" not in client.objects
    assert index_of(client)["checked_at"]["metars"] is None
    assert index_of(client)["checked_at"]["tafs"] == "2026-10-13T00:35:00Z"
    assert not (tmp_path / "out/wx/metars.json.gz").exists()


def test_a_run_told_to_stop_still_writes_the_index_and_keeps_its_state(tmp_path):
    def fetch(url):
        if "tafs.cache" in url:
            raise SystemExit(124)
        return READ(url)

    client = FakeClient()
    with pytest.raises(SystemExit):
        go(tmp_path, fetch, store=R2Store(client, "bucket"))
    assert client.calls[-1] == ("put", "wx/index.json")
    assert index_of(client)["checked_at"]["metars"] == "2026-10-13T00:35:00Z"
    assert index_of(client)["checked_at"]["tafs"] is None
    saved = json.loads((tmp_path / "state.json").read_text())
    assert saved["checked_at"] == {name: "2026-10-13T00:35:00Z" for name in ("radar", "satellite", "lightning", "metars")}


def test_a_turn_stopped_by_a_slow_source_has_already_stored_radar_and_satellite(tmp_path):
    def fetch(url):
        if "aviationweather.gov" in url:
            raise SystemExit(124)
        return READ(url)

    client = FakeClient()
    with pytest.raises(SystemExit):
        go(tmp_path, fetch, store=R2Store(client, "bucket"))
    index = index_of(client)
    assert index["frames"] and index["satellite"]
    assert index["checked_at"]["radar"] == index["checked_at"]["satellite"] == "2026-10-13T00:35:00Z"


def test_exit_code_reports_a_failed_source(tmp_path, monkeypatch):
    monkeypatch.setattr(wx, "run", lambda *args, **extra: ["tafs"])
    assert wx.main(["--work", str(tmp_path), "--no-publish"]) == 1
    monkeypatch.setattr(wx, "run", lambda *args, **extra: [])
    assert wx.main(["--work", str(tmp_path), "--no-publish"]) == 0


def test_sample_runs_never_publish_and_real_runs_cannot_fake_the_time(tmp_path, monkeypatch):
    seen = {}

    def fake_run(work, fetch, now, store=None, **extra):
        seen.update(now=now, store=store)
        return []

    monkeypatch.setattr(wx, "run", fake_run)
    monkeypatch.setattr(wx, "r2_store_from_env", lambda: pytest.fail("a sample run must not open the bucket"))
    assert wx.main(["--work", str(tmp_path), "--offline", str(FIX), "--now", "2026-10-13T00:35:00Z"]) == 0
    assert seen == {"now": NOW, "store": None}
    with pytest.raises(SystemExit):
        wx.main(["--work", str(tmp_path), "--no-publish", "--now", "2026-10-13T00:35:00Z"])


def test_committed_samples_match_the_worker(tmp_path):
    go(tmp_path)
    out = FIX / "out"
    fresh = tmp_path / "out" / "wx"
    assert json.loads((out / "index.json").read_text()) == json.loads((fresh / "index.json").read_text())
    for name, _ in wx.SOURCES.values():
        assert gzip.decompress((out / name).read_bytes()) == gzip.decompress((fresh / name).read_bytes()), name


def test_files_that_stopped_changing_keep_their_old_object_and_time(tmp_path):
    client = FakeClient()
    store = R2Store(client, "bucket")
    go(tmp_path, store=store)
    before = client.objects["wx/gairmets.geojson.gz"]
    assert go(tmp_path, now=NOW + timedelta(days=2), store=store) == ["satellite", "lightning", "metars", "tafs", "gairmets"]
    assert client.objects["wx/gairmets.geojson.gz"] is before
    index = index_of(client)
    for name in ("metars", "tafs", "gairmets"):
        assert index["checked_at"][name] == "2026-10-13T00:35:00Z", name
    assert index["checked_at"]["sigmets"] == "2026-10-15T00:35:00Z"


def test_forecasts_published_without_their_periods_fail_the_run_and_stay_current(tmp_path, monkeypatch):
    monkeypatch.setattr(awc, "DEGRADED", [])

    def renamed(url):
        body = READ(url)
        if "tafs.cache" in url:
            body = gzip.compress(gzip.decompress(body).replace(b"fcst_time_from>", b"fcst_from>"))
        return body

    client = FakeClient()
    store = R2Store(client, "bucket")
    # The report text is still right, so it goes out and the source stays current. The exit code tells the operator.
    assert go(tmp_path, renamed, store=store) == []
    assert index_of(client)["checked_at"]["tafs"] == "2026-10-13T00:35:00Z"
    assert len(json.loads(gzip.decompress(client.objects["wx/tafs.json.gz"]))) == 768
    assert awc.DEGRADED == ["tafs"]
    # The next good run starts clean.
    assert go(tmp_path, now=LATER, store=store) == [] and awc.DEGRADED == []


def test_exit_code_reports_a_degraded_source_on_the_last_line(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(awc, "DEGRADED", ["tafs"])
    monkeypatch.setattr(wx, "run", lambda *args, **extra: ["radar"])
    assert wx.main(["--work", str(tmp_path), "--no-publish"]) == 1
    assert capsys.readouterr().err.splitlines()[-2:] == ["failed sources: radar", "degraded sources: tafs"]
    monkeypatch.setattr(wx, "run", lambda *args, **extra: [])
    assert wx.main(["--work", str(tmp_path), "--no-publish"]) == 1
    assert capsys.readouterr().err.splitlines() == ["degraded sources: tafs"]


FRAME = "wx/radar/20261013-002636.pmtiles"


def test_the_newest_frame_is_stored_before_the_index_names_it(tmp_path):
    client = FakeClient()
    assert go(tmp_path, store=R2Store(client, "bucket")) == []
    assert index_of(client)["frames"] == [{"valid": "2026-10-13T00:26:36Z", "path": FRAME}]
    assert index_of(client)["checked_at"]["radar"] == "2026-10-13T00:35:00Z"
    assert client.calls.index(("put", FRAME)) < client.calls.index(("put", "wx/index.json"))
    assert client.objects[FRAME].startswith(b"frame ")


def test_a_frame_already_in_the_loop_is_not_built_again(tmp_path):
    client = FakeClient()
    store = R2Store(client, "bucket")
    go(tmp_path, store=store)
    client.calls.clear()
    assert go(tmp_path, now=LATER, store=store) == []
    assert not [call for call in client.calls if call[1].startswith("wx/radar/")]
    assert index_of(client)["checked_at"]["radar"] == "2026-10-13T00:40:00Z"


def loop_from(hour, minute):
    """Twelve frames five minutes apart, starting on 12 October at the given time."""
    start = datetime(2026, 10, 12, hour, minute, tzinfo=timezone.utc)
    return [{"valid": f"{moment:%Y-%m-%dT%H:%M:%SZ}", "path": f"wx/radar/{moment:%Y%m%d-%H%M%S}.pmtiles"}
            for moment in (start + timedelta(minutes=5 * step) for step in range(12))]


def test_frames_from_before_a_gap_in_runs_leave_the_loop(tmp_path):
    old = loop_from(21, 0)
    (tmp_path / "state.json").write_text(json.dumps({"checked_at": {}, "frames": old}))
    client = FakeClient()
    client.objects.update({frame["path"]: b"old" for frame in old})
    assert go(tmp_path, store=R2Store(client, "bucket")) == []
    assert index_of(client)["frames"] == [{"valid": "2026-10-13T00:26:36Z", "path": FRAME}]
    after_index = client.calls[client.calls.index(("put", "wx/index.json")) + 1:]
    assert after_index == [("delete", frame["path"]) for frame in old]


def test_the_loop_keeps_twelve_frames_and_deletes_only_its_own_oldest(tmp_path):
    old = loop_from(23, 30)
    (tmp_path / "state.json").write_text(json.dumps({"checked_at": {}, "frames": old}))
    client = FakeClient()
    client.objects.update({frame["path"]: b"old" for frame in old})
    client.objects["charts/2026-09-03/vfr/TX.pmtiles"] = b"chart"
    assert go(tmp_path, store=R2Store(client, "bucket")) == []
    frames = index_of(client)["frames"]
    assert len(frames) == 12 and frames[-1]["path"] == FRAME
    assert frames[0]["valid"] == "2026-10-12T23:35:00Z"
    # A phone holding the last index may still open the oldest frame, so it stays for now.
    oldest = "wx/radar/20261012-233000.pmtiles"
    assert not [call for call in client.calls if call[0] == "delete"]
    assert json.loads((tmp_path / "state.json").read_text())["drop"] == [oldest]
    client.calls.clear()
    # No lightning file is that recent in the saved listing.
    assert go(tmp_path, now=NOW + timedelta(minutes=30), store=R2Store(client, "bucket")) == ["lightning"]
    assert [call for call in client.calls if call[0] == "delete"] == [("delete", oldest)]
    assert client.calls[-2:] == [("put", "wx/index.json"), ("delete", oldest)]
    assert "charts/2026-09-03/vfr/TX.pmtiles" in client.objects
    assert json.loads((tmp_path / "state.json").read_text())["drop"] == []


def test_a_key_outside_the_radar_folder_is_never_deleted(tmp_path):
    (tmp_path / "state.json").write_text(json.dumps({"drop": ["manifest.json"]}))
    client = FakeClient()
    with pytest.raises(ValueError, match="refusing"):
        go(tmp_path, store=R2Store(client, "bucket"))
    assert not [call for call in client.calls if call[0] == "delete"]


def test_a_radar_failure_leaves_the_loop_and_the_other_sources_alone(tmp_path):
    client = FakeClient()
    store = R2Store(client, "bucket")
    go(tmp_path, store=store)
    newer = (FIX / "mrms_listing.xml").read_bytes().replace(b"002636", b"003036")

    def fetch(url):
        return newer if "list-type=2" in url and "noaa-goes" not in url else READ(url.replace("003036", "002636"))

    def broken(grib, out):
        raise RuntimeError("no grib driver")

    assert wx.run(tmp_path, fetch, LATER, store, broken) == ["radar"]
    index = index_of(client)
    assert [frame["valid"] for frame in index["frames"]] == ["2026-10-13T00:26:36Z"]
    assert index["checked_at"]["radar"] == "2026-10-13T00:35:00Z"
    assert index["checked_at"]["metars"] == "2026-10-13T00:40:00Z"
    assert client.calls[-1] == ("put", "wx/index.json")


SATELLITE = "wx/satellite/20261013-003117.pmtiles"


def test_the_newest_satellite_picture_is_stored_once_and_the_one_it_replaces_dropped_later(tmp_path):
    (tmp_path / "state.json").write_text(json.dumps(
        {"satellite": {"valid": "2026-10-13T00:26:17Z", "path": "wx/satellite/20261013-002617.pmtiles"}}))
    client = FakeClient()
    store = R2Store(client, "bucket")
    assert go(tmp_path, store=store) == []
    assert index_of(client)["satellite"] == {"valid": "2026-10-13T00:31:17Z", "path": SATELLITE}
    assert client.objects[SATELLITE] == b"ir satellite-0.nc satellite-1.nc"
    assert client.calls.index(("put", SATELLITE)) < client.calls.index(("put", "wx/index.json"))
    client.calls.clear()
    assert "satellite" not in go(tmp_path, now=NOW + timedelta(minutes=60), store=store)
    assert ("put", SATELLITE) not in client.calls
    assert ("delete", "wx/satellite/20261013-002617.pmtiles") in client.calls
