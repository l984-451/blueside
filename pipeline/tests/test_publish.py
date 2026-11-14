import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from chartpipe import manifest, publish

SHA = "ab" * 32
NOW = datetime(2026, 9, 10, tzinfo=timezone.utc)


class FakeStore:
    def __init__(self, existing=None, fail_on=None):
        self.existing, self.fail_on, self.calls = existing, fail_on, []

    def read_manifest(self):
        return self.existing

    def upload(self, local, key):
        if key == self.fail_on:
            raise RuntimeError("network")
        self.calls.append(("upload", key))

    def write_manifest(self, value):
        self.written = self.existing = value
        self.calls.append(("manifest", [c["id"] for c in value["cycles"]]))


def entry_and_files(tmp_path):
    packs = [{"layer": "vfr", "region": r, "bytes": 1, "sha256": SHA} for r in ("TX", "overview")]
    entry = manifest.cycle_entry("2026-09-03", packs)
    files = {}
    for p in entry["packs"]:
        f = tmp_path / p["path"].replace("/", "_")
        f.write_bytes(b"x")
        files[p["path"]] = f
    return entry, files


def test_manifest_is_written_after_every_pack(tmp_path):
    entry, files = entry_and_files(tmp_path)
    store = FakeStore()
    publish.publish_cycle(store, entry, files, NOW)
    kinds = [c[0] for c in store.calls]
    assert kinds == ["upload", "upload", "manifest"]
    assert store.calls[2] == ("manifest", ["2026-09-03"])


def test_a_failed_upload_leaves_the_manifest_alone(tmp_path):
    entry, files = entry_and_files(tmp_path)
    store = FakeStore(fail_on=entry["packs"][1]["path"])
    with pytest.raises(RuntimeError):
        publish.publish_cycle(store, entry, files, NOW)
    assert all(c[0] == "upload" for c in store.calls)


def test_a_missing_pack_file_stops_before_any_upload(tmp_path):
    entry, files = entry_and_files(tmp_path)
    del files[entry["packs"][0]["path"]]
    store = FakeStore()
    with pytest.raises(KeyError):
        publish.publish_cycle(store, entry, files, NOW)
    assert store.calls == []


def test_a_pack_the_previous_cycle_has_and_this_one_lacks_stops_before_any_upload(tmp_path):
    entry, files = entry_and_files(tmp_path)
    older = [{"layer": "vfr", "region": r, "bytes": 1, "sha256": SHA} for r in ("TX", "OK", "overview")]
    store = FakeStore(existing={"version": 1, "cycles": [manifest.cycle_entry("2026-07-09", older)]})
    with pytest.raises(ValueError) as error:
        publish.publish_cycle(store, entry, files, NOW)
    assert "vfr/OK" in str(error.value)
    assert store.calls == []



def test_a_pack_far_from_its_size_last_cycle_waits_for_force_size(tmp_path):
    entry, files = entry_and_files(tmp_path)
    older = [{"layer": "vfr", "region": r, "bytes": n, "sha256": SHA} for r, n in (("TX", 2), ("overview", 1))]
    store = FakeStore(existing={"version": 1, "cycles": [manifest.cycle_entry("2026-07-09", older)]})
    with pytest.raises(ValueError, match=r"since 2026-07-09 .*\['vfr/TX 2 -> 1 bytes'\]"):
        publish.publish_cycle(store, entry, files, NOW)
    assert store.calls == []
    publish.publish_cycle(store, entry, files, NOW, force_size=True)
    assert [kind for kind, _ in store.calls] == ["upload", "upload", "manifest"]


def test_a_quarter_either_way_is_still_the_same_pack():
    live = {"cycles": [manifest.cycle_entry("2026-07-09", [{"layer": "vfr", "region": "TX", "bytes": 100, "sha256": SHA}])]}
    for size in (75, 125):
        publish.check_sizes(live, "2026-09-03", [{"layer": "vfr", "region": "TX", "bytes": size}])
    for size in (74, 126):
        with pytest.raises(ValueError):
            publish.check_sizes(live, "2026-09-03", [{"layer": "vfr", "region": "TX", "bytes": size}])

VISUAL = (("vfr", "TX"), ("vfr", "overview"), ("vfr-tac", "TX"))


def live_manifest(later_also=()):
    """Two live cycles holding the same visual packs. later_also adds (layer, region) packs to the later one."""
    def packs(pairs):
        return [{"layer": layer, "region": region, "bytes": 7, "sha256": SHA} for layer, region in pairs]
    return {"version": 1, "cycles": [manifest.cycle_entry("2026-09-03", packs(VISUAL)),
                                     manifest.cycle_entry("2026-10-29", packs(VISUAL + tuple(later_also)))]}


def low_packs(*regions):
    entry = manifest.cycle_entry("2026-09-03", [{"layer": "ifr-low", "region": r, "bytes": 3, "sha256": "cd" * 32}
                                                for r in regions])
    return entry, {p["path"]: Path("x") for p in entry["packs"]}


