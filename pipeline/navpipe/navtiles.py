import itertools
import json
import math
import sqlite3
import subprocess
from pathlib import Path

from chartpipe.build import run
from chartpipe.pack import BadPack

from . import airfield, labels, surface

CORE_LAYERS = ("airports", "navaids", "fixes", "airspace", "airways", "sua")
LAYERS = CORE_LAYERS + ("runways", "rwy_ends", "airspace_pt", "sua_pt", "obstacles", "class_e", "class_e5", "pja",
                         "maa", "states", "surface", "taxiways", "fbo")
# Floors well under a normal cycle. A failed download must not reach pilots as a blank layer.
MINIMUM = {"airports": 18000, "navaids": 1200, "fixes": 55000, "airspace": 1200, "airways": 1500, "sua": 1000,
           "runways": 8000, "rwy_ends": 16000, "airspace_pt": 1100, "sua_pt": 700, "obstacles": 150000,
           "class_e": 700, "class_e5": 1000, "pja": 500, "maa": 100, "states": 60,
           "surface": 50000, "taxiways": 30000, "fbo": 300}
CLASS_E_ZOOM, ACTIVITY_ZOOM = 6, 8
BCD = "CLASS IN ('B','C','D')"
E_SURFACE = "LOCAL_TYPE IN ('CLASS_E2','CLASS_E3','CLASS_E4')"
# Class E from 700 or 1200 ft AGL, the sectional's faded band; higher floors are left off as on the chart.
E5 = "LOCAL_TYPE = 'CLASS_E5' AND LOWER_CODE = 'SFC' AND CAST(LOWER_VAL AS integer) IN (700, 1200)"
# Degrees: about 100 m, well inside a band that is drawn several pixels wide.
E5_ZOOM, E5_SIMPLIFY = 6, 0.001
# A cell of this many degrees that holds this many turbines is drawn as one wind farm.
FARM_CELL, FARM_MIN, FARM_ZOOM, FARM_ID = 0.1, 5, 8, 10_000_000
RUNWAY_ZOOM = 10
MIN_ZOOM, MAX_ZOOM = 4, 10
# State lines show from the whole-country view; the census file is in the pipeline image.
STATE_ZOOM, STATES = 0, Path("/opt/states/cb_2023_us_state_500k.shp")
AIRPORT_ZOOM = {1: 4, 2: 5, 3: 7, 4: 8, 5: 9}
# A test signal and a fan marker are never drawn, so they stay out of the tiles.
HIDDEN_NAVAIDS = ("VOT", "FAN MARKER")
LOW_NAVAIDS = ("NDB", "NDB/DME", "MARINE NDB")
AIRWAY_LEVEL = {"V": "low", "T": "low", "J": "high", "Q": "high"}
AIRSPACE_ZOOM, SUA_ZOOM, AIRWAY_ZOOM = 6, 6, 7
AUSTIN = (30.19452722, -97.66987611)
NO_IDENT = "<Null>"
AIRSPACE_SQL = (
    "SELECT FID AS row, IDENT AS ident, NAME AS name, CLASS AS class, LOCAL_TYPE AS local_type, "
    "CAST(UPPER_VAL AS integer) AS upper, UPPER_UOM AS upper_uom, UPPER_CODE AS upper_code, "
    "CAST(LOWER_VAL AS integer) AS lower, LOWER_UOM AS lower_uom, LOWER_CODE AS lower_code, "
    "UPPER_DESC AS upper_desc, LOWER_DESC AS lower_desc, SECTOR AS sector, WKHR_CODE AS hours "
    "FROM Class_Airspace WHERE ")


def _feature(geometry: dict, properties: dict, minzoom: int, number: int | None = None) -> dict:
    # tippecanoe honours a first zoom only when it is set on the feature itself.
    feature = {"type": "Feature", "tippecanoe": {"minzoom": minzoom}, "geometry": geometry,
               "properties": {key: value for key, value in properties.items() if value is not None}}
    if number is not None:
        # A top-level number becomes the tile feature id, which the app uses to mark a selection.
        feature["id"] = number
    return feature


