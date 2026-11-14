import shutil

import pytest

from navhelp import FIXTURES, TOOLS, database
from navpipe import airfield, navtiles

NOTHING_LEFT = {"no_ends": 0, "conflict": 0, "backwards": 0, "estimated": 0}


@pytest.fixture()
def db(tmp_path):
    connection = database(tmp_path)
    yield connection
    connection.close()


def by(features, name):
    return {f["properties"][name]: f for f in features}


def test_outline_is_built_from_the_two_ends_and_the_width():
    ring, built = airfield.rectangle((-97.67936477, 30.21361613), (-97.67847469, 30.17994322), 150)
    assert abs(built - 12250) < 5
    assert len(ring) == 5 and ring[0] == ring[-1]
    across = abs(ring[0][0] - ring[3][0]) * 96295 / 0.3048
    assert abs(across - 150) < 1


def test_every_open_runway_gets_an_outline_and_two_end_points(db):
    outlines, ends, left = navtiles.runway_features(db)
    assert sorted(by(outlines, "rwy")) == ["07L/25R", "07R/25L", "14/32", "15/33", "18L/36R", "18R/36L"]
    assert len(ends) == 12 and left == NOTHING_LEFT
    for feature in outlines:
        assert feature["geometry"]["type"] == "Polygon" and feature["properties"]["kind"] == "runway"
        assert isinstance(feature["id"], int)
    assert len({f["id"] for f in ends}) == 12


def test_outlines_carry_the_towered_paved_and_long_runway_flags(db):
    outlines = by(navtiles.runway_features(db)[0], "rwy")
    aus, t82 = outlines["18L/36R"], outlines["14/32"]
    assert (aus["properties"]["twr"], aus["properties"]["paved"], aus["properties"]["big"]) == (1, 1, 1)
    assert aus["properties"]["len"] == 9000 and aus["tippecanoe"] == {"minzoom": 9}
    assert aus["properties"]["key"] == f"{aus['properties']['apt']}|18L/36R"
    assert (t82["properties"]["twr"], t82["properties"]["paved"]) == (0, 1) and "big" not in t82["properties"]
    assert t82["tippecanoe"] == {"minzoom": 10}


def test_outlines_come_early_wherever_a_style_may_drop_the_symbol_early(tmp_path):
    def gravel(rows):
        base = next(r for r in rows if r["ARPT_ID"] == "T82")
        return rows + [{**base, "RWY_ID": "09/27", "RWY_LEN": "9600", "SURFACE_TYPE_CODE": "GRVL"}]

    def gravel_ends(rows):
        base = {**next(r for r in rows if r["ARPT_ID"] == "T82"), "RWY_ID": "09/27", "LAT_DECIMAL": "30.2432"}
        return rows + [{**base, "RWY_END_ID": "09", "TRUE_ALIGNMENT": "90", "LONG_DECIMAL": "-98.9250"},
                       {**base, "RWY_END_ID": "27", "TRUE_ALIGNMENT": "270", "LONG_DECIMAL": "-98.8946"}]

    db = database(tmp_path, {"APT_RWY": gravel, "APT_RWY_END": gravel_ends})
    outlines, _, left = navtiles.runway_features(db)
    field = by(navtiles.airport_features(db, navtiles.drawn_fields(db, outlines)), "ident")["T82"]["properties"]
    db.close()
    # A paved field whose longest runway is long gravel: a style that reads hard and rwy hides its disc.
    assert (field["hard"], field["geom"]) == (1, 1) and field["rwy"] >= airfield.LONG_RUNWAY and "big" not in field
    assert left == NOTHING_LEFT
    assert by(outlines, "rwy")["14/32"]["tippecanoe"] == by(outlines, "rwy")["09/27"]["tippecanoe"] == {"minzoom": 9}


def wet(field, runway):
    def change(rows):
        for r in rows:
            if r["ARPT_ID"] == field and r["RWY_ID"] == runway:
                r["SURFACE_TYPE_CODE"] = "WATER"
        return rows

    return {"APT_RWY": change}


