import json
import shutil

import pytest

from navhelp import FIXTURES, database, shapefile, square
from navpipe import navtiles

SURFACE = {"UPPER_VAL": "3300", "LOWER_VAL": "0", "LOWER_CODE": "SFC"}
SHAPES = [
    ({"IDENT": "GTU", "NAME": "GEORGETOWN CLASS D", "CLASS": "D", "LOCAL_TYPE": "CLASS_D", "WKHR_CODE": "NOTAM",
      **SURFACE}, square(-97.75, 30.60, 0.14)),
    ({"IDENT": "GTU", "NAME": "GEORGETOWN CLASS E2", "CLASS": "E", "LOCAL_TYPE": "CLASS_E2", "WKHR_CODE": "NOTAM",
      **SURFACE}, square(-97.75, 30.60, 0.14)),
    ({"IDENT": "BMQ", "NAME": "BURNET CLASS E2", "CLASS": "E", "LOCAL_TYPE": "CLASS_E2", "WKHR_CODE": "H24",
      **SURFACE}, square(-98.30, 30.70, 0.14)),
    ({"IDENT": "GTU", "NAME": "GEORGETOWN CLASS E4", "CLASS": "E", "LOCAL_TYPE": "CLASS_E4", "WKHR_CODE": "NOTAM",
      **SURFACE}, square(-97.61, 30.60, 0.05)),
    ({"NAME": "AUSTIN CLASS E5", "CLASS": "E", "LOCAL_TYPE": "CLASS_E5", "UPPER_VAL": "18000", "LOWER_VAL": "700",
      "LOWER_CODE": "SFC"}, square(-98.20, 29.80, 1.0)),
    ({"IDENT": "TPL", "NAME": "TEMPLE CLASS D", "CLASS": "D", "LOCAL_TYPE": "CLASS_D", "WKHR_CODE": "H24",
      **SURFACE}, square(-97.47, 31.08, 0.14)),
    ({"IDENT": "TPL", "NAME": "TEMPLE CLASS E2", "CLASS": "E", "LOCAL_TYPE": "CLASS_E2", "WKHR_CODE": "H24",
      **SURFACE}, square(-97.47, 31.08, 0.14)),
]


def written(tmp_path, shapes=SHAPES):
    if not shutil.which("ogr2ogr"):
        pytest.skip("needs ogr2ogr")
    shp = shapefile(tmp_path, shapes)
    towers, surface = tmp_path / "airspace.geojson", tmp_path / "class_e.geojson"
    assert navtiles._write_airspace(shp, towers) == 2
    count = navtiles._write_airspace(shp, surface, navtiles.E_SURFACE, navtiles.CLASS_E_ZOOM,
                                     navtiles.part_time_towers(towers))
    return count, {f["properties"]["name"]: f for f in map(json.loads, surface.read_text().splitlines())}


def test_surface_areas_are_their_own_layer_and_transition_areas_stay_out(tmp_path):
    count, areas = written(tmp_path)
    assert count == 4
    assert set(areas) == {"GEORGETOWN CLASS E2", "BURNET CLASS E2", "GEORGETOWN CLASS E4", "TEMPLE CLASS E2"}
    assert {f["properties"]["key"] for f in areas.values()} == {"2", "3", "4", "7"}
    for feature in areas.values():
        assert feature["properties"]["kind"] == "airspace" and feature["tippecanoe"] == {"minzoom": 6}
        assert feature["id"] == int(feature["properties"]["key"])
    assert areas["GEORGETOWN CLASS E4"]["properties"]["local_type"] == "CLASS_E4"


def test_only_the_e2_that_stands_in_for_a_part_time_tower_is_flagged(tmp_path):
    _, areas = written(tmp_path)
    assert areas["GEORGETOWN CLASS E2"]["properties"]["alt_of"] == "D"
    for name in ("BURNET CLASS E2", "GEORGETOWN CLASS E4", "TEMPLE CLASS E2"):
        assert "alt_of" not in areas[name]["properties"]


def test_a_part_time_class_c_is_named_by_its_letter(tmp_path):
    tower = ({**SHAPES[0][0], "NAME": "GEORGETOWN CLASS C", "CLASS": "C", "LOCAL_TYPE": "CLASS_C"}, SHAPES[0][1])
    _, areas = written(tmp_path, [tower] + SHAPES[1:])
    assert areas["GEORGETOWN CLASS E2"]["properties"]["alt_of"] == "C"