def _point(lon: float, lat: float, properties: dict, minzoom: int, number: int | None = None) -> dict:
    return _feature({"type": "Point", "coordinates": [round(lon, 6), round(lat, 6)]}, properties, minzoom, number)


def fuel_kinds(fuel: str | None) -> dict:
    """Map flags for the fuels the map can pick out: 100LL, and Jet A in any grade (A, A+, A++, A1, A1+)."""
    kinds = set((fuel or "").replace(" ", "").split(","))
    return {"ll": 1 if "100LL" in kinds else None,
            "jet": 1 if any(k.startswith("A") for k in kinds) else None}


def airport_features(db: sqlite3.Connection, drawn=frozenset()) -> list[dict]:
    """One point per open airport. drawn holds the ids of fields that have runway outlines."""
    runways, radio = airfield.summary(db), airfield.frequencies(db)
    features = []
    # A closed field is left off the map; drawn like an open one it would mislead.
    rows = db.execute("SELECT id, ident, icao, name, city, type, use, lat, lon, elev, twr, fuel, ownership "
                      "FROM airports WHERE status = 'O'")
    for number, ident, icao, name, city, kind, use, lat, lon, elev, twr, fuel, ownership in rows:
        runway = runways.get(number, {})
        towered = twr.startswith("ATCT")
        length, hard = runway.get("rwy", 0), runway.get("hard", 0)
        if towered:
            rank = 1 if length >= 8000 else 2
        elif use == "PU":
            # A public heliport or seaplane base is never ranked with private fields.
            rank = 3 if kind == "A" and hard else 4
        else:
            rank = 5
        properties = {"kind": "airport", "key": str(number), "id": number, "ident": ident, "icao": icao,
                      "name": name, "nm": airfield.title(name), "city": airfield.title(city), "type": kind,
                      "use": use, "twr": int(towered), "elev": round(elev or 0), "rwy": length, "hard": hard,
                      "rank": rank, "hdg": runway.get("hdg"), "hdg_src": runway.get("hdg_src"),
                      "lit": runway.get("lit"), "fuel": 1 if fuel else None, **fuel_kinds(fuel),
                      "mil": 1 if ownership in airfield.MILITARY else None,
                      "big": 1 if runway.get("paved_len", 0) >= airfield.LONG_RUNWAY else None,
                      "geom": 1 if number in drawn else None, **radio.get(number, {})}
        features.append(_point(lon, lat, properties, AIRPORT_ZOOM[rank], number))
    return features


