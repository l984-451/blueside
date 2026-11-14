import csv
import sqlite3
from datetime import datetime
from pathlib import Path

from chartpipe import faa

from . import nasr, surface as osm_surface

# The app builds its test database from an identical copy of this file.
SCHEMA = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "nav" / "nav_schema.sql"
SCHEMA_VERSION = "1"
AIRPORTS_MIN, AIRPORTS_MAX = 19000, 20500
# Floors well under a normal cycle. A table that joined to nothing must not go out.
MINIMUM = {"runways": 19000, "runway_ends": 30000, "frequencies": 30000, "frequencies_tower": 1200,
           "frequencies_ground": 800, "remarks": 60000, "navaids": 1200, "fixes": 55000, "airway_points": 15000,
           "obstacles": 150000, "activity_areas": 600, "surface": 100000}
TABLES = ("airports", "runways", "runway_ends", "frequencies", "remarks", "navaids", "fixes", "airway_points",
          "obstacles", "activity_areas", "surface")
OBSTACLE_MIN_AGL = 200

_EXACT = {"CTAF": "ctaf", "UNICOM": "unicom", "ATIS": "atis", "D-ATIS": "atis", "EMERG": "emergency"}
_STARTS = (("LCL/", "tower"), ("GND/", "ground"), ("CD/", "clearance"), ("CD PRE", "clearance"),
           ("APCH/", "approach"), ("DEP/", "departure"))


def kind(use: str) -> str:
    """Sort the FAA's free-text frequency use by the ordered rules in the schema comment."""
    text = use.strip()
    if "AWOS" in text or "ASOS" in text:
        return "weather"
    if text in _EXACT:
        return _EXACT[text]
    # The slash is part of the rule, so "GND METERING" is not ground and "CDB FSS" is not clearance.
    return next((name for start, name in _STARTS if text.startswith(start)), "other")


def check_national(counts: dict[str, int]) -> None:
    # A cut-off download must not reach pilots as a complete country.
    if not AIRPORTS_MIN <= counts["airports"] <= AIRPORTS_MAX:
        raise ValueError(f"{counts['airports']} airports, expected {AIRPORTS_MIN} to {AIRPORTS_MAX}")
    if short := {name: counts[name] for name, floor in MINIMUM.items() if counts[name] < floor}:
        raise ValueError(f"too few rows: {short}")


def _rows(csv_dir: Path, name: str):
    with open(csv_dir / f"{name}.csv", newline="", encoding="latin-1") as handle:
        yield from csv.DictReader(handle)


def _num(text: str) -> float | None:
    return float(text) if text.strip() else None


def _int(text: str) -> int | None:
    return int(float(text)) if text.strip() else None


def _text(text: str) -> str | None:
    return text.strip() or None


def _only(found: list | None):
    """The single match, or None when there is none or more than one."""
    return found[0] if found and len(found) == 1 else None


def _dms(text: str) -> float | None:
    """33-54-12.8500N as decimal degrees."""
    text = text.strip()
    if not text:
        return None
    degrees, minutes, seconds = text[:-1].split("-")
    value = int(degrees) + int(minutes) / 60 + float(seconds) / 3600
    return -value if text[-1] in "SW" else value


def _areas(csv_dir: Path):
    """Parachute jump areas, then the other activity areas, each with a position where the FAA gives one."""
    for r in _rows(csv_dir, "PJA_BASE"):
        yield {"ident": r["PJA_ID"], "type": "PARACHUTE", "name": _text(r["DROP_ZONE_NAME"]),
               "lat": _num(r["LAT_DECIMAL"]), "lon": _num(r["LONG_DECIMAL"]),
               "max_alt": _text(f"{r['MAX_ALTITUDE'].strip()} {r['MAX_ALTITUDE_TYPE_CODE'].strip()}"),
               "radius": _text(r["PJA_RADIUS"]), "hours": _text(r["TIME_OF_USE"]), "airport": _text(r["ARPT_ID"]),
               "charted": {"Y": 1, "N": 0}.get(r["CHART_REQUEST_FLAG"].strip())}
    outline = {}
    for r in _rows(csv_dir, "MAA_SHP"):
        outline.setdefault(r["MAA_ID"], []).append((_dms(r["LATITUDE"]), _dms(r["LONGITUDE"])))
    for r in _rows(csv_dir, "MAA_BASE"):
        lat, lon = _dms(r["LATITUDE"]), _dms(r["LONGITUDE"])
        if lat is None and (points := outline.get(r["MAA_ID"])):
            # No point is published, so the middle of the published outline stands in for it.
            lat, lon = (sum(point[axis] for point in points) / len(points) for axis in (0, 1))
        yield {"ident": r["MAA_ID"], "type": r["MAA_TYPE_NAME"].strip(), "name": _text(r["MAA_NAME"]),
               "lat": lat, "lon": lon, "max_alt": _text(r["MAX_ALT"]), "radius": _text(r["MAA_RADIUS"]),
               "hours": _text(r["TIME_OF_USE"]), "airport": _text(r["ARPT_IDS"]), "charted": None}


