import json
import shutil

import pytest

from navhelp import FIXTURES, TOOLS, database, shapefile, square
from navpipe import navtiles


@pytest.fixture()
def db(tmp_path):
    connection = database(tmp_path)
    yield connection
    connection.close()


def by_ident(features):
    return {f["properties"]["ident"]: f for f in features}


def test_every_point_has_a_kind_a_key_and_a_numeric_id(db):
    for features, kind in ((navtiles.airport_features(db), "airport"), (navtiles.navaid_features(db), "navaid"),
                           (navtiles.fix_features(db), "fix")):
        assert features
        for feature in features:
            assert feature["properties"]["kind"] == kind
            assert isinstance(feature["id"], int) and feature["id"] > 0
            assert feature["properties"]["key"] == str(feature["id"])


def test_an_airport_key_finds_its_row(db):
    aus = by_ident(navtiles.airport_features(db))["AUS"]["properties"]
    assert aus["key"] == str(aus["id"])
    assert db.execute("SELECT ident FROM airports WHERE id = ?", (int(aus["key"]),)).fetchone() == ("AUS",)


def test_an_airway_key_names_the_airway_and_its_runs_share_one_id(db):
    j21 = [f for f in navtiles.airway_features(db) if f["properties"]["ident"] == "J21"]
    assert len(j21) == 2
    assert {f["properties"]["key"] for f in j21} == {"J21|C"}
    assert {f["properties"]["kind"] for f in j21} == {"airway"}
    assert len({f["id"] for f in j21}) == 1 and isinstance(j21[0]["id"], int)


def test_airways_are_flagged_low_or_high_and_other_letters_get_no_flag(tmp_path):
    def copies(rows):
        j21 = [r for r in rows if r["AWY_ID"] == "J21"]
        return rows + [{**r, "AWY_ID": "V21"} for r in j21] + [{**r, "AWY_ID": "A21"} for r in j21]

    db = database(tmp_path, {"AWY_SEG_ALT": copies})
    level = {f["properties"]["ident"]: f["properties"].get("level") for f in navtiles.airway_features(db)}
    db.close()
    assert (level["J21"], level["V21"], level["A21"]) == ("high", "low", None)


def test_test_signals_and_fan_markers_are_left_out(tmp_path):
    def add(rows):
        cwk = next(r for r in rows if r["NAV_ID"] == "CWK")
        return rows + [{**cwk, "NAV_ID": "ZZF", "NAV_TYPE": "FAN MARKER"}]

    db = database(tmp_path, {"NAV_BASE": add})
    kinds = {f["properties"]["type"] for f in navtiles.navaid_features(db)}
    db.close()
    assert "VORTAC" in kinds and "VOT" not in kinds and "FAN MARKER" not in kinds


def test_a_vfr_waypoint_is_flagged_and_shown_from_zoom_8(tmp_path):
    def add(rows):
        return rows + [{**rows[0], "FIX_ID": "VPAUS", "FIX_USE_CODE": "VFR", "CHARTS": "SECTIONAL"}]

    db = database(tmp_path, {"FIX_BASE": add})
    fixes = by_ident(navtiles.fix_features(db))
    db.close()
    assert fixes["VPAUS"]["properties"]["vfr"] == 1 and fixes["VPAUS"]["tippecanoe"] == {"minzoom": 8}
    assert "vfr" not in fixes["BITER"]["properties"] and fixes["BITER"]["tippecanoe"] == {"minzoom": 9}


def test_a_public_heliport_is_ranked_with_public_fields(tmp_path):
    def public(rows):
        for r in rows:
            if r["ARPT_ID"] == "68TX":
                r["FACILITY_USE_CODE"] = "PU"
        return rows

    db = database(tmp_path, {"APT_BASE": public})
    pad = by_ident(navtiles.airport_features(db))["68TX"]
    db.close()
    assert (pad["properties"]["rank"], pad["tippecanoe"]["minzoom"]) == (4, 8)


def test_a_private_heliport_stays_in_the_last_rank(db):
    assert by_ident(navtiles.airport_features(db))["68TX"]["properties"]["rank"] == 5


def test_special_use_areas_take_the_faa_object_number_as_key():
    features = navtiles.sua_features(FIXTURES / "sua.geojson")
    assert sorted(f["id"] for f in features) == [49, 267, 1397]
    texon = next(f for f in features if f["properties"]["name"] == "TEXON MOA")
    assert (texon["properties"]["kind"], texon["properties"]["key"]) == ("sua", "267")


def test_a_placeholder_ident_is_dropped_and_the_shape_is_kept(tmp_path):
    if not shutil.which("ogr2ogr"):
        pytest.skip("needs ogr2ogr")
    shp = shapefile(tmp_path, [
        ({"IDENT": "<Null>", "NAME": "NOWHERE CLASS D", "CLASS": "D", "LOCAL_TYPE": "CLASS_D",
          "UPPER_VAL": "2500", "LOWER_VAL": "0", "WKHR_CODE": "H24"}, square(-98.0, 30.0, 0.1)),
        ({"IDENT": "AUS", "NAME": "AUSTIN CLASS C", "CLASS": "C", "LOCAL_TYPE": "CLASS_C",
          "UPPER_VAL": "4500", "LOWER_VAL": "0", "WKHR_CODE": "H24"}, square(-97.8, 30.1, 0.2))])
    out = tmp_path / "airspace.geojson"
    assert navtiles._write_airspace(shp, out) == 2
    first, second = (json.loads(line) for line in out.read_text().splitlines())
    assert "ident" not in first["properties"] and first["properties"]["name"] == "NOWHERE CLASS D"
    assert second["properties"]["ident"] == "AUS"
    assert [(f["id"], f["properties"]["key"], f["properties"]["kind"]) for f in (first, second)] == [
        (1, "1", "airspace"), (2, "2", "airspace")]
    assert "row" not in first["properties"]


@pytest.fixture(scope="module")
def tiles(tmp_path_factory):
    if not all(shutil.which(tool) for tool in TOOLS):
        pytest.skip("needs tippecanoe, ogr2ogr and pmtiles")
    folder = tmp_path_factory.mktemp("keys")
    database(folder).close()
    out = folder / "nav.pmtiles"
    navtiles.build(folder / "nav.sqlite", FIXTURES / "shp" / "Class_Airspace.shp", FIXTURES / "sua.geojson", out,
                   folder / "layers", "2026-10-01")
    return out


def test_ids_kinds_and_keys_survive_into_the_tiles(tiles):
    features = navtiles.decode(tiles, 10, *navtiles.tile_xy(*navtiles.AUSTIN, 10))
    assert {"airports", "airspace"} <= {f["tippecanoe"]["layer"] for f in features}
    for feature in features:
        assert isinstance(feature.get("id"), int), feature["tippecanoe"]["layer"]
        assert feature["properties"]["kind"] and isinstance(feature["properties"]["key"], str)


def test_the_archive_is_built_on_the_finer_grid(tiles):
    options = navtiles._show(tiles, "--metadata")["generator_options"]
    assert "--full-detail=13" in options and "--simplification=1" in options and "--simplification=4" not in options
