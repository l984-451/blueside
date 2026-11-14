import csv
import json
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import pytest

from chartpipe.pack import BadPack
from navpipe import navdb, navtiles

FIXTURES = Path(__file__).parent / "fixtures" / "nav"
TOOLS = ("tippecanoe", "tippecanoe-decode", "ogr2ogr", "pmtiles")
AUSTIN = (30.19452722, -97.66987611)
BUILT_AT = datetime(2026, 10, 13, 4, 0, tzinfo=timezone.utc)


@pytest.fixture(scope="module")
def db_path(tmp_path_factory):
    path = tmp_path_factory.mktemp("navdb") / "nav.sqlite"
    navdb.build(FIXTURES / "csv", path, "2026-10-01", BUILT_AT, "2026-09-28T13:54:26Z")
    return path


@pytest.fixture()
def db(db_path):
    connection = sqlite3.connect(db_path)
    yield connection
    connection.close()


def write_states(path: Path) -> Path:
    """Two states sharing the meridian -97 near Austin, and an island state touching neither."""
    def state(code, west, east, south=29.0, north=31.0):
        ring = [[west, south], [east, south], [east, north], [west, north], [west, south]]
        return {"type": "Feature", "properties": {"STUSPS": code},
                "geometry": {"type": "Polygon", "coordinates": [ring]}}
    path.write_text(json.dumps({"type": "FeatureCollection", "features": [
        state("TX", -99.0, -97.0), state("LA", -97.0, -95.0), state("HI", -90.0, -89.0)]}))
    return path


@pytest.fixture(scope="module")
def tiles(db_path, tmp_path_factory):
    if not all(shutil.which(tool) for tool in TOOLS):
        pytest.skip("needs tippecanoe, ogr2ogr and pmtiles")
    folder = tmp_path_factory.mktemp("tiles")
    out = folder / "nav.pmtiles"
    counts = navtiles.build(db_path, FIXTURES / "shp" / "Class_Airspace.shp", FIXTURES / "sua.geojson", out,
                            folder / "layers", "2026-10-01", write_states(folder / "states.geojson"))
    return out, counts


def test_only_the_shared_border_becomes_a_state_line_drawn_from_zoom_0(tmp_path, tiles):
    lines = navtiles.state_line_features(write_states(tmp_path / "states.geojson"))
    assert [f["geometry"] for f in lines] == [{"type": "LineString", "coordinates": [[-97.0, 31.0], [-97.0, 29.0]]}]
    assert lines[0]["tippecanoe"] == {"minzoom": 0}
    out, counts = tiles
    assert counts["states"] == 1
    assert {f["tippecanoe"]["layer"] for f in navtiles.decode(out, 0, 0, 0)} == {"states"}


def by_ident(features):
    return {f["properties"]["ident"]: f for f in features}


def test_airports_carry_rank_and_first_zoom(db):
    airports = by_ident(navtiles.airport_features(db))
    aus = airports["AUS"]
    assert aus["geometry"] == {"type": "Point", "coordinates": [-97.669876, 30.194527]}
    properties = dict(aus["properties"])
    assert isinstance(properties.pop("id"), int)
    assert {"ident": "AUS", "icao": "KAUS", "name": "AUSTIN-BERGSTROM INTL", "type": "A", "use": "PU", "twr": 1,
            "elev": 542, "rwy": 12250, "hard": 1, "rank": 1}.items() <= properties.items()
    assert aus["tippecanoe"] == {"minzoom": 4}
    assert (airports["T82"]["properties"]["rank"], airports["T82"]["tippecanoe"]["minzoom"]) == (3, 7)
    assert (airports["68TX"]["properties"]["rank"], airports["68TX"]["tippecanoe"]["minzoom"]) == (5, 9)


def test_an_icao_code_is_never_made_up_and_closed_airports_are_left_out(db):
    airports = by_ident(navtiles.airport_features(db))
    assert airports["ANC"]["properties"]["icao"] == "PANC"
    assert "icao" not in airports["T82"]["properties"]
    assert "TS01" not in airports


