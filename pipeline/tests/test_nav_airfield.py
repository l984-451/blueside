import pytest

from navhelp import database
from navpipe import airfield, navtiles


@pytest.fixture()
def db(tmp_path):
    connection = database(tmp_path)
    yield connection
    connection.close()


def airports(db):
    return {f["properties"]["ident"]: f["properties"] for f in navtiles.airport_features(db)}


@pytest.mark.parametrize("faa, shown", [
    ("MC KINNEY FLD", "McKinney Fld"),
    ("MCKINNEY NTL", "McKinney Ntl"),
    ("DEKALB-PEACHTREE", "DeKalb-Peachtree"),
    ("DE KALB TAYLOR MUNI", "De Kalb Taylor Muni"),
    ("CHICAGO O'HARE INTL", "Chicago O'Hare Intl"),
    ("ST VINCENTS EAST", "St Vincents East"),
    ("ST MARY'S", "St Mary's"),
    ("AUSTIN-BERGSTROM INTL", "Austin-Bergstrom Intl"),
    ("MAXWELL AFB", "Maxwell AFB"),
    ("MCAS MIRAMAR", "MCAS Miramar"),
    ("ALBERTVILLE RGNL/THOMAS J BRUMLIK FLD", "Albertville Rgnl/Thomas J Brumlik Fld"),
    ("BAYLOR SCOTT & WHITE MED CTR - MCKINNEY", "Baylor Scott & White Med Ctr - McKinney"),
    ("3M RANCH", "3M Ranch"),
    ("", ""),
])
def test_display_name_is_mixed_case_by_rule(faa, shown):
    assert airfield.title(faa) == shown


def test_a_surveyed_heading_is_used_as_given():
    assert airfield.heading("18R", 179, (30.2136, -97.6794), (30.1799, -97.6785), "4E") == (179, "surveyed")


def test_without_a_survey_the_heading_comes_from_the_two_ends_and_says_so():
    found = airfield.heading("14", None, (30.24899233, -98.91352972), (30.23749383, -98.90484391), "6E")
    assert found == (147, "derived")


def test_with_no_positions_the_runway_number_and_the_variation_are_used():
    assert airfield.heading("14", None, None, None, "6E") == (146, "derived")
    assert airfield.heading("36", None, None, None, "10W") == (350, "derived")


def test_no_heading_is_made_up_when_the_number_or_the_variation_is_missing():
    assert airfield.heading("14", None, None, None, None) == (None, None)
    assert airfield.heading("NE", None, None, None, "6E") == (None, None)
    assert airfield.heading("H1", None, (30.0, -97.0), None, "6E") == (None, None)


def test_airport_heading_is_marked_surveyed_or_derived(tmp_path):
    def blank(rows):
        for r in rows:
            if r["ARPT_ID"] == "T82":
                r["TRUE_ALIGNMENT"] = ""
        return rows

    db = database(tmp_path, {"APT_RWY_END": blank})
    found = airports(db)
    db.close()
    assert (found["AUS"]["hdg"], found["AUS"]["hdg_src"]) == (179, "surveyed")
    assert (found["T82"]["hdg"], found["T82"]["hdg_src"]) == (147, "derived")
    assert "hdg" not in found["68TX"] and "hdg_src" not in found["68TX"]


def test_airport_point_carries_the_symbol_attributes(db):
    found = airports(db)
    aus, t82, pad = found["AUS"], found["T82"], found["68TX"]
    assert (aus["name"], aus["nm"], aus["city"]) == ("AUSTIN-BERGSTROM INTL", "Austin-Bergstrom Intl", "Austin")
    assert (aus["fuel"], aus["lit"], aus["big"], aus["ct"]) == (1, 1, 1, "121.0")
    assert not {"mil", "ctaf", "geom"} & set(aus)
    assert (t82["fuel"], t82["lit"], t82["ctaf"]) == (1, 1, "122.7")
    assert not {"ct", "big", "mil"} & set(t82)
    assert pad["lit"] == 1 and "fuel" not in pad
    assert (aus["ll"], aus["jet"]) == (1, 1) and not {"ll", "jet"} & set(pad)
    assert found["ANC"]["ct"] == "118.3"


