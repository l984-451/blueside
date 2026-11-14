import io
import shutil
import zipfile

import pytest

from navhelp import FIXTURES, TOOLS, database
from navpipe import nasr, navdb, navtiles

NATIONAL = {"airports": 19427, "runways": 23191, "runway_ends": 39829, "frequencies": 36447,
            "frequencies_tower": 1537, "frequencies_ground": 1089, "remarks": 88928, "navaids": 1617,
            "fixes": 70129, "airway_points": 19541, "obstacles": 200838, "activity_areas": 863, "surface": 219641}


@pytest.fixture()
def db(tmp_path):
    connection = database(tmp_path, None, FIXTURES / "DOF.CSV")
    yield connection
    connection.close()


def test_the_obstacle_file_is_downloaded_and_unpacked(tmp_path, monkeypatch):
    body = io.BytesIO()
    with zipfile.ZipFile(body, "w") as archive:
        archive.writestr("DOF.CSV", "OAS,AGL\r\n")
    asked = []
    monkeypatch.setattr(nasr, "_fetch", lambda url, attempts=3: asked.append(url) or body.getvalue())
    path = nasr.fetch_obstacles(tmp_path)
    assert path.read_bytes() == b"OAS,AGL\r\n"
    assert asked == ["https://aeronav.faa.gov/Obst_Data/DAILY_DOF_CSV.ZIP"]


def test_only_200_ft_and_taller_are_kept_with_both_heights_and_lighting(db):
    rows = db.execute("SELECT oas, type, agl, msl, lighting, quantity, verified FROM obstacles "
                      "ORDER BY oas").fetchall()
    assert len(rows) == 11 and "48-000004" not in {row[0] for row in rows}
    assert rows[0] == ("48-000001", "TOWER", 1297, 2049, "D", 1, "O")
    assert rows[3] == ("48-000005", "STACK", 310, 860, "R", 3, "O")


def test_an_obstacle_with_no_city_and_no_type_is_kept(db):
    row = db.execute("SELECT type, agl, msl, lighting, verified FROM obstacles WHERE oas = '48-000003'").fetchone()
    assert row == (None, 250, 800, "N", "U")


def test_a_build_without_the_file_leaves_the_table_empty(tmp_path):
    db = database(tmp_path)
    assert db.execute("SELECT count(*) FROM obstacles").fetchone()[0] == 0
    db.close()


def test_a_national_build_with_too_few_obstacles_is_refused():
    navdb.check_national(NATIONAL)
    with pytest.raises(ValueError, match="obstacles"):
        navdb.check_national({**NATIONAL, "obstacles": 0})


def obstacles(db):
    ids = dict(db.execute("SELECT oas, id FROM obstacles"))
    features = navtiles.obstacle_features(db)
    single = {f["properties"]["key"]: f for f in features if f["properties"]["kind"] == "obstacle"}
    groups = [f for f in features if f["properties"]["kind"] == "obstacle_group"]
    return {oas: single[str(number)] for oas, number in ids.items()}, groups


def test_tile_features_carry_heights_lighting_and_first_zoom(db):
    single, _ = obstacles(db)
    tall = single["48-000001"]
    assert {"kind": "obstacle", "type": "TOWER", "agl": 1297, "msl": 2049, "lighting": "D"}.items() <= tall[
        "properties"].items()
    assert tall["tippecanoe"] == {"minzoom": 7} and tall["properties"]["n"] == 1
    assert tall["id"] == int(tall["properties"]["key"])
    assert tall["geometry"]["coordinates"] == [-97.8, 30.325]
    assert single["48-000002"]["tippecanoe"] == {"minzoom": 9}
    plain = single["48-000003"]
    assert plain["tippecanoe"] == {"minzoom": 10} and "type" not in plain["properties"]
    assert (plain["properties"]["agl"], plain["properties"]["msl"], plain["properties"]["lighting"]) == (250, 800, "N")
    assert single["48-000005"]["properties"]["n"] == 3


def test_a_wind_farm_is_one_group_mark_and_its_turbines_wait_for_zoom_10(db):
    single, groups = obstacles(db)
    (group,) = groups
    assert {"type": "WINDMILL", "n": 6, "agl": 499, "msl": 1210, "lighting": "W"}.items() <= group[
        "properties"].items()
    assert group["geometry"]["coordinates"] == [-97.51, 30.45] and group["tippecanoe"] == {"minzoom": 8}
    assert group["id"] >= 10_000_000
    for oas in ("48-000101", "48-000102", "48-000103", "48-000104", "48-000105", "48-000106"):
        assert single[oas]["properties"]["farm"] == 1 and single[oas]["tippecanoe"] == {"minzoom": 10}
        assert single[oas]["properties"]["agl"] >= 410 and single[oas]["properties"]["msl"] >= 1110
    lone = single["48-000200"]
    assert "farm" not in lone["properties"] and lone["tippecanoe"] == {"minzoom": 10}


def test_the_archive_holds_each_obstacle_from_its_first_zoom_with_both_heights(db, tmp_path):
    if not all(shutil.which(tool) for tool in TOOLS):
        pytest.skip("needs tippecanoe, ogr2ogr and pmtiles")
    out = tmp_path / "nav.pmtiles"
    counts = navtiles.build(tmp_path / "nav.sqlite", FIXTURES / "shp" / "Class_Airspace.shp",
                            FIXTURES / "sua.geojson", out, tmp_path / "layers", "2026-10-01")
    assert counts["obstacles"] == 12

    def heights(zoom, lat, lon):
        found = navtiles.decode(out, zoom, *navtiles.tile_xy(lat, lon, zoom))
        return {(f["properties"]["kind"], f["properties"]["agl"], f["properties"]["msl"],
                 f["properties"].get("lighting"), f["properties"]["n"])
                for f in found if f["tippecanoe"]["layer"] == "obstacles"}

    assert ("obstacle", 250, 800, "N", 1) in heights(10, 30.21, -97.71)
    assert heights(9, 30.21, -97.71) >= {("obstacle", 650, 1190, "R", 1)}
    assert not any(agl < 500 and kind == "obstacle" for kind, agl, *_ in heights(9, 30.21, -97.71))
    assert heights(8, 30.45, -97.51) >= {("obstacle_group", 499, 1210, "W", 6)}
    assert ("obstacle", 1297, 2049, "D", 1) in heights(7, 30.325, -97.8)
    assert heights(6, 30.325, -97.8) == set()