def runway_features(db: sqlite3.Connection) -> tuple[list[dict], list[dict], dict[str, int]]:
    """Runway outlines and runway end points, and a count of what was left out and what was estimated.
    A runway counted as backwards keeps its outline and loses only its end points. A closed runway is drawn
    with no end points."""
    closed, runways = airfield.closed_runways(db), airfield.summary(db)
    fields = {number: (int(twr.startswith("ATCT")), magvar, (lat, lon)) for number, twr, magvar, lat, lon in
              db.execute("SELECT id, twr, magvar, lat, lon FROM airports WHERE status = 'O'")}
    ends = {}
    for row in db.execute("SELECT airport_id, rwy_id, end_id, true_hdg, lat, lon, displaced_len "
                          "FROM runway_ends ORDER BY rowid"):
        ends.setdefault(row[:2], []).append(row[2:])
    outlines, points, left = [], [], {"no_ends": 0, "conflict": 0, "backwards": 0, "estimated": 0}
    rows = db.execute("SELECT airport_id, rwy_id, length, width, surface FROM runways ORDER BY rowid").fetchall()
    strips = {}
    for airport_id, rwy_id, *_ in rows:
        strips[airport_id] = strips.get(airport_id, 0) + ("/" in rwy_id)
    for number, (airport_id, rwy_id, length, width, surface) in enumerate(rows, start=1):
        if airport_id not in fields:
            continue
        towered, magvar, arp = fields[airport_id]
        filed = ends.get((airport_id, rwy_id), [])
        placed = [end for end in filed if end[2] is not None and end[3] is not None]
        if len(placed) != 2 or placed[0][2:4] == placed[1][2:4]:
            placed = airfield.estimated_ends(rwy_id, filed, length, magvar, arp, strips[airport_id] == 1)
            left["estimated"] += bool(placed and width)
        if not placed or not width:
            # A helipad has one end by nature and is not counted as a gap.
            left["no_ends"] += "/" in rwy_id
            continue
        ring, built = airfield.rectangle((placed[0][3], placed[0][2]), (placed[1][3], placed[1][2]), width)
        if length and abs(built - length) > airfield.MAX_LENGTH_GAP:
            # The FAA's own figures disagree, so the runway is not drawn until someone checks it.
            left["conflict"] += 1
            continue
        field = runways.get(airport_id, {})
        shut = (airport_id, rwy_id) in closed
        # Wider than the airport's own flag, so a style that hides the disc on hard and rwy still has a shape.
        big = field.get("hard") and field.get("rwy", 0) >= airfield.LONG_RUNWAY
        key = f"{airport_id}|{rwy_id}"
        # The id cannot tell a water lane from a land runway: some lanes are numbered plain 04/22.
        water = 1 if (surface or "").startswith("WATER") else None
        properties = {"kind": "runway", "key": key, "apt": airport_id, "rwy": rwy_id, "len": length,
                      "paved": 1 if (surface or "").split("-")[0] in airfield.PAVED else None,
                      "water": water, "twr": towered, "big": 1 if big else None, "closed": 1 if shut else None}
        outlines.append(_feature({"type": "Polygon", "coordinates": [ring]}, properties,
                                 RUNWAY_ZOOM - 1 if big else RUNWAY_ZOOM, number))
        if shut:
            continue
        pairs = ((placed[0], placed[1]), (placed[1], placed[0]))
        if any(airfield.backwards(here[0], here[1], here[2:4], there[2:4], magvar) for here, there in pairs):
            # The two ends are filed at each other's positions. The outline is the same either way; the names are not.
            left["backwards"] += 1
            continue
        for index, (here, there) in enumerate(pairs):
            end_id, true_hdg, lat, lon, displaced = here
            hdg, source = airfield.heading(end_id, true_hdg, (lat, lon), (there[2], there[3]), magvar)
            properties = {"kind": "runway_end", "key": f"{key}|{end_id}", "apt": airport_id, "end": end_id,
                          "hdg": hdg, "hdg_src": source, "disp": displaced or None, "water": water,
                          "twr": towered}
            points.append(_point(lon, lat, properties, RUNWAY_ZOOM, number * 2 + index))
    return outlines, points, left


def drawn_fields(db: sqlite3.Connection, outlines: list[dict]) -> set[int]:
    """Airports whose every open land runway has an outline. Only these may give up their symbol."""
    # Water lanes and closed runways do not count, so a seaplane base keeps its anchor.
    have = {(feature["properties"]["apt"], feature["properties"]["rwy"]) for feature in outlines
            if not feature["properties"].get("water") and not feature["properties"].get("closed")}
    closed = airfield.closed_runways(db)
    partly = {airport_id for airport_id, rwy_id in db.execute(
        "SELECT airport_id, rwy_id FROM runways WHERE rwy_id LIKE '%/%' AND length > 0 "
        "AND coalesce(surface, '') NOT LIKE 'WATER%'")
        if (airport_id, rwy_id) not in have and (airport_id, rwy_id) not in closed}
    return {airport_id for airport_id, _ in have} - partly


def surface_features(db: sqlite3.Connection) -> tuple[list[dict], list[dict], list[dict]]:
    """OpenStreetMap aprons and buildings, taxiway and hold lines, and FBO points, back in degrees."""
    areas, paths, points = [], [], []
    for kind, name, blob, lat, lon in db.execute(
            "SELECT s.kind, s.name, s.points, a.lat, a.lon FROM surface s JOIN airports a ON a.id = s.airport_id"):
        kx, ky = surface.feet_per_degree(lat)
        ring = [[round(lon + x / kx, 7), round(lat + y / ky, 7)] for x, y in surface.unpack(blob)]
        if kind in ("apron", "building"):
            areas.append(_feature({"type": "Polygon", "coordinates": [ring + ring[:1]]}, {"k": kind}, MAX_ZOOM))
        elif kind == "fbo":
            points.append(_feature({"type": "Point", "coordinates": ring[0]}, {"name": name}, MAX_ZOOM))
        elif len(ring) > 1:
            paths.append(_feature({"type": "LineString", "coordinates": ring}, {"k": kind, "ref": name}, MAX_ZOOM))
    return areas, paths, points


