import json
import math
import shutil

import pytest

from chartpipe.pack import BadPack
from navhelp import FIXTURES, TOOLS, database, lines, square
from navpipe import labels, navtiles

CORE, SHELF = square(-97.8, 30.1, 0.2), square(-98.0, 29.9, 0.6)


def shape(key, name, lower, geometry, **more):
    return {"type": "Feature", "id": int(key), "tippecanoe": {"minzoom": 6}, "geometry": geometry,
            "properties": {"kind": "airspace", "key": key, "name": name, "class": "C", "lower": lower,
                           "upper": 4500, **more}}


def area(key, name, lower, upper, geometry, **more):
    return {"type": "Feature", "id": int(key), "tippecanoe": {"minzoom": 6}, "geometry": geometry,
            "properties": {"kind": "sua", "key": key, "name": name, "type": "R", "lower": lower, "lower_uom": "FT",
                           "lower_code": "MSL", "upper": upper, "upper_uom": "FT", "upper_code": "MSL",
                           "hours": "CONTINUOUS", **more}}


def label(key, name, lower, lon, lat, room=1.0):
    return {"type": "Feature", "id": int(key), "geometry": {"type": "Point", "coordinates": [lon, lat]},
            "properties": {"kind": "airspace", "key": key, "name": name, "lower": lower, "room": room}}


def austin(tmp_path):
    return lines(tmp_path / "airspace.geojson", [shape("1", "AUSTIN CLASS C", 0, CORE),
                                                 shape("2", "AUSTIN CLASS C", 2100, SHELF)])


def test_a_shelf_drawn_over_its_core_is_labelled_outside_the_core(tmp_path):
    path = austin(tmp_path)
    points = {p["properties"]["key"]: p for p in labels.airspace_points(path)}
    x, y = points["2"]["geometry"]["coordinates"]
    assert labels.inside(SHELF["coordinates"], x, y) and not labels.inside(CORE["coordinates"], x, y)
    assert labels.inside(CORE["coordinates"], *points["1"]["geometry"]["coordinates"])
    assert points["2"]["properties"]["room"] > 3 and points["2"]["properties"]["lower"] == 2100
    assert (points["2"]["id"], points["2"]["properties"]["kind"]) == (2, "airspace")
    assert points["2"]["tippecanoe"] == {"minzoom": 7}
    assert labels.violations(list(points.values()), path, same_name=True) == []


def test_the_check_refuses_a_shelf_label_inside_the_core(tmp_path):
    path = austin(tmp_path)
    bad = lines(tmp_path / "airspace_pt.geojson", [label("1", "AUSTIN CLASS C", 0, -97.7, 30.2),
                                                   label("2", "AUSTIN CLASS C", 2100, -97.7, 30.2)])
    with pytest.raises(BadPack, match="label is inside AUSTIN CLASS C"):
        labels.check(bad, path, [], same_name=True)


def test_the_check_refuses_a_label_outside_its_own_shape(tmp_path):
    path = austin(tmp_path)
    bad = lines(tmp_path / "airspace_pt.geojson", [label("1", "AUSTIN CLASS C", 0, -97.5, 30.45)])
    with pytest.raises(BadPack, match="outside its own shape"):
        labels.check(bad, path, [], same_name=True)


def test_the_check_refuses_a_label_whose_shape_is_missing(tmp_path):
    path = austin(tmp_path)
    bad = lines(tmp_path / "airspace_pt.geojson", [label("9", "LOST CLASS D", 0, -97.7, 30.2)])
    with pytest.raises(BadPack, match="has no shape"):
        labels.check(bad, path, [], same_name=True)


def test_another_airspace_with_a_lower_floor_is_not_a_lower_sector(tmp_path):
    path = lines(tmp_path / "airspace.geojson", [shape("1", "GEORGETOWN CLASS D", 0, CORE),
                                                 shape("2", "AUSTIN CLASS C", 2100, SHELF)])
    inside_the_d = [label("2", "AUSTIN CLASS C", 2100, -97.7, 30.2)]
    assert labels.violations(inside_the_d, path, same_name=True) == []