def test_fuel_kinds_pick_out_100ll_and_every_jet_a_grade():
    assert navtiles.fuel_kinds("100LL,A1+") == {"ll": 1, "jet": 1}
    assert navtiles.fuel_kinds("100,MOGAS,UL94") == {"ll": None, "jet": None}
    assert navtiles.fuel_kinds("A++") == {"ll": None, "jet": 1}
    assert navtiles.fuel_kinds(None) == {"ll": None, "jet": None}


def test_two_primary_tower_frequencies_leave_the_property_out(tmp_path):
    def second(rows):
        local = next(r for r in rows if r["SERVICED_FACILITY"] == "AUS" and r["FREQ"] == "121.0")
        return rows + [{**local, "FREQ": "118.225"}]

    db = database(tmp_path, {"FRQ": second})
    found = airports(db)
    db.close()
    assert "ct" not in found["AUS"]


def test_a_military_field_is_flagged_and_its_owner_is_stored(tmp_path):
    def army(rows):
        for r in rows:
            if r["ARPT_ID"] == "T82":
                r["OWNERSHIP_TYPE_CODE"] = "MR"
        return rows

    db = database(tmp_path, {"APT_BASE": army})
    found = airports(db)
    stored = dict(db.execute("SELECT ident, ownership FROM airports"))
    db.close()
    assert found["T82"]["mil"] == 1 and "mil" not in found["AUS"]
    assert (stored["T82"], stored["AUS"]) == ("MR", "PU")


def test_the_shape_flag_is_set_only_for_fields_that_have_outlines(db):
    number = db.execute("SELECT id FROM airports WHERE ident = 'AUS'").fetchone()[0]
    found = {f["properties"]["ident"]: f["properties"] for f in navtiles.airport_features(db, {number})}
    assert found["AUS"]["geom"] == 1 and "geom" not in found["T82"]


def remark(rows, runway, text, column="RWY_ID", field="AUS"):
    base = next(r for r in rows if r["ARPT_ID"] == field)
    return {**base, "TAB_NAME": "RUNWAY", "REF_COL_NAME": column, "ELEMENT": runway, "REF_COL_SEQ_NO": "1",
            "REMARK": text}


def aus_with(tmp_path, *remarks):
    db = database(tmp_path, {"APT_RMK": lambda rows: rows + [remark(rows, *each) for each in remarks]})
    aus = airports(db)["AUS"]
    db.close()
    return aus


def test_a_closed_runway_never_raises_the_rank(tmp_path):
    aus = aus_with(tmp_path, ("18R/36L", "CLSD INDEFLY."), ("18L/36R", "RWY 18L/36R CLSD."))
    assert (aus["rank"], aus["rwy"], aus["hard"]) == (2, 0, 0) and not {"big", "hdg", "lit"} & set(aus)


def test_an_open_pad_does_not_stand_in_for_the_closed_runways_of_an_airport(tmp_path):
    def pad(rows):
        base = next(r for r in rows if r["ARPT_ID"] == "T82")
        return rows + [{**base, "RWY_ID": "H1", "RWY_LEN": "46", "RWY_WIDTH": "46", "SURFACE_TYPE_CODE": "CONC",
                        "RWY_LGT_CODE": "PERI"}]

    db = database(tmp_path, {"APT_RWY": pad, "APT_RMK": lambda rows: rows + [
        remark(rows, "14/32", "CLSD INDEFLY.", field="T82")]})
    found = airports(db)
    db.close()
    t82 = found["T82"]
    assert (t82["rank"], t82["rwy"], t82["hard"]) == (4, 0, 0) and not {"lit", "hdg", "big"} & set(t82)
    # A field that has pads only is still described by them.
    assert found["68TX"]["lit"] == 1 and found["68TX"]["rwy"] > 0


