import hashlib
import sqlite3

import pytest

from chartpipe import pack


def make_tiles(root, tiles):
    for z, x, y in tiles:
        folder = root / str(z) / str(x)
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"{y}.webp").write_bytes(f"{z}/{x}/{y}".encode())


def test_mbtiles_holds_every_tile_with_flipped_rows(tmp_path):
    make_tiles(tmp_path / "t", [(1, 0, 0), (1, 1, 1), (2, 3, 0)])
    count = pack.tiles_to_mbtiles(tmp_path / "t", tmp_path / "out.mbtiles", "test")
    assert count == 3
    db = sqlite3.connect(tmp_path / "out.mbtiles")
    rows = set(db.execute("SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles"))
    # MBTiles rows count from the south: row = 2**z - 1 - y
    assert rows == {(1, 0, 1, b"1/0/0"), (1, 1, 0, b"1/1/1"), (2, 3, 3, b"2/3/0")}
    meta = dict(db.execute("SELECT name, value FROM metadata"))
    assert meta["format"] == "webp" and meta["minzoom"] == "1" and meta["maxzoom"] == "2"


def test_mbtiles_refuses_an_empty_tile_folder(tmp_path):
    (tmp_path / "t").mkdir()
    with pytest.raises(pack.BadPack):
        pack.tiles_to_mbtiles(tmp_path / "t", tmp_path / "out.mbtiles", "test")


def test_describe_gives_size_and_lowercase_sha256(tmp_path):
    f = tmp_path / "x.pmtiles"
    f.write_bytes(b"abc")
    assert pack.describe(f) == (3, hashlib.sha256(b"abc").hexdigest())


def test_check_zooms_raises_on_a_wrong_range(tmp_path, monkeypatch):
    monkeypatch.setattr(pack, "zoom_range", lambda path: (4, 0))
    with pytest.raises(pack.BadPack) as error:
        pack.check_zooms(tmp_path / "TX.pmtiles", (4, 12))
    assert "TX.pmtiles" in str(error.value)


def test_check_zooms_accepts_the_expected_range(tmp_path, monkeypatch):
    monkeypatch.setattr(pack, "zoom_range", lambda path: (4, 12))
    pack.check_zooms(tmp_path / "TX.pmtiles", (4, 12))


def test_state_codes_cover_states_dc_and_puerto_rico():
    assert len(pack.STATE_CODES) == 52 and len(set(pack.STATE_CODES)) == 52
    assert {"TX", "AK", "HI", "DC", "PR"} <= set(pack.STATE_CODES)


def test_missing_states_names_required_states_without_a_vfr_pack():
    packs = [{"layer": "vfr", "region": code} for code in pack.STATE_CODES if code not in ("TX", "AK", "HI")]
    packs.append({"layer": "vfr-tac", "region": "TX"})
    # AK and HI are optional; a terminal pack does not stand in for the sectional one.
    assert pack.missing_states(packs) == ["TX"]
    assert pack.missing_states(packs + [{"layer": "vfr", "region": "TX"}]) == []