def test_a_label_keeps_clear_of_an_airport_symbol_and_its_room_says_how_far(tmp_path):
    path = lines(tmp_path / "airspace.geojson", [shape("1", "GEORGETOWN CLASS D", 0, CORE)])
    field = [(-97.7, 30.2)]
    (point,) = labels.airspace_points(path, field)
    x, y = point["geometry"]["coordinates"]
    away = math.hypot((x + 97.7) * math.cos(math.radians(30.2)), y - 30.2) * 60
    assert away >= point["properties"]["room"] > 2
    labels.check(lines(tmp_path / "ok.geojson", [point]), path, field, same_name=True)
    point["properties"]["room"] = 9.0
    with pytest.raises(BadPack, match="airport symbol"):
        labels.check(lines(tmp_path / "bad.geojson", [point]), path, field, same_name=True)


def test_stacked_areas_on_one_footprint_share_a_label_with_the_lowest_floor_and_highest_ceiling(tmp_path):
    ground = square(-98.0, 31.0, 0.5)
    path = lines(tmp_path / "sua.geojson", [
        area("11", "R-6302B", 10000, 300, ground, upper_uom="FL", upper_code="STD"),
        area("10", "R-6302A", 0, 10000, ground, lower_code="SFC")])
    (point,) = labels.sua_points(path)
    p = point["properties"]
    assert (p["key"], p["keys"], p["n"], point["id"]) == ("10", "10,11", 2, 10)
    assert (p["name"], p["names"]) == ("R-6302", "R-6302A, R-6302B")
    assert (p["lower"], p["lower_code"]) == (0, "SFC")
    assert (p["upper"], p["upper_uom"], p["upper_code"]) == (300, "FL", "STD")
    assert "hours" not in p and p["room"] > 5
    assert labels.violations([point], path, same_name=False) == []


def test_an_unlimited_ceiling_wins_and_prints_no_number(tmp_path):
    ground = square(-98.0, 31.0, 0.5)
    top = area("11", "W-1B", 5000, None, ground, upper_uom=None, upper_code="UNLTD")
    path = lines(tmp_path / "sua.geojson", [area("10", "W-1A", 0, 5000, ground), top])
    (point,) = labels.sua_points(path)
    assert "upper" not in point["properties"] and point["properties"]["upper_code"] == "UNLTD"


def test_names_that_differ_by_more_than_a_suffix_are_all_printed(tmp_path):
    ground = square(-98.0, 31.0, 0.5)
    path = lines(tmp_path / "sua.geojson", [area("10", "TEXON LOW MOA", 500, 6000, ground),
                                            area("11", "TEXON HIGH MOA", 6000, 180, ground, upper_uom="FL")])
    (point,) = labels.sua_points(path)
    assert point["properties"]["name"] == "TEXON LOW MOA / TEXON HIGH MOA"


def test_a_single_area_keeps_its_own_name_hours_and_limits(tmp_path):
    path = lines(tmp_path / "sua.geojson", [area("10", "R-2501E", 0, 10000, square(-98.0, 31.0, 0.5))])
    (point,) = labels.sua_points(path)
    p = point["properties"]
    assert (p["name"], p["hours"], p["upper"]) == ("R-2501E", "CONTINUOUS", 10000)
    assert not {"n", "names", "keys"} & set(p)


def test_a_high_area_is_never_labelled_over_a_lower_one_it_overlaps(tmp_path):
    low, high = square(-98.0, 31.0, 0.3), square(-98.1, 30.9, 0.8)
    path = lines(tmp_path / "sua.geojson", [area("10", "LOW MOA", 500, 8000, low),
                                            area("11", "HIGH MOA", 8000, 180, high, upper_uom="FL")])
    points = {p["properties"]["key"]: p for p in labels.sua_points(path)}
    assert set(points) == {"10", "11"}
    assert not labels.inside(low["coordinates"], *points["11"]["geometry"]["coordinates"])
    assert labels.inside(high["coordinates"], *points["11"]["geometry"]["coordinates"])


def test_an_area_wholly_inside_a_lower_one_gets_no_label_of_its_own(tmp_path):
    path = lines(tmp_path / "sua.geojson", [area("10", "LOW MOA", 500, 8000, square(-98.5, 30.5, 1.0)),
                                            area("11", "HIGH ATCAA", 8000, 180, square(-98.1, 30.9, 0.2))])
    assert [p["properties"]["key"] for p in labels.sua_points(path)] == ["10"]