def test_adding_layers_to_a_live_cycle_leaves_its_packs_alone():
    live = live_manifest()
    before, other = json.dumps(live["cycles"][0]["packs"]), json.dumps(live["cycles"][1])
    entry, files = low_packs("TX", "overview")
    store = FakeStore(existing=live)
    publish.publish_cycle(store, entry, files, NOW)
    uploaded = [key for kind, key in store.calls if kind == "upload"]
    assert uploaded == ["charts/2026-09-03/ifr-low/TX.pmtiles", "charts/2026-09-03/ifr-low/overview.pmtiles"]
    packs = store.written["cycles"][0]["packs"]
    assert json.dumps(packs[:3]) == before
    assert [(p["layer"], p["region"]) for p in packs[3:]] == [("ifr-low", "TX"), ("ifr-low", "overview")]
    assert json.dumps(store.written["cycles"][1]) == other


def test_a_cycle_published_by_another_job_during_the_uploads_is_kept():
    class BusyStore(FakeStore):
        def upload(self, local, key):
            super().upload(local, key)
            # Another job adds the later cycle while this one is still sending packs.
            self.existing = live_manifest()

    both = live_manifest()
    store = BusyStore(existing={"version": 1, "cycles": both["cycles"][:1]})
    entry, files = low_packs("TX", "overview")
    publish.publish_cycle(store, entry, files, NOW)
    assert [c["id"] for c in store.written["cycles"]] == ["2026-09-03", "2026-10-29"]
    packs = store.written["cycles"][0]["packs"]
    assert [(p["layer"], p["region"]) for p in packs] == [*VISUAL, ("ifr-low", "TX"), ("ifr-low", "overview")]


def test_a_hand_run_publish_container_has_a_name_the_daily_job_can_see():
    script = (Path(__file__).parent.parent / "deploy" / "remote.sh").read_text()
    publish_line = next(line for line in script.splitlines() if "--env-file" in line)
    assert "--name chartpipe-manual" in publish_line


def test_a_pack_that_is_already_live_is_never_uploaded_again(tmp_path):
    again = [{"layer": "vfr", "region": "TX", "bytes": 999, "sha256": "ef" * 32},
             {"layer": "ifr-area", "region": "TX", "bytes": 3, "sha256": "cd" * 32}]
    entry = manifest.cycle_entry("2026-09-03", again)
    store = FakeStore(existing=live_manifest())
    publish.publish_cycle(store, entry, {entry["packs"][1]["path"]: tmp_path / "x"}, NOW)
    assert [key for kind, key in store.calls if kind == "upload"] == ["charts/2026-09-03/ifr-area/TX.pmtiles"]
    assert store.written["cycles"][0]["packs"][0]["bytes"] == 7


def test_a_visual_pack_only_the_other_cycle_has_does_not_block_new_layers():
    entry, files = low_packs("TX")
    store = FakeStore(existing=live_manifest(later_also=[("vfr-tac", "OK")]))
    publish.publish_cycle(store, entry, files, NOW)
    assert [key for kind, key in store.calls if kind == "upload"] == ["charts/2026-09-03/ifr-low/TX.pmtiles"]


def test_a_new_layer_short_of_a_region_the_other_cycle_has_stops_before_any_upload():
    entry, files = low_packs("TX")
    store = FakeStore(existing=live_manifest(later_also=[("ifr-low", "TX"), ("ifr-low", "OK")]))
    with pytest.raises(ValueError) as error:
        publish.publish_cycle(store, entry, files, NOW)
    # Only the layer being added is judged. The visual packs of both cycles match and are not named.
    assert "ifr-low/OK" in str(error.value) and "vfr" not in str(error.value)
    assert store.calls == []


class FakeClient:
    """A bucket of keys, each with its upload time. Only the charts/ prefix is ever listed."""
    def __init__(self, keys):
        self.keys, self.deleted = keys, []

    def get_paginator(self, name):
        client = self

        class Pages:
            def paginate(self, Bucket, Prefix):
                return [{"Contents": [{"Key": k, "LastModified": t} for k, t in client.keys.items() if k.startswith(Prefix)]}]
        return Pages()

    def delete_object(self, Bucket, Key):
        self.deleted.append(Key)


OLD, FRESH = NOW - timedelta(days=30), NOW - timedelta(hours=1)


