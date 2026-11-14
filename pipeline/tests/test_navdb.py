import csv
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import pytest

from navpipe import navdb

FIXTURES = Path(__file__).parent / "fixtures" / "nav"
BUILT_AT = datetime(2026, 10, 13, 4, 0, tzinfo=timezone.utc)
FREQUENCIES = ("SELECT f.use, f.kind, f.freq FROM frequencies f "
               "JOIN airports a ON a.id = f.airport_id WHERE a.ident = ?")
NATIONAL = {"airports": 19427, "runways": 23191, "runway_ends": 39829, "frequencies": 36447,
            "frequencies_tower": 1537, "frequencies_ground": 1089, "remarks": 88928, "navaids": 1617,
            "fixes": 70129, "airway_points": 19541, "obstacles": 200838,
            "activity_areas": 863, "surface": 219641}


@pytest.fixture(scope="module")
def built(tmp_path_factory):
    path = tmp_path_factory.mktemp("nav") / "nav.sqlite"
    counts = navdb.build(FIXTURES / "csv", path, "2026-10-01", BUILT_AT, "2026-09-28T13:54:26Z")
    db = sqlite3.connect(path)
    yield db, counts
    db.close()


def one(db, sql, *args):
    return db.execute(sql, args).fetchone()


def test_meta_records_the_cycle_its_dates_the_build_time_and_the_sua_date(built):
    db, _ = built
    assert dict(db.execute("SELECT key, value FROM meta")) == {
        "schema_version": "1",
        "cycle": "2026-10-01",
        "effective": "2026-10-01T09:01:00Z",
        "expires": "2026-10-29T09:01:00Z",
        "built_at": "2026-10-13T04:00:00Z",
        "sua_snapshot": "2026-09-28T13:54:26Z",
    }


def test_schema_file_and_builder_agree_on_the_version():
    first_line = navdb.SCHEMA.read_text().splitlines()[0]
    assert f"schema version {navdb.SCHEMA_VERSION}." in first_line


def test_file_is_left_in_the_default_journal_mode(built):
    db, _ = built
    assert one(db, "PRAGMA journal_mode")[0] == "delete"


def test_airport_row_matches_the_faa_file(built):
    db, counts = built
    assert counts["airports"] == 5
    row = one(db, "SELECT site_no, icao, name, city, state, type, use, lat, lon, elev, magvar, tpa, twr, "
                  "fuel, artcc, status FROM airports WHERE ident = 'AUS'")
    assert row == ("23369.", "KAUS", "AUSTIN-BERGSTROM INTL", "AUSTIN", "TX", "A", "PU", 30.19452722,
                   -97.66987611, 541.5, "4E", None, "ATCT-TRACON", "100LL,A", "ZHU", "O")


def test_only_airports_the_faa_gives_an_icao_code_have_one(built):
    db, _ = built
    assert dict(db.execute("SELECT ident, icao FROM airports")) == {
        "AUS": "KAUS", "ANC": "PANC", "T82": None, "68TX": None, "TS01": None}


def test_search_and_nearest_indexes_are_filled(built):
    db, _ = built
    assert one(db, "SELECT count(*) FROM airports_rtree")[0] == 5
    found = one(db, "SELECT ident FROM airports WHERE id IN "
                    "(SELECT rowid FROM airports_fts WHERE airports_fts MATCH 'bergstrom*')")
    assert found == ("AUS",)
    nearest = one(db, "SELECT a.ident FROM airports_rtree r JOIN airports a ON a.id = r.id "
                      "WHERE r.min_lat > 29.4 AND r.max_lat < 31.0 AND r.min_lon > -98.5 AND r.max_lon < -96.9 "
                      "ORDER BY (a.lat - 30.19452722) * (a.lat - 30.19452722) "
                      "+ (a.lon + 97.66987611) * (a.lon + 97.66987611)")
    assert nearest == ("AUS",)


def test_runways_and_ends_join_to_their_airport(built):
    db, _ = built
    runways = db.execute("SELECT r.rwy_id, r.length, r.width, r.surface, r.cond, r.lights FROM runways r "
                         "JOIN airports a ON a.id = r.airport_id WHERE a.ident = 'T82'").fetchall()
    assert runways == [("14/32", 5002, 75, "ASPH", "GOOD", "MED")]
    end = one(db, "SELECT e.true_hdg, e.rh_pattern, e.lat, e.lon, e.elev, e.displaced_len, e.vgsi, e.als, "
                  "e.tora, e.lda FROM runway_ends e JOIN airports a ON a.id = e.airport_id "
                  "WHERE a.ident = 'AUS' AND e.end_id = '18L'")
    assert end == (179, "N", 30.20383005, -97.65789105, 491.6, None, "P4L", "ALSF2", 9000, 9000)