def _obstacles(path: Path):
    """Obstacles of 200 ft above ground and taller. A blank field stays blank; none is dropped for one."""
    with open(path, newline="", encoding="latin-1") as handle:
        for r in csv.DictReader(handle):
            agl = _int(r["AGL"])
            if agl is None or agl < OBSTACLE_MIN_AGL or not r["LATDEC"].strip():
                continue
            yield {"oas": r["OAS"].strip(), "type": _text(r["TYPE"]), "lat": float(r["LATDEC"]),
                   "lon": float(r["LONDEC"]), "agl": agl, "msl": _int(r["AMSL"]),
                   "lighting": _text(r["LIGHTING"]), "quantity": _int(r["QUANTITY"]),
                   "verified": _text(r["VERIFIED STATUS"])}


def _insert(db: sqlite3.Connection, table: str, row: dict) -> None:
    marks = ",".join("?" * len(row))
    db.execute(f"INSERT INTO {table}({','.join(row)}) VALUES ({marks})", list(row.values()))


def build(csv_dir: Path, out: Path, cycle_id: str, built_at: datetime, sua_snapshot: str,
          obstacles: Path | None = None, surface: Path | None = None) -> dict[str, int]:
    """Write the navigation database for one cycle. Returns row counts for the log."""
    effective, expires = nasr.cycle_dates(cycle_id)
    out.unlink(missing_ok=True)
    db = sqlite3.connect(out)
    db.executescript(SCHEMA.read_text())
    for key, value in (("schema_version", SCHEMA_VERSION), ("cycle", cycle_id),
                       ("effective", faa.iso(effective)), ("expires", faa.iso(expires)),
                       ("built_at", faa.iso(built_at)), ("sua_snapshot", sua_snapshot)):
        _insert(db, "meta", {"key": key, "value": value})

    # A trigger in the schema fills the search and nearest indexes from these rows.
    airport = {}
    for number, r in enumerate(_rows(csv_dir, "APT_BASE"), start=1):
        airport[r["ARPT_ID"]] = number
        _insert(db, "airports", {
            "id": number, "site_no": r["SITE_NO"], "ident": r["ARPT_ID"],
            # Never made up from the identifier: most small fields have no ICAO code.
            "icao": _text(r["ICAO_ID"]),
            "name": r["ARPT_NAME"], "city": r["CITY"], "state": r["STATE_CODE"],
            "type": r["SITE_TYPE_CODE"], "use": r["FACILITY_USE_CODE"],
            "lat": float(r["LAT_DECIMAL"]), "lon": float(r["LONG_DECIMAL"]), "elev": _num(r["ELEV"]),
            "magvar": _text(r["MAG_VARN"] + r["MAG_HEMIS"]), "tpa": _text(r["TPA"]),
            "twr": r["TWR_TYPE_CODE"], "fuel": _text(r["FUEL_TYPES"]),
            "artcc": _text(r["RESP_ARTCC_ID"]), "status": r["ARPT_STATUS"],
            "ownership": _text(r["OWNERSHIP_TYPE_CODE"])})

    for r in _rows(csv_dir, "APT_RWY"):
        if number := airport.get(r["ARPT_ID"]):
            _insert(db, "runways", {
                "airport_id": number, "rwy_id": r["RWY_ID"], "length": _int(r["RWY_LEN"]),
                "width": _int(r["RWY_WIDTH"]), "surface": r["SURFACE_TYPE_CODE"], "cond": r["COND"],
                "lights": r["RWY_LGT_CODE"]})

    for r in _rows(csv_dir, "APT_RWY_END"):
        if number := airport.get(r["ARPT_ID"]):
            _insert(db, "runway_ends", {
                "airport_id": number, "rwy_id": r["RWY_ID"], "end_id": r["RWY_END_ID"],
                "true_hdg": _int(r["TRUE_ALIGNMENT"]), "rh_pattern": r["RIGHT_HAND_TRAFFIC_PAT_FLAG"],
                "lat": _num(r["LAT_DECIMAL"]), "lon": _num(r["LONG_DECIMAL"]), "elev": _num(r["RWY_END_ELEV"]),
                "displaced_len": _int(r["DISPLACED_THR_LEN"]), "vgsi": r["VGSI_CODE"],
                "als": r["APCH_LGT_SYSTEM_CODE"], "tora": _int(r["TKOF_RUN_AVBL"]),
                "lda": _int(r["LNDG_DIST_AVBL"])})

    unmatched = 0
    for r in _rows(csv_dir, "FRQ"):
        number = airport.get(r["SERVICED_FACILITY"])
        # A navaid's own frequency can share an identifier with an airport somewhere else.
        if not number or r["FACILITY_TYPE"] == "NAVAID":
            unmatched += 1
            continue
        _insert(db, "frequencies", {
            "airport_id": number, "use": r["FREQ_USE"], "kind": kind(r["FREQ_USE"]),
            "freq": r["FREQ"], "call": r["TOWER_OR_COMM_CALL"], "sector": r["SECTORIZATION"],
            "remark": r["REMARK"]})

    for r in _rows(csv_dir, "APT_RMK"):
        if number := airport.get(r["ARPT_ID"]):
            _insert(db, "remarks", {
                "airport_id": number, "tab": r["TAB_NAME"], "ref_col": r["REF_COL_NAME"],
                "element": r["ELEMENT"], "seq": _int(r["REF_COL_SEQ_NO"]), "remark": r["REMARK"]})

    navaid_by_type, navaid_by_ident = {}, {}
    for number, r in enumerate(_rows(csv_dir, "NAV_BASE"), start=1):
        position = (float(r["LAT_DECIMAL"]), float(r["LONG_DECIMAL"]))
        navaid_by_type.setdefault((r["NAV_ID"], r["NAV_TYPE"].strip()), []).append(position)
        navaid_by_ident.setdefault(r["NAV_ID"], []).append(position)
        _insert(db, "navaids", {
            "id": number, "ident": r["NAV_ID"], "type": r["NAV_TYPE"].strip(), "name": r["NAME"],
            "city": _text(r["CITY"]), "state": _text(r["STATE_CODE"]), "lat": position[0], "lon": position[1],
            "elev": _num(r["ELEV"]), "freq": _text(r["FREQ"]), "chan": _text(r["CHAN"]),
            "magvar": _text(r["MAG_VARN"] + r["MAG_VARN_HEMIS"]), "status": _text(r["NAV_STATUS"])})

    fix_at = {}
    for number, r in enumerate(_rows(csv_dir, "FIX_BASE"), start=1):
        position = (float(r["LAT_DECIMAL"]), float(r["LONG_DECIMAL"]))
        fix_at.setdefault(r["FIX_ID"], []).append(position)
        _insert(db, "fixes", {
            "id": number, "ident": r["FIX_ID"], "state": _text(r["STATE_CODE"]), "lat": position[0],
            "lon": position[1], "use": _text(r["FIX_USE_CODE"]), "charts": _text(r["CHARTS"])})

    unplaced = 0
    for r in _rows(csv_dir, "AWY_SEG_ALT"):
        point, point_type = r["FROM_POINT"], r["FROM_PT_TYPE"].strip()
        # An identifier shared by two facilities is left unplaced, never guessed.
        position = (_only(navaid_by_type.get((point, point_type))) or _only(fix_at.get(point))
                    or _only(navaid_by_ident.get(point)))
        if position is None:
            unplaced += 1
        lat, lon = position or (None, None)
        _insert(db, "airway_points", {
            "airway": r["AWY_ID"], "location": r["AWY_LOCATION"], "seq": int(r["POINT_SEQ"]), "point": point,
            "point_type": point_type or None, "lat": lat, "lon": lon,
            "gap": 1 if r["AWY_SEG_GAP_FLAG"] == "Y" else 0, "mea": _int(r["MIN_ENROUTE_ALT"])})

    for number, row in enumerate(_obstacles(obstacles) if obstacles else (), start=1):
        _insert(db, "obstacles", {"id": number, **row})

    unplaced_areas = 0
    for number, area in enumerate(_areas(csv_dir), start=1):
        if area["lat"] is None or area["lon"] is None:
            unplaced_areas += 1
            continue
        _insert(db, "activity_areas", {"id": number, **area})

    if surface:
        osm_surface.insert(db, surface)

    db.commit()
    db.execute("VACUUM")
    db.execute("ANALYZE")
    db.commit()
    counts = {table: db.execute(f"SELECT count(*) FROM {table}").fetchone()[0] for table in TABLES}
    for name in ("tower", "ground"):
        counts[f"frequencies_{name}"] = db.execute(
            "SELECT count(*) FROM frequencies WHERE kind = ?", (name,)).fetchone()[0]
    counts["frequencies_unmatched"] = unmatched
    counts["airway_points_unplaced"] = unplaced
    counts["activity_areas_unplaced"] = unplaced_areas
    db.close()
    return counts