def test_cleanup_removes_only_old_chart_keys_the_manifest_does_not_name():
    listed = {"version": 1, "cycles": [manifest.cycle_entry("2026-09-03", [{"layer": "vfr", "region": "TX", "bytes": 1, "sha256": SHA}])],
              "base": manifest.base_entries([{"layer": "street", "region": "TX", "bytes": 1, "sha256": SHA}], "1")}
    client = FakeClient({
        "charts/2026-07-09/vfr/TX.pmtiles": OLD,          # expired cycle
        "charts/2026-09-03/vfr/TX.pmtiles": OLD,          # listed
        "charts/2026-09-03/street/TX.pmtiles": OLD,       # per-cycle copy the base replaced
        "charts/2026-09-03/terrain/TX.pmtiles": OLD,
        "charts/base/street/TX-abababababababab.pmtiles": OLD,   # listed base
        "charts/base/street/TX-cdcdcdcdcdcdcdcd.pmtiles": OLD,   # replaced base
        "charts/2026-10-29/vfr/TX.pmtiles": FRESH,        # another job's upload in progress
        "nav/2026-09-03/nav.sqlite": OLD, "plates/2026-09-03/TX.sqlite": OLD, "wx/radar.pmtiles": OLD,
        "manifest.json": OLD,
    })
    gone = publish.R2Store(client, "bucket").delete_unlisted(listed, NOW)
    assert gone == client.deleted == ["charts/2026-07-09/vfr/TX.pmtiles", "charts/2026-09-03/street/TX.pmtiles",
                                      "charts/2026-09-03/terrain/TX.pmtiles", "charts/base/street/TX-cdcdcdcdcdcdcdcd.pmtiles"]


def test_cleanup_refuses_an_empty_manifest():
    client = FakeClient({"charts/2026-09-03/vfr/TX.pmtiles": OLD})
    for empty in (None, {"version": 1, "cycles": []}):
        with pytest.raises(ValueError):
            publish.R2Store(client, "bucket").delete_unlisted(empty, NOW)
    assert client.deleted == []


def street(*pairs):
    """Base street packs from (region, sha) pairs, with a local file behind each."""
    packs = manifest.base_entries([{"layer": "street", "region": r, "bytes": 5, "sha256": sha} for r, sha in pairs], "1")
    return packs, {p["path"]: Path("x") for p in packs}


def legacy_street():
    """Live cycles from before the base section, each with its own copy of the street pack."""
    live = live_manifest()
    for cycle in live["cycles"]:
        cycle["packs"].append({"layer": "street", "region": "TX", "bytes": 5, "sha256": SHA,
                               "path": manifest.pack_path(cycle["id"], "street", "TX")})
    return live


def test_base_packs_are_listed_once_and_leave_every_cycle():
    store = FakeStore(existing=legacy_street())
    packs, files = street(("TX", SHA), ("OK", SHA))
    publish.publish_base(store, packs, files, NOW)
    assert [key for kind, key in store.calls if kind == "upload"] == [
        "charts/base/street/TX-abababababababab.pmtiles", "charts/base/street/OK-abababababababab.pmtiles"]
    assert store.written["base"] == packs and packs[0]["version"] == "1"
    assert all(p["layer"] != "street" for c in store.written["cycles"] for p in c["packs"])
    assert [(p["layer"], p["region"]) for p in store.written["cycles"][0]["packs"]] == list(VISUAL)


def test_a_base_pack_with_the_same_bytes_is_not_uploaded_again():
    store = FakeStore(existing=live_manifest())
    publish.publish_base(store, *street(("TX", SHA), ("OK", SHA)), NOW)
    store.calls.clear()
    publish.publish_base(store, *street(("TX", SHA), ("OK", "cd" * 32)), NOW)
    assert [key for kind, key in store.calls if kind == "upload"] == ["charts/base/street/OK-cdcdcdcdcdcdcdcd.pmtiles"]
    assert [p["sha256"] for p in store.written["base"]] == [SHA, "cd" * 32]


def test_a_base_build_keeps_the_other_base_layer():
    store = FakeStore(existing=live_manifest())
    terrain = manifest.base_entries([{"layer": "terrain", "region": "TX", "bytes": 2, "sha256": SHA}], "1")
    publish.publish_base(store, terrain, {terrain[0]["path"]: Path("x")}, NOW)
    publish.publish_base(store, *street(("TX", SHA)), NOW)
    assert [p["layer"] for p in store.written["base"]] == ["terrain", "street"]


def test_a_base_build_short_of_a_live_region_stops_before_any_upload():
    store = FakeStore(existing=live_manifest())
    publish.publish_base(store, *street(("TX", SHA), ("OK", SHA)), NOW)
    store.calls.clear()
    with pytest.raises(ValueError) as error:
        publish.publish_base(store, *street(("TX", "cd" * 32)), NOW)
    assert "street/OK" in str(error.value) and store.calls == []


def test_a_new_cycle_without_the_old_per_cycle_street_packs_is_not_short():
    older = legacy_street()
    store = FakeStore(existing={"version": 1, "cycles": older["cycles"][:1]})
    entry = manifest.cycle_entry("2026-10-29", [{"layer": l, "region": r, "bytes": 7, "sha256": SHA} for l, r in VISUAL])
    publish.publish_cycle(store, entry, {p["path"]: Path("x") for p in entry["packs"]}, NOW)
    assert store.calls[-1] == ("manifest", ["2026-09-03", "2026-10-29"])