def test_a_smaller_area_stacked_over_a_lower_one_raises_the_lower_label_ceiling(tmp_path):
    path = lines(tmp_path / "sua.geojson", [
        area("1", "R-2202B", 0, 10000, square(-98.0, 31.0, 1.0), lower_code="SFC"),
        area("2", "R-2202C", 10000, 310, square(-97.8, 31.2, 0.4), upper_uom="FL", upper_code="STD")])
    out = tmp_path / "sua_pt.geojson"
    assert labels.write(path, out, [], merge=True) == 1
    p = json.loads(out.read_text())["properties"]
    assert (p["key"], p["keys"], p["lower"]) == ("1", "1,2", 0)
    assert (p["upper"], p["upper_uom"], p["name"]) == (310, "FL", "R-2202")
    assert labels.unlabeled(out, path) == []


def test_an_upper_area_over_two_lower_areas_raises_both_labels(tmp_path):
    both = {"type": "Polygon", "coordinates": [[[-98.0, 31.0], [-97.0, 31.0], [-97.0, 31.5], [-98.0, 31.5],
                                                [-98.0, 31.0]]]}
    path = lines(tmp_path / "sua.geojson", [area("1", "R-1A", 0, 10000, square(-98.0, 31.0, 0.5)),
                                            area("2", "R-1B", 0, 10000, square(-97.5, 31.0, 0.5)),
                                            area("3", "R-1C", 10000, 310, both, upper_uom="FL")])
    points = {p["properties"]["key"]: p["properties"] for p in labels.sua_points(path)}
    assert set(points) == {"1", "2"}
    assert all((q["upper"], q["upper_uom"]) == (310, "FL") for q in points.values())
    assert (points["1"]["keys"], points["2"]["keys"]) == ("1,3", "2,3")


@pytest.mark.parametrize("first, second", [("R-4002", "R-4006"), ("R-2917", "R-2914A"), ("R-5201", "R-5202A")])
def test_two_designators_are_never_shortened_to_one_the_faa_did_not_publish(tmp_path, first, second):
    ground = square(-98.0, 31.0, 0.5)
    path = lines(tmp_path / "sua.geojson", [area("10", first, 0, 5000, ground), area("11", second, 5000, 9000, ground)])
    (point,) = labels.sua_points(path)
    assert point["properties"]["name"] == f"{first} / {second}"


def test_two_areas_with_one_name_print_it_once(tmp_path):
    ground = square(-98.0, 31.0, 0.5)
    path = lines(tmp_path / "sua.geojson", [area("10", "W-72A", 0, 2000, ground),
                                            area("11", "W-72A", 60000, 99000, ground)])
    (point,) = labels.sua_points(path)
    p = point["properties"]
    assert (p["name"], p["names"], p["n"], p["types"]) == ("W-72A", "W-72A", 2, "R")


def test_a_restricted_area_stacked_on_a_moa_is_labelled_as_restricted(tmp_path):
    ground = square(-98.0, 31.0, 0.5)
    path = lines(tmp_path / "sua.geojson", [area("10", "GRAND BAY MOA", 500, 8000, ground, type="MOA"),
                                            area("11", "R-3008C", 8000, 10000, ground)])
    (point,) = labels.sua_points(path)
    p = point["properties"]
    assert (p["type"], p["types"], p["lower"], p["upper"]) == ("R", "MOA,R", 500, 10000)
    assert p["name"] == "GRAND BAY MOA / R-3008C"


def test_of_two_areas_with_one_floor_the_taller_gives_the_label_its_key(tmp_path):
    ground = square(-98.0, 31.0, 0.5)
    path = lines(tmp_path / "sua.geojson", [area("10", "R-2103A", 0, 3000, ground),
                                            area("11", "R-2103B", 0, 9000, ground)])
    (point,) = labels.sua_points(path)
    assert (point["properties"]["key"], point["properties"]["name"]) == ("11", "R-2103")


def test_an_area_with_no_limits_gets_no_label_and_joins_no_other(tmp_path):
    ground = square(-98.0, 31.0, 0.5)
    path = lines(tmp_path / "sua.geojson", [area("10", "SELLS 1 MOA", 0, 0, ground, type="MOA"),
                                            area("11", "R-2304", 3000, 9000, ground)])
    out = tmp_path / "sua_pt.geojson"
    assert labels.write(path, out, [], merge=True) == 1
    p = json.loads(out.read_text())["properties"]
    assert (p["key"], p["name"], p["type"], p["lower"]) == ("11", "R-2304", "R", 3000) and "n" not in p
    assert [q["name"] for q in labels.unlabeled(out, path)] == ["SELLS 1 MOA"]