def navaid_features(db: sqlite3.Connection) -> list[dict]:
    rows = db.execute("SELECT id, ident, name, type, lat, lon, freq, chan FROM navaids "
                      "WHERE coalesce(status, '') NOT LIKE 'SHUTDOWN%'")
    return [_point(lon, lat, {"kind": "navaid", "key": str(number), "ident": ident, "name": name, "type": kind,
                              "freq": freq, "chan": chan}, 8 if kind in LOW_NAVAIDS else 6, number)
            for number, ident, name, kind, lat, lon, freq, chan in rows if kind not in HIDDEN_NAVAIDS]


def fix_features(db: sqlite3.Connection) -> list[dict]:
    features = []
    for number, ident, lat, lon, use, charts in db.execute("SELECT id, ident, lat, lon, use, charts FROM fixes"):
        enroute, vfr = "ENROUTE" in (charts or ""), use == "VFR"
        properties = {"kind": "fix", "key": str(number), "ident": ident, "use": use, "enr": int(enroute),
                      "vfr": 1 if vfr else None}
        features.append(_point(lon, lat, properties, 8 if vfr else 9 if enroute else 10, number))
    return features


def lines(points: list[tuple]) -> list[list[list[float]]]:
    """Split one airway into drawable runs. Each point is (lat, lon, gap), in order."""
    runs, current = [], []
    for lat, lon, gap in points:
        if lat is None:
            runs.append(current)
            current = []
            continue
        # A leg across the date line would be drawn the long way round the world.
        if current and abs(lon - current[-1][0]) > 180:
            runs.append(current)
            current = []
        current.append([round(lon, 6), round(lat, 6)])
        if gap:
            runs.append(current)
            current = []
    runs.append(current)
    return [found for found in runs if len(found) > 1]


def airway_features(db: sqlite3.Connection) -> list[dict]:
    rows = db.execute("SELECT airway, location, lat, lon, gap FROM airway_points "
                      "ORDER BY airway, location, seq")
    features = []
    groups = itertools.groupby(rows, key=lambda row: row[:2])
    for number, ((airway, location), group) in enumerate(groups, start=1):
        # The letter fixes the level by rule; any other letter gets no flag.
        properties = {"kind": "airway", "key": f"{airway}|{location}", "ident": airway, "location": location,
                      "level": AIRWAY_LEVEL.get(airway[:1])}
        for coordinates in lines([row[2:] for row in group]):
            features.append(_feature({"type": "LineString", "coordinates": coordinates}, properties,
                                     AIRWAY_ZOOM, number))
    return features


def _obstacle_zoom(agl: int) -> int:
    return 7 if agl >= 1000 else 9 if agl >= 500 else MAX_ZOOM


def obstacle_features(db: sqlite3.Connection) -> list[dict]:
    """Every obstacle of 200 ft and taller, plus one mark per wind farm for the wider zooms."""
    features, cells = [], {}
    for number, kind, lat, lon, agl, msl, lighting, quantity in db.execute(
            "SELECT id, type, lat, lon, agl, msl, lighting, quantity FROM obstacles"):
        properties = {"kind": "obstacle", "key": str(number), "type": kind, "agl": agl, "msl": msl,
                      "lighting": lighting, "n": quantity}
        if kind == "WINDMILL" and agl < 1000:
            cells.setdefault((math.floor(lat / FARM_CELL), math.floor(lon / FARM_CELL)), []).append(
                (number, lat, lon, properties))
        else:
            features.append(_point(lon, lat, properties, _obstacle_zoom(agl), number))
    for index, (cell, turbines) in enumerate(sorted(cells.items())):
        if len(turbines) < FARM_MIN:
            features += [_point(lon, lat, p, _obstacle_zoom(p["agl"]), number) for number, lat, lon, p in turbines]
            continue
        # Each turbine is still in the closest tile, flagged so a style can hold it back.
        features += [_point(lon, lat, {**p, "farm": 1}, MAX_ZOOM, number) for number, lat, lon, p in turbines]
        _, lat, lon, tallest = max(turbines, key=lambda turbine: turbine[3]["agl"])
        codes = {p["lighting"] for _, _, _, p in turbines}
        tops = [p["msl"] for _, _, _, p in turbines if p["msl"] is not None]
        group = {"kind": "obstacle_group", "key": f"{cell[0]},{cell[1]}", "type": "WINDMILL", "n": len(turbines),
                 "agl": tallest["agl"], "msl": max(tops) if tops else None,
                 "lighting": codes.pop() if len(codes) == 1 else None}
        features.append(_point(lon, lat, group, FARM_ZOOM, FARM_ID + index))
    return features