def test_a_water_lane_with_a_plain_number_says_it_is_water_on_the_outline_and_both_ends(tmp_path):
    db = database(tmp_path, wet("T82", "14/32"))
    outlines, ends, _ = navtiles.runway_features(db)
    db.close()
    lane, ends = by(outlines, "rwy")["14/32"]["properties"], by(ends, "end")
    assert lane["water"] == 1 and "paved" not in lane
    assert ends["14"]["properties"]["water"] == 1 and ends["32"]["properties"]["water"] == 1
    land = by(outlines, "rwy")["18L/36R"]["properties"]
    assert "water" not in land and "water" not in ends["18L"]["properties"]


def test_a_field_whose_only_outlines_are_water_lanes_keeps_its_symbol(tmp_path):
    db = database(tmp_path, wet("T82", "14/32"))
    outlines, _, _ = navtiles.runway_features(db)
    found = by(navtiles.airport_features(db, navtiles.drawn_fields(db, outlines)), "ident")
    db.close()
    assert "14/32" in by(outlines, "rwy") and "geom" not in found["T82"]["properties"]


def test_a_water_lane_beside_drawn_land_runways_leaves_the_shape_flag_alone(tmp_path):
    db = database(tmp_path, wet("AUS", "18L/36R"))
    outlines, _, _ = navtiles.runway_features(db)
    found = by(navtiles.airport_features(db, navtiles.drawn_fields(db, outlines)), "ident")
    db.close()
    assert by(outlines, "rwy")["18L/36R"]["properties"]["water"] == 1
    assert found["AUS"]["properties"]["geom"] == 1


def test_end_points_carry_the_end_name_heading_and_displaced_threshold(db):
    ends = {end: f["properties"] for end, f in by(navtiles.runway_features(db)[1], "end").items()}
    assert (ends["18R"]["hdg"], ends["18R"]["hdg_src"]) == (179, "surveyed")
    assert ends["33"]["disp"] == 465 and "disp" not in ends["15"]
    assert (ends["36L"]["twr"], ends["14"]["twr"]) == (1, 0)
    assert ends["14"]["kind"] == "runway_end" and ends["14"]["key"].endswith("|14/32|14")


def test_an_end_with_no_surveyed_heading_is_marked_derived(tmp_path):
    def blank(rows):
        for r in rows:
            if r["ARPT_ID"] == "T82":
                r["TRUE_ALIGNMENT"] = ""
        return rows

    db = database(tmp_path, {"APT_RWY_END": blank})
    ends = {end: f["properties"] for end, f in by(navtiles.runway_features(db)[1], "end").items()}
    db.close()
    assert (ends["14"]["hdg"], ends["14"]["hdg_src"]) == (147, "derived")
    assert (ends["32"]["hdg"], ends["32"]["hdg_src"]) == (327, "derived")


def swapped(survey):
    def change(rows):
        first, second = (r for r in rows if r["ARPT_ID"] == "T82")
        for column in ("LAT_DECIMAL", "LONG_DECIMAL"):
            first[column], second[column] = second[column], first[column]
        if not survey:
            first["TRUE_ALIGNMENT"] = second["TRUE_ALIGNMENT"] = ""
        return rows

    return change


def no_variation(rows):
    for r in rows:
        if r["ARPT_ID"] == "T82":
            r["MAG_VARN"] = r["MAG_HEMIS"] = ""
    return rows