# Wordings taken from the FAA's remarks, with the runway id changed to the fixture's.
@pytest.mark.parametrize("text", [
    "CLSD.", "RWY CLSD.", "CLSD INDEFLY.", "RWY CLSD INDEFLY.", "RY CLSD INDEFLY.", "RY 18R/36L CLSD INDEFLY.",
    "CLSD INDEF.", "RWY 18R/36L CLSD INDEF.", "RWY 18R/36L CLSD PERM.", "RWY 18R/36L CLSD PERMLY.", "CLSD UFN.",
    "CLSD, NOT INSP.", "CLSD INDEFLY - PAVEMENT UNUSBL.", "RWY 18R/36L CLSD INDEFLY, UNUSBL.",
    "RWY 18R/36L CLSD INDEFLY DUE TO FLOOD DMG, CULVERTS WASHED OUT.",
    "ALL RWYS CLSD INDEFLY AND MKD WITH YELLOW X ADJ TO RWY ENDS.", "18R/36L CLSD INDEFLY.",
    "CLSD INDEFLY. 2 FT BUMP XG TWY.", "RWY 18R/36L CLSD INDEFLY; UNDER REPAIR.",
    "RWY CLSD DUE TO EDGES CONTAIN LOOSE ROCKS AND CRUMBLING.",
    # What follows the closure describes the runway and takes nothing back.
    "RWY CLSD DUE TO CRUMBLING. LRG CRACKS; VEGETATION GROWING THRU JOINTS; MARKINGS FADED.",
    "RWY 18R/36L CLSD INDEFLY. MARKED YELLOW X'S AT EACH END.", "CLSD INDEFLY. 60 FT TREES N & S OF CNTRLN.",
    "CLSD INDEFLY. MAINT NA. BIRDS MAY BE ON RWY.", "TURF RY CLSD INDEFLY.",
    # A closure after a sentence about the surface; open to taxiing is still closed to flight.
    "BLOCK CRACKING UP TO 3 IN WIDE CRACKS, RAVELING, AND WEATHERING.  RWY CLSD INDEFLY EXECEPT FOR TAXIING.",
    # Limits on use written well before the closure do not qualify it; the FAA diagram marks this runway closed.
    "RWY 04R/22L NOT AVBL FOR PART 121/PART 380 OPS WITH SKED PAX CARRYING OPS MORE THAN 9 PAX SEATS AND NON-SKED "
    "PAX CARRYING OPS MORE THAN 30 PAX SEATS. 90 DAY PPR FOR UNSKED ACR OPS GTR THAN 30 PAX SEATS - CALL AMGR. "
    "937-528-9891. CLSD INDEFLY.",
])
def test_every_wording_of_an_outright_closure_closes_the_runway(tmp_path, text):
    aus = aus_with(tmp_path, ("18R/36L", text))
    assert (aus["rank"], aus["rwy"]) == (1, 9000)


@pytest.mark.parametrize("text", [
    "CLSD WINTER MONTHS.", "CLSD WHEN ATCT CLSD.", "CLSD NIGHTS INDEFLY; ONLY VFR OPNS DURG DAY.", "RWY CLSD NGTS.",
    "CLSD TO HEL.", "CLSD INDEFLY TO JET ACFT.", "CLSD TO ACFT 8,500 LBS OR MORE.", "CLSD OVR 12500 LB - AMGR.",
    "CLSD SS-SR.", "CLSD SS-0700.", "RWY 18R/36L CLSD FM 2200-0600.", "WEST 1713 FT CLSD INDEFLY.",
    "NORTH 1000 FT OF RY CLSD INDEFLY.", "RWY TEMPORARILY CLSD & NOT BEING MNTND.", "HELIPAD TEMP CLSD.",
    "RWY LNDG ZONE CLSD.", "CLSD FOR VEHICULAR TRAFFIC.", "RWY 18R/36L CLSD EXCP PPR.",
    "CLSD, EXCP PPR.", "CLSD - SEE NOTAMS.", "RWY CLSD - WINTER.", "CLSD-NOV THRU APR.", "CLSD, USE RWY 18L/36R.",
    "CLSD INDEFLY - OPEN TO SKI ACFT.", "CLSD DUE TO SNOW.", "RWY 18R/36L CLSD AND MKD WITH X WHEN FLOODED.",
    "CLSD DUE TO CONSTRUCTION UNTIL 12/2026.",
    # The same exceptions written as a second sentence.
    "CLSD; EXCP PPR.", "CLSD. OPEN WITH PPR.", "CLSD INDEFLY; OPEN TO SKI ACFT.", "CLSD INDEFLY. EXC MIL OPS.",
    "CLSD; SS-SR.", "CLSD. NGTS ONLY.", "CLSD. WINTER MONTHS.", "RWY 18R/36L CLSD; 2200-0600.",
    "CLSD INDEFLY. SEE NOTAMS.", "CLSD UFN; UNLESS PPR FM AMGR.", "CLSD. NOV-APR.",
    "GRASS ON RWY. RWY CLSD. EXC PPR.", "RWY HAS A DITCH. 1ST 300 FT OF RWY 36L CLSD.",
    "PVT USE, CTC TWR. WHEN TWR CLSD USE CTAF.", "SOFT. RWY CLSD EXCEPT FOR TAXIING WHEN WET.",
    # The condition written as a sentence before the closure.
    "WINTER MONTHS. RWY CLSD.", "PPR ONLY. RWY CLSD.", "NOV-APR. RWY CLSD INDEFLY.",
])
def test_a_seasonal_night_partial_or_conditional_closure_is_not_a_closed_runway(tmp_path, text):
    aus = aus_with(tmp_path, ("18R/36L", text))
    assert (aus["rank"], aus["rwy"]) == (1, 12250)