def _whole(text) -> int | None:
    # The FAA writes -9998 for no limit; the code column says UNLTD.
    return None if text is None or float(text) < 0 else int(float(text))


def sua_features(path: Path) -> list[dict]:
    features = []
    for source in json.loads(path.read_text())["features"]:
        p = source["properties"]
        properties = {"kind": "sua", "key": str(p["OBJECTID"]), "name": p["NAME"], "type": p["TYPE_CODE"],
                      "upper": _whole(p["UPPER_VAL"]), "upper_uom": p["UPPER_UOM"], "upper_code": p["UPPER_CODE"],
                      "lower": _whole(p["LOWER_VAL"]), "lower_uom": p["LOWER_UOM"],
                      "lower_code": p["LOWER_CODE"], "hours": p["TIMESOFUSE"]}
        features.append(_feature(source["geometry"], properties, SUA_ZOOM, p["OBJECTID"]))
    return features


def state_line_features(states: Path) -> list[dict]:
    """Lines where two states meet, each drawn once. Coasts and national borders are left out."""
    text = subprocess.run(["ogr2ogr", "-f", "GeoJSONSeq", "/vsistdout/", str(states), "-t_srs", "EPSG:4326",
                           "-lco", "COORDINATE_PRECISION=6"], check=True, capture_output=True, text=True).stdout
    rings = []
    for line in filter(None, (line.strip("\x1e\n ") for line in text.splitlines())):
        feature = json.loads(line)
        g = feature["geometry"]
        polygons = [g["coordinates"]] if g["type"] == "Polygon" else g["coordinates"]
        code = feature["properties"]["STUSPS"]
        rings += [(code, [tuple(point) for point in ring]) for polygon in polygons for ring in polygon]
    owners: dict[frozenset, set[str]] = {}
    for code, ring in rings:
        for a, b in itertools.pairwise(ring):
            owners.setdefault(frozenset((a, b)), set()).add(code)
    features, chain = [], []
    for code, ring in rings:
        for a, b in itertools.pairwise(ring):
            shared = owners[frozenset((a, b))]
            if len(shared) > 1 and code == min(shared):
                if not chain:
                    chain = [a]
                chain.append(b)
            elif chain:
                features.append(chain)
                chain = []
        if chain:
            features.append(chain)
            chain = []
    return [_feature({"type": "LineString", "coordinates": [list(p) for p in points]}, {}, STATE_ZOOM)
            for points in features]


def _write(path: Path, features: list[dict]) -> int:
    with open(path, "w") as handle:
        for feature in features:
            handle.write(json.dumps(feature, separators=(",", ":")) + "\n")
    return len(features)


def _write_airspace(shp: Path, out: Path, where: str = BCD, zoom: int = AIRSPACE_ZOOM,
                    part_time: dict[str, str] | None = None, simplify: float | None = None) -> int:
    """Shapes of the class airspace file as one GeoJSON feature per line, each with its first zoom."""
    raw = out.with_name(out.stem + "_raw.geojson")
    raw.unlink(missing_ok=True)
    run(["ogr2ogr", "-f", "GeoJSONSeq", raw, shp, "-sql", AIRSPACE_SQL + where, "-t_srs", "EPSG:4326",
         "-dim", "XY", "-lco", "COORDINATE_PRECISION=6"] + (["-simplify", str(simplify)] if simplify else []))
    # A query that matches nothing may leave no file at all.
    raw.touch()
    count = 0
    with open(raw) as source, open(out, "w") as target:
        for line in source:
            line = line.strip("\x1e\n ")
            if line:
                feature = json.loads(line)
                p = feature["properties"]
                # The file has no id of its own, so the row number is the key for this cycle.
                number = p.pop("row") + 1
                if p.get("ident") == NO_IDENT:
                    del p["ident"]
                # The FAA's -9998 means no value, never a ceiling to print.
                for limit in ("upper", "lower"):
                    if (p.get(limit) or 0) < 0:
                        del p[limit]
                p.update(kind="airspace", key=str(number))
                # The surface area that takes over when a part-time tower closes names the class it replaces.
                if part_time and p.get("local_type") == "CLASS_E2" and p.get("ident") in part_time:
                    p["alt_of"] = part_time[p["ident"]]
                feature["id"] = number
                feature["tippecanoe"] = {"minzoom": zoom}
                target.write(json.dumps(feature, separators=(",", ":")) + "\n")
                count += 1
    raw.unlink()
    return count