def test_navaids_and_fixes_first_zooms(db):
    navaids = navtiles.navaid_features(db)
    cwk = by_ident(navaids)["CWK"]
    assert {"ident": "CWK", "name": "CENTEX", "type": "VORTAC", "freq": "112.8",
            "chan": "75X"}.items() <= cwk["properties"].items()
    assert cwk["tippecanoe"] == {"minzoom": 6}
    assert not [f for f in navaids if f["properties"]["type"] == "VOT"]
    fixes = by_ident(navtiles.fix_features(db))
    assert {"ident": "BITER", "use": "WP", "enr": 1}.items() <= fixes["BITER"]["properties"].items()
    assert fixes["BITER"]["tippecanoe"] == {"minzoom": 9}
    assert min(f["tippecanoe"]["minzoom"] for f in fixes.values()) >= 9


def test_lines_break_after_a_gap_and_never_bridge_a_missing_point():
    points = [(30.0, -97.0, 0), (31.0, -97.0, 1), (32.0, -97.0, 0), (33.0, -97.0, 0), (None, None, 0),
              (35.0, -97.0, 0)]
    assert navtiles.lines(points) == [[[-97.0, 30.0], [-97.0, 31.0]], [[-97.0, 32.0], [-97.0, 33.0]]]


def test_lines_break_where_a_leg_would_cross_the_date_line():
    points = [(54.2, 178.3, 0), (54.6, -178.1, 0), (55.0, -177.0, 0)]
    assert navtiles.lines(points) == [[[-178.1, 54.6], [-177.0, 55.0]]]


def test_airway_lines_break_at_a_point_with_no_position(db):
    j21 = [f for f in navtiles.airway_features(db) if f["properties"]["ident"] == "J21"]
    assert [len(f["geometry"]["coordinates"]) for f in j21] == [4, 2]
    assert j21[0]["geometry"]["coordinates"][0] == [-99.333639, 26.933639]
    assert j21[0]["geometry"]["coordinates"][-1] == [-97.529847, 30.37855]
    assert j21[1]["geometry"]["coordinates"][0] == [-97.179426, 32.889449]
    for feature in j21:
        assert feature["geometry"]["type"] == "LineString"
        assert {"ident": "J21", "location": "C"}.items() <= feature["properties"].items()
        assert feature["tippecanoe"] == {"minzoom": 7}


def test_special_use_airspace_keeps_name_type_limits_and_hours():
    features = navtiles.sua_features(FIXTURES / "sua.geojson")
    assert len(features) == 3
    texon = next(f for f in features if f["properties"]["name"] == "TEXON MOA")
    assert texon["geometry"]["type"] == "Polygon"
    assert texon["tippecanoe"] == {"minzoom": 6}
    assert texon["properties"]["type"] == "MOA"
    assert (texon["properties"]["upper"], texon["properties"]["upper_uom"]) == (180, "FL")
    assert (texon["properties"]["lower"], texon["properties"]["lower_uom"]) == (6000, "FT")
    assert texon["properties"]["hours"] == "SUNRISE - SUNSET, MON - FRI; OTHER TIMES BY NOTAM"
    assert set(texon["properties"]) <= {"kind", "key", "name", "type", "upper", "upper_uom", "upper_code", "lower",
                                        "lower_uom", "lower_code", "hours"}


def test_an_unlimited_ceiling_is_left_out_instead_of_shown_as_a_number():
    features = navtiles.sua_features(FIXTURES / "sua.geojson")
    area = next(f for f in features if f["properties"]["name"] == "R-2501E")
    assert "upper" not in area["properties"] and "upper_uom" not in area["properties"]
    assert area["properties"]["upper_code"] == "UNLTD"
    assert (area["properties"]["lower"], area["properties"]["lower_uom"]) == (0, "FT")


def test_tile_numbers_for_austin():
    assert navtiles.tile_xy(*AUSTIN, 10) == (234, 421)
    assert navtiles.tile_xy(*AUSTIN, 4) == (3, 6)


def test_archive_has_exactly_the_six_layers(tiles):
    out, counts = tiles
    assert set(counts) == set(navtiles.LAYERS) and all(counts[name] for name in navtiles.CORE_LAYERS)
    navtiles.check(out)


def test_austin_is_in_the_zoom_10_tile_with_its_airspace(tiles):
    out, _ = tiles
    features = navtiles.decode(out, 10, *navtiles.tile_xy(*AUSTIN, 10))
    assert {"airports", "airspace"} <= {f["tippecanoe"]["layer"] for f in features}
    assert any(f["tippecanoe"]["layer"] == "airports" and f["properties"]["ident"] == "AUS" for f in features)