def test_a_closure_filed_under_another_column_counts(tmp_path):
    assert aus_with(tmp_path, ("18R/36L", "RWY 18R/36L CLSD INDEFLY.", "RWY_LEN"))["rwy"] == 9000


def test_a_general_remark_closes_only_the_runway_it_names_outright(tmp_path):
    def close(rows):
        return rows + [remark(rows, "", "RWY 7L-25R CLSD PERM", "GENERAL_REMARK", "ANC"),
                       remark(rows, "", "RWY 18L/36R CLSD INDEFLY.", "GENERAL_REMARK"),
                       remark(rows, "", "RWY 18R/36L CLSD WHEN ATCT CLSD.", "GENERAL_REMARK"),
                       remark(rows, "", "RWY 9/27 CLSD PERMLY.", "GENERAL_REMARK"),
                       remark(rows, "", "TWY C SOUTH OF RWY 15/33 CLSD PERMLY.", "GENERAL_REMARK", "ANC"),
                       remark(rows, "H1", "HELIPAD CLSD."), remark(rows, "H2", "H2 CLSD INDEFLY.")]

    db = database(tmp_path, {"APT_RMK": close})
    idents = dict(db.execute("SELECT id, ident FROM airports"))
    closed = {(idents[number], runway) for number, runway in airfield.closed_runways(db)}
    db.close()
    assert closed == {("ANC", "07L/25R"), ("AUS", "18L/36R"), ("AUS", "H1"), ("AUS", "H2")}


def test_a_remark_naming_another_runway_or_one_end_closes_nothing(tmp_path):
    def close(rows):
        return rows + [remark(rows, "18R/36L", "RWY 18L/36R CLSD INDEFLY."), remark(rows, "18L/36R", "RWY 36R CLSD."),
                       remark(rows, "07R/25L", "RWY 7L/25R CLSD INDEFLY.", field="ANC"),
                       remark(rows, "15/33", "RWY 15-33 CLSD INDEFLY.", field="ANC")]

    db = database(tmp_path, {"APT_RMK": close})
    idents = dict(db.execute("SELECT id, ident FROM airports"))
    closed = {(idents[number], runway) for number, runway in airfield.closed_runways(db)}
    db.close()
    assert closed == {("ANC", "15/33")}


def test_a_remark_naming_its_own_runway_without_the_leading_zero_closes_it(tmp_path):
    db = database(tmp_path, {"APT_RMK": lambda rows: rows + [
        remark(rows, "07L/25R", "RWY 7L/25R CLSD INDEFLY.", field="ANC")]})
    closed = {runway for _, runway in airfield.closed_runways(db)}
    db.close()
    assert closed == {"07L/25R"}


def runways(tmp_path, change):
    db = database(tmp_path, {"APT_RWY": change})
    found = airports(db)
    db.close()
    return found


def test_a_lighted_pad_does_not_make_an_unlit_airport_lighted(tmp_path):
    def dark(rows):
        for r in rows:
            if r["ARPT_ID"] == "AUS":
                r["RWY_LGT_CODE"] = "PERI" if r["RWY_ID"].startswith("H") else ""
        return rows

    found = runways(tmp_path, dark)
    assert "lit" not in found["AUS"] and found["68TX"]["lit"] == 1