def test_frequencies_keep_the_faa_wording_and_get_a_kind(built):
    db, counts = built
    for name in ("tower", "ground"):
        stored = one(db, "SELECT count(*) FROM frequencies WHERE kind = ?", name)[0]
        assert counts[f"frequencies_{name}"] == stored > 0
    aus = set(db.execute(FREQUENCIES, ("AUS",)))
    for expected in [("LCL/P", "tower", "121.0"), ("LCL/S", "tower", "118.225"), ("GND/P", "ground", "121.9"),
                     ("CD/P", "clearance", "125.5"), ("D-ATIS", "atis", "124.4"), ("UNICOM", "unicom", "122.95"),
                     ("APCH/P DEP/P IC", "approach", "127.225"), ("RAMP CTL", "other", "126.225"),
                     ("CLASS C", "other", "119.0")]:
        assert expected in aus
    t82 = set(db.execute(FREQUENCIES, ("T82",)))
    assert t82 >= {("CTAF", "ctaf", "122.7"), ("UNICOM", "unicom", "122.7"),
                   ("T82 AWOS-3", "weather", "120.0"), ("FREDERICKSBURG RCAG", "other", "134.2")}


@pytest.mark.parametrize("use, expected", [
    ("CTAF", "ctaf"),
    ("UNICOM", "unicom"),
    ("LCL/P", "tower"),
    ("LCL/P IC", "tower"),
    ("GND/P", "ground"),
    ("GND METERING", "other"),
    ("GNDLF STAR", "other"),
    ("CD/P", "clearance"),
    ("CD PRE TAXI CLNC", "clearance"),
    ("CD PRE DEP CLNC", "clearance"),
    ("ATIS", "atis"),
    ("D-ATIS", "atis"),
    ("APCH/P DEP/P", "approach"),
    ("DEP/P", "departure"),
    ("EMERG", "emergency"),
    ("EDC AWOS-3", "weather"),
    ("CDA AWOS-3", "weather"),
    ("CDW ASOS", "weather"),
    ("CLASS C", "other"),
    ("AUSTIN DP", "other"),
    ("CDB FSS", "other"),
    ("CD NDB", "other"),
    ("", "other"),
])
def test_kind(use, expected):
    assert navdb.kind(use) == expected


def test_navaids_and_fixes_match_the_faa_files(built):
    db, counts = built
    assert counts["navaids"] == 7 and counts["fixes"] == 3
    navaid = one(db, "SELECT type, name, city, state, lat, lon, elev, freq, chan, magvar, status "
                     "FROM navaids WHERE ident = 'CWK'")
    assert navaid == ("VORTAC", "CENTEX", "AUSTIN", "TX", 30.37855, -97.52984722, 593.0, "112.8", "75X",
                      "6E", "OPERATIONAL RESTRICTED")
    fix = one(db, "SELECT state, lat, lon, use, charts FROM fixes WHERE ident = 'BITER'")
    assert fix == ("TX", 30.11251388, -97.07993055, "WP", "CONTROLLER LOW,ENROUTE LOW,STAR")


def test_airway_points_are_placed_by_identifier_and_type(built):
    db, _ = built
    rows = db.execute("SELECT seq, point, point_type, lat, lon, gap, mea FROM airway_points "
                      "WHERE airway = 'J21' AND location = 'C' ORDER BY seq").fetchall()
    assert [row[0] for row in rows] == [10, 20, 30, 40, 50, 60, 70, 80]
    # SAT is both a VORTAC and a test facility a few miles away; the airway uses the VORTAC.
    assert rows[3] == (40, "SAT", "VORTAC", 29.64403, -98.4613158, 0, 18000)
    assert rows[1][1:5] == ("TTXOX", "CN", 26.93363888, -99.33363888)


def test_a_point_that_cannot_be_placed_has_no_position(built):
    db, counts = built
    unplaced = db.execute("SELECT airway, point FROM airway_points WHERE lat IS NULL "
                          "ORDER BY airway, seq").fetchall()
    assert unplaced == [("J21", "U.S. MEXICAN BORDER-2"), ("J21", "ACT"), ("T797", "U.S. CANADIAN BORDER-1")]
    assert counts["airway_points_unplaced"] == 3


def test_a_national_build_that_is_short_anywhere_is_refused():
    navdb.check_national(NATIONAL)
    for change in ({"airports": 5}, {"airports": 18999}, {"airports": 20501}, {"frequencies": 0},
                   {"runways": 0}, {"frequencies_ground": 3}):
        with pytest.raises(ValueError):
            navdb.check_national({**NATIONAL, **change})


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


def test_an_identifier_shared_by_two_navaids_of_one_type_is_not_placed(tmp_path):
    def twin(rows):
        cwk = next(r for r in rows if r["NAV_ID"] == "CWK")
        return rows + [{**cwk, "LAT_DECIMAL": "45.0", "LONG_DECIMAL": "-120.0"}]

    db = rebuilt(tmp_path, "NAV_BASE", twin)
    assert db.execute("SELECT lat, lon FROM airway_points WHERE airway = 'J21' AND point = 'CWK'").fetchone() == (
        None, None)
    db.close()


def test_a_navaid_frequency_row_is_not_attached_to_an_airport(tmp_path):
    def add(rows):
        aus = next(r for r in rows if r["SERVICED_FACILITY"] == "AUS")
        return rows + [{**aus, "FACILITY_TYPE": "NAVAID", "FREQ_USE": "VORTAC", "FREQ": "117.1"}]

    db = rebuilt(tmp_path, "FRQ", add)
    assert db.execute("SELECT count(*) FROM frequencies WHERE freq = '117.1'").fetchone()[0] == 0
    db.close()