@pytest.mark.parametrize("changes", [
    {"APT_RWY_END": swapped(survey=False)},
    {"APT_RWY_END": swapped(survey=False), "APT_BASE": no_variation},
    {"APT_RWY_END": swapped(survey=True)},
], ids=["number and variation", "number alone", "surveyed heading"])
def test_ends_filed_at_each_others_positions_are_not_shown_and_the_outline_stays(tmp_path, changes):
    db = database(tmp_path, changes)
    outlines, ends, left = navtiles.runway_features(db)
    db.close()
    # Shown, end 14 would be printed at the threshold of runway 32.
    assert "14/32" in by(outlines, "rwy")
    assert not {"14", "32"} & set(by(ends, "end")) and len(ends) == 10
    assert left == {**NOTHING_LEFT, "backwards": 1}


def test_an_end_named_for_a_direction_keeps_its_point(tmp_path):
    def named(rows):
        for r in rows:
            if r["ARPT_ID"] == "T82":
                r["TRUE_ALIGNMENT"] = ""
                r["RWY_END_ID"] = {"14": "NW", "32": "SE"}[r["RWY_END_ID"]]
        return rows

    db = database(tmp_path, {"APT_RWY_END": named})
    _, ends, left = navtiles.runway_features(db)
    db.close()
    assert by(ends, "end")["NW"]["properties"]["hdg_src"] == "derived" and left == NOTHING_LEFT


def test_the_only_runway_without_end_positions_is_centered_on_the_airport_along_its_heading(tmp_path):
    def blank(rows):
        for r in rows:
            if r["ARPT_ID"] == "T82":
                r["LAT_DECIMAL"] = r["LONG_DECIMAL"] = ""
        return rows

    db = database(tmp_path, {"APT_RWY_END": blank})
    outlines, ends, left = navtiles.runway_features(db)
    db.close()
    ring = by(outlines, "rwy")["14/32"]["geometry"]["coordinates"][0]
    middle = sum(x for x, _ in ring[:4]) / 4, sum(y for _, y in ring[:4]) / 4
    assert abs(middle[0] - -98.90918666) < 1e-6 and abs(middle[1] - 30.24324305) < 1e-6
    ends = by(ends, "end")
    assert ends["14"]["properties"]["hdg"] == 147 and ends["32"]["properties"]["hdg"] == 327
    _, built = airfield.rectangle(ends["14"]["geometry"]["coordinates"], ends["32"]["geometry"]["coordinates"], 75)
    assert abs(built - 5002) < 1
    assert left == {**NOTHING_LEFT, "estimated": 1}


def test_a_runway_with_one_surveyed_end_runs_from_it_for_its_length(tmp_path):
    def blank(rows):
        for r in rows:
            if r["ARPT_ID"] == "AUS" and r["RWY_END_ID"] == "36L":
                r["LAT_DECIMAL"] = r["LONG_DECIMAL"] = ""
        return rows

    db = database(tmp_path, {"APT_RWY_END": blank})
    outlines, ends, left = navtiles.runway_features(db)
    db.close()
    far = by(ends, "end")["36L"]["geometry"]["coordinates"]
    # The surveyed 36L is some metres off a line flown on 18R's whole-degree heading.
    assert abs(far[1] - 30.17994322) * 111000 < 10 and abs(far[0] - -97.67847469) * 96000 < 50
    assert "18R/36L" in by(outlines, "rwy") and left == {**NOTHING_LEFT, "estimated": 1}


def test_a_runway_without_end_positions_at_a_field_with_others_is_left_out_and_counted(tmp_path):
    def blank(rows):
        for r in rows:
            if r["ARPT_ID"] == "ANC" and r["RWY_ID"] == "15/33":
                r["LAT_DECIMAL"] = r["LONG_DECIMAL"] = ""
        return rows

    db = database(tmp_path, {"APT_RWY_END": blank})
    outlines, ends, left = navtiles.runway_features(db)
    db.close()
    assert "15/33" not in by(outlines, "rwy") and "15" not in by(ends, "end")
    assert left == {**NOTHING_LEFT, "no_ends": 1}