def part_time_towers(path: Path) -> dict[str, str]:
    """Ident to class letter for each Class C or D surface area that is not in force all day."""
    found = {}
    with open(path) as handle:
        for line in handle:
            p = json.loads(line)["properties"]
            if (p["class"] in ("C", "D") and p.get("lower") == 0 and p.get("ident")
                    and p.get("hours") not in (None, "H24")):
                found[p["ident"]] = p["class"]
    return found


def activity_features(db: sqlite3.Connection) -> tuple[list[dict], list[dict]]:
    """Parachute jump areas, then the other activity areas, as two lists of points."""
    jump, other = [], []
    for number, ident, kind, name, lat, lon, max_alt, radius, charted in db.execute(
            "SELECT id, ident, type, name, lat, lon, max_alt, radius, charted FROM activity_areas"):
        properties = {"kind": "activity", "key": str(number), "ident": ident, "type": kind, "name": name,
                      "max": max_alt, "radius": radius, "chart": charted or None}
        (jump if kind == "PARACHUTE" else other).append(_point(lon, lat, properties, ACTIVITY_ZOOM, number))
    return jump, other


def tile_xy(lat: float, lon: float, zoom: int) -> tuple[int, int]:
    n = 2 ** zoom
    y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    return int((lon + 180) / 360 * n), int(y)


def decode(pmtiles: Path, zoom: int, x: int, y: int) -> list[dict]:
    """Features of one tile. Each carries its layer name under tippecanoe.layer."""
    out = subprocess.run(["tippecanoe-decode", "-c", str(pmtiles), str(zoom), str(x), str(y)],
                         check=True, capture_output=True, text=True).stdout
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def _show(pmtiles: Path, what: str) -> dict:
    return json.loads(subprocess.run(["pmtiles", "show", what, str(pmtiles)],
                                     check=True, capture_output=True, text=True).stdout)


def check(pmtiles: Path) -> None:
    """Refuse an archive with a missing or unknown layer, or one where the first zooms were ignored."""
    tile_type = _show(pmtiles, "--header-json")["tile_type"]
    names = {layer["id"] for layer in _show(pmtiles, "--metadata")["vector_layers"]}
    if tile_type != "mvt" or not set(CORE_LAYERS) <= names <= set(LAYERS):
        raise BadPack(f"{pmtiles.name}: tile type {tile_type}, layers {sorted(names)}")
    low = {f["tippecanoe"]["layer"] for f in decode(pmtiles, MIN_ZOOM, *tile_xy(*AUSTIN, MIN_ZOOM))}
    if low - {"airports", "states"}:
        raise BadPack(f"{pmtiles.name}: zoom {MIN_ZOOM} holds {sorted(low - {'airports', 'states'})}")
    high = decode(pmtiles, MAX_ZOOM, *tile_xy(*AUSTIN, MAX_ZOOM))
    if not any(f["tippecanoe"]["layer"] == "airports" and f["properties"].get("ident") == "AUS" for f in high):
        raise BadPack(f"{pmtiles.name}: Austin is missing at zoom {MAX_ZOOM}")


def check_national(counts: dict[str, int]) -> None:
    """Refuse a national build in which any layer is thin or absent."""
    if short := {name: counts.get(name, 0) for name, floor in MINIMUM.items() if counts.get(name, 0) < floor}:
        raise BadPack(f"too few tile features: {short}")


