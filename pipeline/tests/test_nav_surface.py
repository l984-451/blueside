import json
from datetime import datetime, timedelta

import pytest

from navhelp import database
from navpipe import navtiles, surface

AUS = (-97.66987611, 30.19452722)
T82 = (-98.90918666, 30.24324305)


def box(lon, lat, half):
    return [[lon - half, lat - half], [lon + half, lat - half], [lon + half, lat + half], [lon - half, lat + half],
            [lon - half, lat - half]]


def test_osm_features_become_compact_rows():
    taxiway = {"properties": {"aeroway": "taxiway", "name": "Taxiway B2"},
               "geometry": {"type": "LineString", "coordinates": [[0, 0], [1, 1]]}}
    assert surface.classify(taxiway)[0]["n"] == "B2"
    hangar = {"properties": {"building": "hangar", "name": "Signature Flight Support"},
              "geometry": {"type": "MultiPolygon", "coordinates": [[box(1, 1, 0.5)]]}}
    assert [row["k"] for row in surface.classify(hangar)] == ["building", "fbo"]
    assert surface.classify(hangar)[1]["g"] == [[1, 1]]
    # A shop named like an FBO off the airport's business is not one.
    shop = {"properties": {"shop": "yes", "name": "Jet Center"}, "geometry": {"type": "Point", "coordinates": [0, 0]}}
    assert surface.classify(shop) == []
    for tags in ({"aeroway": "helipad", "name": "Hurst Aviation Heliport"},
                 {"aeroway": "terminal", "name": "Federal Aviation Administration"}):
        assert surface.classify({"properties": tags, "geometry": {"type": "Point", "coordinates": [0, 0]}}) == []
    road = {"properties": {"highway": "service"}, "geometry": {"type": "LineString", "coordinates": [[0, 0], [1, 1]]}}
    assert surface.classify(road) == []


def test_each_feature_goes_to_its_field_in_feet_and_far_ones_are_dropped(tmp_path):
    rows = [{"k": "field", "faa": "AUS", "g": box(*AUS, 0.03)},
            # A field outline with no codes is matched by the airport point inside it.
            {"k": "field", "g": box(*T82, 0.01)},
            {"k": "taxiway", "n": "A", "g": [[AUS[0] - 0.01, AUS[1]], [AUS[0] + 0.01, AUS[1]]]},
            {"k": "building", "g": box(AUS[0] + 0.005, AUS[1], 0.0003)},
            {"k": "fbo", "n": "Signature", "g": [[AUS[0] + 0.005, AUS[1]]]},
            # Too small to draw.
            {"k": "building", "g": box(AUS[0] - 0.005, AUS[1], 0.00002)},
            {"k": "apron", "g": box(*T82, 0.001)},
            # Off every outline but near Gillespie County.
            {"k": "hold", "g": [[T82[0], T82[1] + 0.012]]},
            # Nowhere near a field.
            {"k": "taxiway", "g": [[-100, 40], [-100.01, 40]]}]
    path = tmp_path / "surface.jsonl"
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))
    db = database(tmp_path / "db", None, None, path)
    found = db.execute("SELECT a.ident, s.kind, s.name, s.points FROM surface s JOIN airports a ON a.id = s.airport_id "
                       "ORDER BY s.rowid").fetchall()
    assert [row[:3] for row in found] == [("AUS", "taxiway", "A"), ("AUS", "building", None),
                                          ("AUS", "fbo", "Signature"), ("T82", "apron", None), ("T82", "hold", None)]
    # 0.01 degrees of longitude at 30 N is about 3,150 ft; a straight line keeps only its ends.
    (west, _), (east, _) = surface.unpack(found[0][3])
    assert abs(east - 3150) < 20 and west == -east
    # A ring is stored open.
    assert len(surface.unpack(found[1][3])) == 4

    areas, paths, points = navtiles.surface_features(db)
    assert [f["properties"]["k"] for f in areas] == ["building", "apron"]
    assert areas[0]["geometry"]["coordinates"][0][0] == areas[0]["geometry"]["coordinates"][0][-1]
    assert [f["properties"].get("ref") for f in paths] == ["A"]
    assert abs(paths[0]["geometry"]["coordinates"][1][0] - (AUS[0] + 0.01)) < 1e-5
    assert points[0]["properties"] == {"name": "Signature"}


def test_simplify_keeps_corners_and_drops_wobble():
    line = [(0, 0), (100, 1), (200, 0), (200, 200)]
    assert surface._simplify(line, 3) == [(0, 0), (200, 0), (200, 200)]
    assert surface.pack([(40000, 0)]) is None


def test_a_failed_monthly_refresh_keeps_the_older_rows(tmp_path, monkeypatch):
    old = tmp_path / "surface.jsonl"
    old.write_text("{}\n")
    monkeypatch.setattr(surface, "run", lambda cmd: (_ for _ in ()).throw(OSError("offline")))
    later = datetime.fromtimestamp(old.stat().st_mtime) + timedelta(days=40)
    assert surface.fetch(tmp_path, later) == old
    old.unlink()
    with pytest.raises(OSError):
        surface.fetch(tmp_path, later)