def test_an_outline_that_disagrees_with_the_published_length_is_held_back(tmp_path):
    def shorter(rows):
        for r in rows:
            if r["ARPT_ID"] == "AUS" and r["RWY_ID"] == "18R/36L":
                r["RWY_LEN"] = "11000"
        return rows

    db = database(tmp_path, {"APT_RWY": shorter})
    outlines, _, left = navtiles.runway_features(db)
    db.close()
    assert "18R/36L" not in by(outlines, "rwy") and left == {**NOTHING_LEFT, "conflict": 1}


def test_a_closed_runway_is_drawn_marked_closed_without_end_points(tmp_path):
    def close(rows):
        base = next(r for r in rows if r["ARPT_ID"] == "AUS")
        return rows + [{**base, "TAB_NAME": "RUNWAY", "REF_COL_NAME": "RWY_ID", "ELEMENT": "18L/36R",
                        "REF_COL_SEQ_NO": "1", "REMARK": "RWY CLSD."}]

    db = database(tmp_path, {"APT_RMK": close})
    outlines, ends, left = navtiles.runway_features(db)
    db.close()
    assert by(outlines, "rwy")["18L/36R"]["properties"]["closed"] == 1 and left == NOTHING_LEFT
    assert "closed" not in by(outlines, "rwy")["18R/36L"]["properties"]
    assert not {"18L", "36R"} & set(by(ends, "end"))


def test_a_field_with_an_open_runway_left_out_keeps_its_symbol(tmp_path):
    def blank(rows):
        for r in rows:
            if r["ARPT_ID"] == "AUS" and r["RWY_ID"] == "18R/36L":
                r["LAT_DECIMAL"] = r["LONG_DECIMAL"] = ""
        return rows

    db = database(tmp_path, {"APT_RWY_END": blank})
    outlines, _, left = navtiles.runway_features(db)
    drawn = navtiles.drawn_fields(db, outlines)
    found = {f["properties"]["ident"]: f["properties"] for f in navtiles.airport_features(db, drawn)}
    db.close()
    assert "18L/36R" in by(outlines, "rwy") and left["no_ends"] == 1
    assert "geom" not in found["AUS"] and found["T82"]["geom"] == 1 and found["ANC"]["geom"] == 1


def test_a_closed_runway_does_not_cost_the_field_its_shape_flag(tmp_path):
    def close(rows):
        base = next(r for r in rows if r["ARPT_ID"] == "AUS")
        return rows + [{**base, "TAB_NAME": "RUNWAY", "REF_COL_NAME": "RWY_ID", "ELEMENT": "18L/36R",
                        "REF_COL_SEQ_NO": "1", "REMARK": "RWY CLSD."}]

    db = database(tmp_path, {"APT_RMK": close})
    drawn = navtiles.drawn_fields(db, navtiles.runway_features(db)[0])
    aus = db.execute("SELECT id FROM airports WHERE ident = 'AUS'").fetchone()[0]
    db.close()
    assert aus in drawn


def test_runways_reach_the_tiles_and_the_airport_says_it_has_shapes(tmp_path):
    if not all(shutil.which(tool) for tool in TOOLS):
        pytest.skip("needs tippecanoe, ogr2ogr and pmtiles")
    database(tmp_path).close()
    out = tmp_path / "nav.pmtiles"
    counts = navtiles.build(tmp_path / "nav.sqlite", FIXTURES / "shp" / "Class_Airspace.shp",
                            FIXTURES / "sua.geojson", out, tmp_path / "layers", "2026-10-01")
    assert (counts["runways"], counts["rwy_ends"]) == (6, 12)
    features = navtiles.decode(out, 10, *navtiles.tile_xy(*navtiles.AUSTIN, 10))
    assert {"runways", "rwy_ends"} <= {f["tippecanoe"]["layer"] for f in features}
    aus = next(f for f in features if f["tippecanoe"]["layer"] == "airports" and f["properties"]["ident"] == "AUS")
    assert aus["properties"]["geom"] == 1
    assert "--no-tiny-polygon-reduction" in navtiles._show(out, "--metadata")["generator_options"]