def build(db_path: Path, shp: Path, sua: Path, out: Path, scratch: Path, cycle_id: str,
          states: Path = STATES) -> dict[str, int]:
    """Write the vector tile archive for one cycle. Returns the feature count of each layer."""
    scratch.mkdir(parents=True, exist_ok=True)
    files = {name: scratch / f"{name}.geojson" for name in LAYERS}
    db = sqlite3.connect(db_path)
    outlines, ends, left = runway_features(db)
    airports = airport_features(db, drawn_fields(db, outlines))
    jump, other = activity_features(db)
    areas, paths, fbos = surface_features(db)
    counts = {
        "airports": _write(files["airports"], airports),
        "navaids": _write(files["navaids"], navaid_features(db)),
        "fixes": _write(files["fixes"], fix_features(db)),
        "airways": _write(files["airways"], airway_features(db)),
        "sua": _write(files["sua"], sua_features(sua)),
        "runways": _write(files["runways"], outlines),
        "rwy_ends": _write(files["rwy_ends"], ends),
        "obstacles": _write(files["obstacles"], obstacle_features(db)),
        "pja": _write(files["pja"], jump),
        "maa": _write(files["maa"], other),
        "states": _write(files["states"], state_line_features(states) if states.exists() else []),
        "surface": _write(files["surface"], areas),
        "taxiways": _write(files["taxiways"], paths),
        "fbo": _write(files["fbo"], fbos),
    }
    db.close()
    print(f"{cycle_id}: runways left out {left}")
    counts["airspace"] = _write_airspace(shp, files["airspace"])
    counts["class_e"] = _write_airspace(shp, files["class_e"], E_SURFACE, CLASS_E_ZOOM,
                                        part_time_towers(files["airspace"]))
    counts["class_e5"] = _write_airspace(shp, files["class_e5"], E5, E5_ZOOM, simplify=E5_SIMPLIFY)
    if empty := [name for name in CORE_LAYERS if not counts[name]]:
        raise BadPack(f"no features for {empty}")
    # Labels keep clear of the airports that draw a symbol at the zooms where labels show.
    spots = [feature["geometry"]["coordinates"] for feature in airports if feature["properties"]["rank"] <= 3]
    counts["airspace_pt"] = labels.write(files["airspace"], files["airspace_pt"], spots, merge=False)
    counts["sua_pt"] = labels.write(files["sua"], files["sua_pt"], spots, merge=True)
    bare = labels.unlabeled(files["airspace_pt"], files["airspace"])
    print(f"{cycle_id}: {len(bare)} of {counts['airspace']} airspace shapes have no label")
    for p in bare:
        print(f"  no label: {p.get('name')} {p.get('lower')} to {p.get('upper')}")
    kinds = [p.get("type") or "?" for p in labels.unlabeled(files["sua_pt"], files["sua"])]
    by_type = {kind: kinds.count(kind) for kind in sorted(set(kinds))}
    print(f"{cycle_id}: {counts['sua_pt']} special use labels for {counts['sua']} areas; "
          f"areas under no label by type: {by_type}")
    # Without --drop-rate=1 tippecanoe thins points at low zoom and airports vanish.
    # The finer grid and lighter simplification keep an airspace arc within a few metres.
    # A narrow runway is a few grid units wide; tiny-polygon reduction would replace it with a dot.
    # The wider buffer keeps the inside bands of airspace from showing the tile's cut edges.
    command = ["tippecanoe", "-o", out, "--force", "--quiet", f"-Z{STATE_ZOOM}", f"-z{MAX_ZOOM}",
               "--drop-rate=1", "--no-feature-limit", "--no-tile-size-limit", "--simplification=1",
               "--full-detail=13", "--no-tiny-polygon-reduction", "--detect-shared-borders", "--buffer=10",
               f"--name=FAA nav {cycle_id}", f"--attribution=FAA NASR {cycle_id}; © OpenStreetMap contributors"]
    # A layer with nothing in it is left out here; the national count check insists on every layer.
    for name in LAYERS:
        if counts[name]:
            command += ["-L", f"{name}:{files[name]}"]
    run(command)
    check(out)
    return counts