def test_a_file_with_no_class_e_gives_an_empty_layer(tmp_path):
    if not shutil.which("ogr2ogr"):
        pytest.skip("needs ogr2ogr")
    out = tmp_path / "class_e.geojson"
    count = navtiles._write_airspace(FIXTURES / "shp" / "Class_Airspace.shp", out, navtiles.E_SURFACE,
                                     navtiles.CLASS_E_ZOOM, {})
    assert count == 0 and out.read_text() == ""


@pytest.fixture()
def db(tmp_path):
    connection = database(tmp_path)
    yield connection
    connection.close()


def stored(db):
    rows = db.execute("SELECT ident, type, name, lat, lon, max_alt, radius, hours, airport, charted "
                      "FROM activity_areas")
    return {ident: rest for ident, *rest in rows}


def test_jump_areas_are_stored_as_published_and_one_without_a_position_is_left_out(db):
    rows = stored(db)
    assert set(rows) == {"PAK001", "PTX901", "AAL001", "GTX901"}
    assert rows["PAK001"] == ["PARACHUTE", None, 62.95104027, -155.61140277, "5000 MSL", None,
                              "JUN- SEP;IRREGULAR HOURS", "16Z", 0]
    assert rows["PTX901"] == ["PARACHUTE", "SKYDIVE SAN MARCOS", 29.89277777, -97.86305555, "14000 MSL", "3",
                              "SR-SS DAILY", "HYI", 1]


def test_an_activity_area_takes_its_published_point_or_the_middle_of_its_outline(db):
    rows = stored(db)
    glider, aerobatic = rows["GTX901"], rows["AAL001"]
    assert glider[0] == "GLIDER" and glider[1] == "TEST SOARING" and glider[-1] is None
    assert (glider[2], glider[3]) == pytest.approx((32.45, -96.9125), abs=1e-6)
    assert (glider[4], glider[5]) == ("12000MSL", "5")
    assert aerobatic[0] == "AEROBATIC PRACTICE" and aerobatic[1] is None and aerobatic[7] == "JFX"
    assert (aerobatic[2], aerobatic[3]) == pytest.approx((33.90162, -87.31941), abs=1e-4)


def test_the_tiles_split_parachute_areas_from_the_rest(db):
    jump, other = navtiles.activity_features(db)
    by_ident = {f["properties"]["ident"]: f for f in jump + other}
    assert {f["properties"]["ident"] for f in jump} == {"PAK001", "PTX901"}
    assert {f["properties"]["type"] for f in other} == {"AEROBATIC PRACTICE", "GLIDER"}
    marcos = by_ident["PTX901"]
    assert {"kind": "activity", "type": "PARACHUTE", "name": "SKYDIVE SAN MARCOS", "max": "14000 MSL",
            "radius": "3", "chart": 1}.items() <= marcos["properties"].items()
    assert marcos["tippecanoe"] == {"minzoom": 8} and marcos["properties"]["key"] == str(marcos["id"])
    assert marcos["geometry"]["coordinates"] == [-97.863056, 29.892778]
    assert not {"name", "chart", "radius"} & set(by_ident["PAK001"]["properties"])


def test_the_faa_no_value_ceiling_is_left_out_not_shipped(tmp_path):
    shapes = [({**props, "UPPER_VAL": "-9998"}, shape) if props["NAME"] == "BURNET CLASS E2" else (props, shape)
              for props, shape in SHAPES]
    _, areas = written(tmp_path, shapes)
    assert "upper" not in areas["BURNET CLASS E2"]["properties"]


def test_class_e_from_700_ft_is_its_own_layer_with_its_floor(tmp_path):
    if not shutil.which("ogr2ogr"):
        pytest.skip("needs ogr2ogr")
    high = ({**SHAPES[4][0], "NAME": "HIGH CLASS E5", "LOWER_VAL": "9500", "LOWER_CODE": "MSL"}, square(-99, 29, 1))
    out = tmp_path / "class_e5.geojson"
    count = navtiles._write_airspace(shapefile(tmp_path, SHAPES + [high]), out, navtiles.E5, navtiles.E5_ZOOM,
                                     simplify=navtiles.E5_SIMPLIFY)
    feature, = map(json.loads, out.read_text().splitlines())
    assert count == 1 and feature["tippecanoe"] == {"minzoom": 6}
    assert {"name": "AUSTIN CLASS E5", "local_type": "CLASS_E5", "lower": 700}.items() <= feature["properties"].items()