def test_a_slab_wholly_above_a_lower_sector_of_its_airspace_gets_no_label(tmp_path):
    path = lines(tmp_path / "airspace.geojson", [shape("1", "SAN DIEGO CLASS B", 0, SHELF, upper=3300),
                                                 shape("2", "SAN DIEGO CLASS B", 4700, CORE, upper=10000)])
    out = tmp_path / "airspace_pt.geojson"
    assert labels.write(path, out, [], merge=False) == 1
    assert [p["key"] for p in labels.unlabeled(out, path)] == ["2"]


def test_a_shape_with_no_room_for_a_label_gets_none():
    sliver = square(-98.0, 31.0, 0.002)["coordinates"]
    assert labels.place(sliver) is None


def test_a_shape_with_few_corners_and_one_crowded_edge_is_searched_on_its_true_outline(tmp_path):
    # 299 points along the south edge, then three corners: a square with a deep notch cut from the north.
    south = [[-98.0 + 0.3 * i / 299, 31.0] for i in range(300)]
    ring = south + [[-97.7, 31.3], [-97.85, 31.02], [-98.0, 31.3], [-98.0, 31.0]]
    notched = {"type": "Polygon", "coordinates": [ring]}
    path = lines(tmp_path / "sua.geojson", [area("10", "A-632A", 6000, 180, notched, upper_uom="FL", type="A")])
    out = tmp_path / "sua_pt.geojson"
    assert labels.write(path, out, [], merge=True) == 1
    point = json.loads(out.read_text())
    x, y = point["geometry"]["coordinates"]
    assert labels.inside([ring], x, y)
    k = math.cos(math.radians(31.15))
    assert point["properties"]["room"] <= labels._edge([ring], x, y, k) * 60 + 0.05


def test_a_label_in_a_ring_centred_on_its_airport_sits_clear_of_the_airport_text(tmp_path):
    path = lines(tmp_path / "airspace.geojson", [shape("1", "GEORGETOWN CLASS D", 0, square(-97.77, 30.13, 0.14))])
    (point,) = labels.airspace_points(path, [(-97.7, 30.2)])
    assert point["geometry"]["coordinates"][1] > 30.2


def test_the_check_refuses_a_label_under_an_airport_ident(tmp_path):
    path = lines(tmp_path / "airspace.geojson", [shape("1", "GEORGETOWN CLASS D", 0, CORE)])
    bad = lines(tmp_path / "airspace_pt.geojson", [label("1", "GEORGETOWN CLASS D", 0, -97.7, 30.18)])
    with pytest.raises(BadPack, match="airport"):
        labels.check(bad, path, [(-97.7, 30.2)], same_name=True)


def test_write_drops_nothing_good_and_leaves_a_file_that_passes_the_check(tmp_path):
    path = austin(tmp_path)
    out = tmp_path / "airspace_pt.geojson"
    assert labels.write(path, out, [], merge=False) == 2
    labels.check(out, path, [], same_name=True)


def test_the_austin_shelf_label_is_outside_the_surface_core_in_a_real_build(tmp_path):
    if not all(shutil.which(tool) for tool in TOOLS):
        pytest.skip("needs tippecanoe, ogr2ogr and pmtiles")
    database(tmp_path).close()
    out, layers = tmp_path / "nav.pmtiles", tmp_path / "layers"
    counts = navtiles.build(tmp_path / "nav.sqlite", FIXTURES / "shp" / "Class_Airspace.shp",
                            FIXTURES / "sua.geojson", out, layers, "2026-10-01")
    assert (counts["airspace_pt"], counts["sua_pt"]) == (2, 3)

    def read(name):
        return {f["properties"]["lower"]: f for f in map(json.loads, (layers / name).read_text().splitlines())}

    shapes, points = read("airspace.geojson"), read("airspace_pt.geojson")
    x, y = points[2100]["geometry"]["coordinates"]
    assert labels.inside(labels._rings(shapes[2100]["geometry"]), x, y)
    assert not labels.inside(labels._rings(shapes[0]["geometry"]), x, y)
    assert points[2100]["properties"]["class"] == "C" and points[2100]["properties"]["room"] > 0.5
    stored = {layer["id"] for layer in navtiles._show(out, "--metadata")["vector_layers"]}
    assert {"airspace_pt", "sua_pt"} <= stored