def test_a_paved_pad_does_not_make_a_turf_airport_paved(tmp_path):
    def turf(rows):
        for r in rows:
            if r["ARPT_ID"] == "AUS" and "/" in r["RWY_ID"]:
                r["SURFACE_TYPE_CODE"] = "TURF"
        return rows

    aus = runways(tmp_path, turf)["AUS"]
    assert (aus["hard"], aus["rwy"]) == (0, 12250) and "big" not in aus


def test_a_long_unpaved_runway_beside_a_short_paved_one_is_not_drawn_to_scale(tmp_path):
    def gravel(rows):
        paved = next(r for r in rows if r["ARPT_ID"] == "T82")
        paved["RWY_LEN"] = "3000"
        return rows + [{**paved, "RWY_ID": "09/27", "RWY_LEN": "9600", "SURFACE_TYPE_CODE": "GRVL"}]

    db = database(tmp_path, {"APT_RWY": gravel})
    t82 = airports(db)["T82"]
    number = db.execute("SELECT id FROM airports WHERE ident = 'T82'").fetchone()[0]
    paved_len = airfield.summary(db)[number]["paved_len"]
    db.close()
    assert (t82["rwy"], t82["hard"], paved_len) == (9600, 1, 3000) and "big" not in t82


def lane_at(field, length, lights=""):
    def add(rows):
        base = next(r for r in rows if r["ARPT_ID"] == field)
        return rows + [{**base, "RWY_ID": "03W/21W", "RWY_LEN": length, "SURFACE_TYPE_CODE": "WATER",
                        "RWY_LGT_CODE": lights}]

    return add


def lane_ends(rows):
    base = next(r for r in rows if r["ARPT_ID"] == "T82")
    blank = {**base, "RWY_ID": "03W/21W", "TRUE_ALIGNMENT": "", "LAT_DECIMAL": "", "LONG_DECIMAL": ""}
    return rows + [{**blank, "RWY_END_ID": "03W"}, {**blank, "RWY_END_ID": "21W"}]


def test_a_longer_water_lane_does_not_describe_a_field_that_has_a_land_runway(tmp_path):
    def tower(rows):
        for r in rows:
            if r["ARPT_ID"] == "T82":
                r["TWR_TYPE_CODE"] = "ATCT"
        return rows

    def unlit(rows):
        for r in rows:
            if r["ARPT_ID"] == "T82":
                r["RWY_LGT_CODE"] = ""
        return lane_at("T82", "15000", "MED")(rows)

    db = database(tmp_path, {"APT_BASE": tower, "APT_RWY": unlit, "APT_RWY_END": lane_ends})
    t82 = airports(db)["T82"]
    db.close()
    # The paved 14/32 is 5,002 ft, surveyed at 147. The lane's number would give 36.
    assert (t82["rwy"], t82["hard"], t82["hdg"], t82["hdg_src"]) == (5002, 1, 147, "surveyed")
    assert t82["rank"] == 2 and "lit" not in t82


def test_a_seaplane_base_with_a_land_strip_is_still_described_by_its_longer_lane(tmp_path):
    def base(rows):
        for r in rows:
            if r["ARPT_ID"] == "T82":
                r["SITE_TYPE_CODE"] = "C"
        return rows

    db = database(tmp_path, {"APT_BASE": base, "APT_RWY": lane_at("T82", "10000")})
    t82 = airports(db)["T82"]
    db.close()
    assert (t82["type"], t82["rwy"]) == ("C", 10000)


def test_a_field_with_only_water_lanes_is_still_described_by_them(tmp_path):
    def wet(rows):
        for r in rows:
            if r["ARPT_ID"] == "T82":
                r["SURFACE_TYPE_CODE"] = "WATER"
        return lane_at("T82", "3000")(rows)

    t82 = runways(tmp_path, wet)["T82"]
    assert (t82["rwy"], t82["hard"], t82["hdg"], t82["lit"]) == (5002, 0, 147, 1)


def test_a_closed_airport_is_left_out_whatever_its_runways(tmp_path):
    def tower(rows):
        for r in rows:
            if r["ARPT_ID"] == "TS01":
                r["TWR_TYPE_CODE"] = "ATCT"
        return rows

    db = database(tmp_path, {"APT_BASE": tower})
    found = airports(db)
    db.close()
    assert "TS01" not in found
