import json
from datetime import datetime, timezone
from pathlib import Path

from chartpipe import manifest

SHA = "ab" * 32
PACKS = [{"layer": "vfr", "region": "TX", "bytes": 10, "sha256": SHA},
         {"layer": "vfr", "region": "overview", "bytes": 5, "sha256": SHA},
         {"layer": "vfr-tac", "region": "TX", "bytes": 7, "sha256": SHA}]


def at(text):
    return datetime.fromisoformat(text).replace(tzinfo=timezone.utc)


def test_cycle_entry_has_dates_and_paths():
    entry = manifest.cycle_entry("2026-09-03", PACKS)
    assert entry["id"] == "2026-09-03"
    assert entry["effective"] == "2026-09-03T09:01:00Z"
    assert entry["expires"] == "2026-10-29T09:01:00Z"
    assert entry["packs"][0] == {"layer": "vfr", "region": "TX", "bytes": 10, "sha256": SHA,
                                 "path": "charts/2026-09-03/vfr/TX.pmtiles"}
    assert entry["packs"][2]["path"] == "charts/2026-09-03/vfr-tac/TX.pmtiles"


def test_merge_into_nothing():
    merged = manifest.merge(None, manifest.cycle_entry("2026-09-03", PACKS), at("2026-09-10"))
    assert merged["version"] == 1 and [c["id"] for c in merged["cycles"]] == ["2026-09-03"]


def test_merge_keeps_current_and_next_in_date_order():
    first = manifest.merge(None, manifest.cycle_entry("2026-10-29", PACKS), at("2026-10-12"))
    merged = manifest.merge(first, manifest.cycle_entry("2026-09-03", PACKS), at("2026-10-12"))
    assert [c["id"] for c in merged["cycles"]] == ["2026-09-03", "2026-10-29"]


def test_merge_drops_cycles_that_are_over():
    old = manifest.merge(None, manifest.cycle_entry("2026-07-09", PACKS), at("2026-07-10"))
    merged = manifest.merge(old, manifest.cycle_entry("2026-09-03", PACKS), at("2026-09-10"))
    assert [c["id"] for c in merged["cycles"]] == ["2026-09-03"]


def test_merge_replaces_a_cycle_with_the_same_id():
    first = manifest.merge(None, manifest.cycle_entry("2026-09-03", PACKS[:1]), at("2026-09-10"))
    merged = manifest.merge(first, manifest.cycle_entry("2026-09-03", PACKS), at("2026-09-10"))
    assert len(merged["cycles"]) == 1 and len(merged["cycles"][0]["packs"]) == 3


def test_known_cycles():
    assert manifest.known_cycles(None) == set()
    merged = manifest.merge(None, manifest.cycle_entry("2026-09-03", PACKS), at("2026-09-10"))
    assert manifest.known_cycles(merged) == {"2026-09-03"}


def test_fixture_is_what_the_pipeline_writes_today():
    current = manifest.merge(None, manifest.cycle_entry("2026-09-03", PACKS), at("2026-09-10"))
    both = manifest.merge(current, manifest.cycle_entry("2026-10-29", PACKS), at("2026-10-12"))
    street = manifest.base_entries([{"layer": "street", "region": "TX", "bytes": 9, "sha256": "cd" * 32}], "1")
    written = manifest.merge(both, None, at("2026-10-12"), street)
    fixture = Path(__file__).parent / "fixtures" / "manifest.json"
    assert json.loads(fixture.read_text()) == written


def test_merge_keeps_the_base_and_takes_its_layers_out_of_the_cycles():
    legacy = manifest.cycle_entry("2026-09-03", PACKS + [{"layer": "street", "region": "TX", "bytes": 9, "sha256": SHA}])
    street = manifest.base_entries([{"layer": "street", "region": "TX", "bytes": 9, "sha256": SHA}], "1")
    moved = manifest.merge({"version": 1, "cycles": [legacy]}, None, at("2026-09-10"), street)
    assert [p["layer"] for p in moved["cycles"][0]["packs"]] == ["vfr", "vfr", "vfr-tac"]
    assert moved["base"][0]["path"] == "charts/base/street/TX-abababababababab.pmtiles"
    later = manifest.merge(moved, manifest.cycle_entry("2026-10-29", PACKS), at("2026-09-10"))
    assert later["base"] == street
    assert manifest.missing_base(later, {"street": "1", "terrain": "1"}) == ["terrain"]
    assert manifest.missing_base(later, {"street": "2", "terrain": "1"}) == ["street", "terrain"]


def test_missing_layers_are_counted_per_cycle():
    live = manifest.merge(None, manifest.cycle_entry("2026-09-03", PACKS), at("2026-09-10"))
    layers = ["vfr", "vfr-tac", "ifr-low", "ifr-area"]
    assert manifest.missing_layers(live, "2026-09-03", layers) == ["ifr-low", "ifr-area"]
    assert manifest.missing_layers(live, "2026-10-29", layers) == layers
    assert manifest.missing_layers(None, "2026-09-03", layers) == layers


def test_enroute_packs_share_the_cycle_dates_and_path_scheme():
    entry = manifest.cycle_entry("2026-09-03", [{"layer": "ifr-low", "region": "TX", "bytes": 1, "sha256": SHA}])
    assert (entry["effective"], entry["expires"]) == ("2026-09-03T09:01:00Z", "2026-10-29T09:01:00Z")
    assert entry["packs"][0]["path"] == "charts/2026-09-03/ifr-low/TX.pmtiles"
