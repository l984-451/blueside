from datetime import datetime, timezone

import pytest

from chartpipe.pack import BadPack
from navpipe import __main__ as cli
from navpipe import navtiles

BUILT_AT = datetime(2026, 10, 13, 4, 0, tzinfo=timezone.utc)
NATIONAL = {"airports": 19135, "navaids": 1524, "fixes": 70129, "airspace": 1287, "airways": 1751, "sua": 1542,
            "runways": 8700, "rwy_ends": 17400, "airspace_pt": 1250, "sua_pt": 1300, "obstacles": 203758,
            "class_e": 854, "class_e5": 1400, "pja": 690, "maa": 173, "states": 74,
            "surface": 111754, "taxiways": 88380, "fbo": 796}


def test_a_full_national_count_passes():
    navtiles.check_national(NATIONAL)


def test_every_layer_has_a_floor():
    assert set(navtiles.MINIMUM) == set(navtiles.LAYERS) == set(NATIONAL)


@pytest.mark.parametrize("layer", sorted(NATIONAL))
def test_a_layer_that_is_empty_or_missing_is_refused(layer):
    with pytest.raises(BadPack, match=layer):
        navtiles.check_national({**NATIONAL, layer: 0})
    with pytest.raises(BadPack, match=layer):
        navtiles.check_national({name: count for name, count in NATIONAL.items() if name != layer})


def test_a_thin_layer_stops_the_cycle_before_the_manifest_step(monkeypatch, tmp_path):
    monkeypatch.setattr(cli.nasr, "fetch_cycle", lambda cycle_id, work: (work / "csv", work / "a.shp"))
    monkeypatch.setattr(cli.surface, "fetch", lambda cache, now: None)
    monkeypatch.setattr(cli.nasr, "fetch_obstacles", lambda work: work / "DOF.CSV")
    monkeypatch.setattr(cli.nasr, "fetch_sua", lambda target, pending=False: "2026-09-28T13:54:26Z")
    monkeypatch.setattr(cli.navdb, "build", lambda *args: {})
    monkeypatch.setattr(cli.navdb, "check_national", lambda counts: None)
    monkeypatch.setattr(cli.navtiles, "build", lambda *args: {**NATIONAL, "obstacles": 12})
    monkeypatch.setattr(cli.publish, "cycle_entry", lambda cycle_id, out: pytest.fail("reached the manifest step"))
    with pytest.raises(BadPack, match="obstacles"):
        cli.build_cycle("2026-10-01", tmp_path / "work", tmp_path / "out", BUILT_AT)
