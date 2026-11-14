import hashlib
import io
import json
from datetime import datetime, timezone

import pytest

from navpipe import publish

NOW = datetime(2026, 10, 13, tzinfo=timezone.utc)


class FakeClient:
    class exceptions:
        class NoSuchKey(Exception):
            pass

    def __init__(self, existing):
        self.existing, self.calls, self.written = existing, [], None

    def get_object(self, Bucket, Key):
        self.calls.append(("get", Key))
        if self.existing is None:
            raise self.exceptions.NoSuchKey()
        return {"Body": io.BytesIO(json.dumps(self.existing).encode())}

    def put_object(self, Bucket, Key, Body, **extra):
        self.calls.append(("put", Key))
        self.written = json.loads(Body)


class FakeStore:
    bucket = "bucket"

    def __init__(self, existing=None, fail_on=None):
        self.client, self.fail_on = FakeClient(existing), fail_on

    def upload(self, local, key):
        if key == self.fail_on:
            raise RuntimeError("network")
        self.client.calls.append(("upload", key))

    def read_manifest(self):
        raise AssertionError("the chart manifest was read")

    def write_manifest(self, value):
        raise AssertionError("the chart manifest was written")

    def delete_cycles_except(self, keep):
        raise AssertionError("something was deleted")


def built(tmp_path, cycle_id="2026-10-01"):
    folder = tmp_path / cycle_id
    folder.mkdir()
    (folder / "nav.sqlite").write_bytes(b"database")
    (folder / "nav.pmtiles").write_bytes(b"tiles")
    return publish.cycle_entry(cycle_id, folder)


def test_entry_lists_both_files_for_a_28_day_cycle(tmp_path):
    entry, files = built(tmp_path)
    assert entry["id"] == "2026-10-01"
    assert entry["effective"] == "2026-10-01T09:01:00Z"
    assert entry["expires"] == "2026-10-29T09:01:00Z"
    assert entry["packs"] == [
        {"layer": "nav-db", "region": "US", "bytes": 8,
         "sha256": hashlib.sha256(b"database").hexdigest(), "path": "nav/2026-10-01/nav.sqlite"},
        {"layer": "nav-tiles", "region": "US", "bytes": 5,
         "sha256": hashlib.sha256(b"tiles").hexdigest(), "path": "nav/2026-10-01/nav.pmtiles"},
    ]
    assert files == {"nav/2026-10-01/nav.sqlite": tmp_path / "2026-10-01" / "nav.sqlite",
                     "nav/2026-10-01/nav.pmtiles": tmp_path / "2026-10-01" / "nav.pmtiles"}


def test_files_go_up_first_and_the_nav_manifest_last(tmp_path):
    entry, files = built(tmp_path)
    store = FakeStore()
    merged = publish.publish_nav(store, entry, files, NOW)
    assert store.client.calls == [
        ("upload", "nav/2026-10-01/nav.sqlite"),
        ("upload", "nav/2026-10-01/nav.pmtiles"),
        ("get", "nav/manifest.json"),
        ("put", "nav/manifest.json"),
    ]
    assert merged == {"version": 1, "cycles": [entry]}
    assert store.client.written == merged


def test_the_next_cycle_is_added_beside_the_current_one(tmp_path):
    current, _ = built(tmp_path)
    entry, files = built(tmp_path, "2026-10-29")
    store = FakeStore(existing={"version": 1, "cycles": [current]})
    publish.publish_nav(store, entry, files, NOW)
    assert [c["id"] for c in store.client.written["cycles"]] == ["2026-10-01", "2026-10-29"]


def test_a_failed_upload_leaves_the_manifest_alone(tmp_path):
    entry, files = built(tmp_path)
    store = FakeStore(fail_on="nav/2026-10-01/nav.pmtiles")
    with pytest.raises(RuntimeError):
        publish.publish_nav(store, entry, files, NOW)
    assert ("put", "nav/manifest.json") not in store.client.calls


def test_a_key_outside_the_cycle_folder_is_refused_before_any_upload(tmp_path):
    entry, files = built(tmp_path)
    entry["packs"][0]["path"] = "charts/2026-10-01/vfr/TX.pmtiles"
    files["charts/2026-10-01/vfr/TX.pmtiles"] = files["nav/2026-10-01/nav.sqlite"]
    store = FakeStore()
    with pytest.raises(ValueError):
        publish.publish_nav(store, entry, files, NOW)
    assert store.client.calls == []


def test_every_key_touched_is_under_nav(tmp_path):
    entry, files = built(tmp_path)
    store = FakeStore()
    publish.publish_nav(store, entry, files, NOW)
    assert all(key.startswith("nav/") for _, key in store.client.calls)


def test_read_manifest_gives_none_when_there_is_none():
    assert publish.read_manifest(FakeStore()) is None