def test_the_zoom_4_tile_holds_major_airports_only(tiles):
    out, _ = tiles
    features = [f for f in navtiles.decode(out, 4, *navtiles.tile_xy(*AUSTIN, 4))
                if f["tippecanoe"]["layer"] != "states"]
    assert {f["tippecanoe"]["layer"] for f in features} == {"airports"}
    idents = {f["properties"]["ident"] for f in features}
    assert "AUS" in idents and "T82" not in idents


def test_check_refuses_an_archive_with_a_different_layer_list(tiles, monkeypatch):
    out, _ = tiles
    monkeypatch.setattr(navtiles, "CORE_LAYERS", navtiles.CORE_LAYERS + ("extra",))
    with pytest.raises(BadPack):
        navtiles.check(out)


def test_check_refuses_other_layers_at_the_lowest_zoom_and_a_missing_austin(tiles, monkeypatch):
    out, _ = tiles
    real = navtiles.decode
    stray = [{"tippecanoe": {"layer": "fixes"}, "properties": {"ident": "BITER"}}]
    monkeypatch.setattr(navtiles, "decode", lambda p, z, x, y: real(p, z, x, y) + (stray if z == 4 else []))
    with pytest.raises(BadPack, match="zoom 4 holds"):
        navtiles.check(out)
    monkeypatch.setattr(navtiles, "decode", lambda p, z, x, y: [] if z == 10 else real(p, z, x, y))
    with pytest.raises(BadPack, match="Austin is missing"):
        navtiles.check(out)


def test_build_stops_when_the_archive_fails_its_check(db_path, tiles, tmp_path, monkeypatch):
    def bad(path):
        raise BadPack("refused")

    monkeypatch.setattr(navtiles, "check", bad)
    with pytest.raises(BadPack, match="refused"):
        navtiles.build(db_path, FIXTURES / "shp" / "Class_Airspace.shp", FIXTURES / "sua.geojson",
                       tmp_path / "nav.pmtiles", tmp_path / "layers", "2026-10-01")


def test_an_empty_layer_stops_the_build_before_tiles_are_made(db_path, tiles, tmp_path):
    empty = tmp_path / "sua.geojson"
    empty.write_text('{"type": "FeatureCollection", "features": []}')
    with pytest.raises(BadPack, match="no features"):
        navtiles.build(db_path, FIXTURES / "shp" / "Class_Airspace.shp", empty, tmp_path / "nav.pmtiles",
                       tmp_path / "layers", "2026-10-01")
    assert not (tmp_path / "nav.pmtiles").exists()


def rebuilt(tmp_path, table, change):
    """Build from the fixture tables after passing one of them through change."""
    folder = tmp_path / "csv"
    shutil.copytree(FIXTURES / "csv", folder)
    with open(folder / f"{table}.csv", newline="", encoding="latin-1") as handle:
        reader = csv.DictReader(handle)
        fields, rows = reader.fieldnames, list(reader)
    with open(folder / f"{table}.csv", "w", newline="", encoding="latin-1") as handle:
        writer = csv.DictWriter(handle, fields, quoting=csv.QUOTE_ALL)
        writer.writeheader()
        writer.writerows(change(rows))
    navdb.build(folder, tmp_path / "nav.sqlite", "2026-10-01", BUILT_AT, "2026-09-28T13:54:26Z")
    return sqlite3.connect(tmp_path / "nav.sqlite")


def test_a_gap_row_is_stored_and_breaks_the_line(tmp_path):
    def flag(rows):
        for r in rows:
            if r["AWY_ID"] == "J21" and r["POINT_SEQ"] == "30":
                r["AWY_SEG_GAP_FLAG"] = "Y"
        return rows

    db = rebuilt(tmp_path, "AWY_SEG_ALT", flag)
    assert db.execute("SELECT gap FROM airway_points WHERE airway = 'J21' AND seq = 30").fetchone() == (1,)
    j21 = [f for f in navtiles.airway_features(db) if f["properties"]["ident"] == "J21"]
    assert [len(f["geometry"]["coordinates"]) for f in j21] == [2, 2, 2]
    db.close()


def test_a_shut_down_navaid_is_left_off_the_map(tmp_path):
    def shut(rows):
        for r in rows:
            if r["NAV_ID"] == "INL":
                r["NAV_STATUS"] = "SHUTDOWN"
        return rows

    db = rebuilt(tmp_path, "NAV_BASE", shut)
    assert "INL" not in {f["properties"]["ident"] for f in navtiles.navaid_features(db)}
    db.close()
