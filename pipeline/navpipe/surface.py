"""Airport surface detail from OpenStreetMap (© OpenStreetMap contributors, ODbL): taxiways, aprons, buildings,
FBOs and hold lines, kept per airport in feet from its reference point."""
import json
import math
import re
import sqlite3
import struct
from datetime import datetime, timedelta
from pathlib import Path

from chartpipe.build import run

US_EXTRACT = "https://download.geofabrik.de/north-america/us-latest.osm.pbf"
# The extract is fetched again once the cached detail is this old; never per cycle.
MAX_AGE = timedelta(days=31)
FT = 0.3048
# A feature is kept for a field it lies inside, or else for the nearest field within this many feet.
NEAR_FT = 6000
# Douglas-Peucker tolerance, and the smallest things kept.
SIMPLIFY_FT = 3
MIN_AREA_FT2 = {"building": 400, "apron": 2500}
MIN_LINE_FT = 60
LIMIT = 32767
_FBO = re.compile(r"\bFBO\b|FLIGHT SUPPORT|JET ?CENTER|AVIATION|AIR ?CENTER|AERO ?CENTER|FLIGHT CENTER|MILLION AIR"
                  r"|SHELTAIR|SIGNATURE|AVFLIGHT|WILSON AIR CENTER|TAC AIR|AIRCRAFT SERVICES|AIR SERVICE", re.I)
# Government, military, school and museum names share those words but sell no fuel or parking.
_NOT_FBO = re.compile(r"FEDERAL AVIATION|\bFAA\b|POLICE|SHERIFF|NATIONAL GUARD|ARMY|NAVY|AIR FORCE|COAST GUARD"
                      r"|HELIPORT|AIRPORT|AIRFIELD|MUSEUM|SCHOOL|ACADEMY|COLLEGE|UNIVERSITY|TOWER", re.I)


def feet_per_degree(lat: float) -> tuple[float, float]:
    """Feet per degree of longitude and latitude on WGS84, the same figures the app uses."""
    r = math.radians(lat)
    return ((111412.84 * math.cos(r) - 93.5 * math.cos(3 * r) + 0.118 * math.cos(5 * r)) / FT,
            (111132.92 - 559.82 * math.cos(2 * r) + 1.175 * math.cos(4 * r)) / FT)


def _ref(tags: dict) -> str | None:
    ref = (tags.get("ref") or "").strip()
    if not ref:
        name = re.sub(r"(?i)^taxi(way|lane)\s+", "", (tags.get("name") or "").strip())
        ref = name if len(name) <= 4 else ""
    return ref or None


def _fbo(tags: dict) -> str | None:
    name = (tags.get("name") or tags.get("operator") or "").strip()
    if tags.get("aeroway") == "fbo":
        return name or "FBO"
    # A heliport or field named for a company is a place, not its FBO.
    if tags.get("aeroway") in ("aerodrome", "helipad", "heliport", "runway"):
        return None
    return name if name and _FBO.search(name) and not _NOT_FBO.search(name) else None


def _rings(geometry: dict) -> list[list]:
    if geometry["type"] == "Polygon":
        return [geometry["coordinates"][0]]
    if geometry["type"] == "MultiPolygon":
        return [polygon[0] for polygon in geometry["coordinates"]]
    return []


def classify(feature: dict) -> list[dict]:
    """Compact cache rows for one exported OSM feature: k kind, n name, g a point or line of [lon, lat], and for
    an aerodrome its faa and icao codes."""
    tags, geometry = feature.get("properties") or {}, feature.get("geometry") or {}
    aeroway, kind = tags.get("aeroway"), geometry.get("type")
    if aeroway == "aerodrome":
        return [{"k": "field", "faa": tags.get("faa"), "icao": tags.get("icao"), "g": ring}
                for ring in _rings(geometry)]
    if kind == "LineString":
        if aeroway in ("taxiway", "taxilane"):
            return [{"k": aeroway, "n": _ref(tags), "g": geometry["coordinates"]}]
        if aeroway == "holding_position":
            return [{"k": "hold", "g": geometry["coordinates"]}]
        return []
    if kind == "Point":
        if aeroway == "holding_position":
            return [{"k": "hold", "g": [geometry["coordinates"]]}]
        # A named point counts as an FBO only on airport business, never a shop or house that shares a word.
        fbo = _fbo(tags) if aeroway or tags.get("amenity") or tags.get("office") else None
        return [{"k": "fbo", "n": fbo, "g": [geometry["coordinates"]]}] if fbo else []
    rings = _rings(geometry)
    if aeroway == "apron":
        return [{"k": "apron", "g": ring} for ring in rings]
    if tags.get("building") or aeroway in ("hangar", "terminal", "fbo"):
        rows = [{"k": "building", "g": ring} for ring in rings]
        if (fbo := _fbo(tags)) and rings:
            ring = max(rings, key=len)
            rows.append({"k": "fbo", "n": fbo, "g": [[sum(p[0] for p in ring[:-1]) / (len(ring) - 1),
                                                       sum(p[1] for p in ring[:-1]) / (len(ring) - 1)]]})
        return rows
    return []


def _export(pbf: Path) -> Path:
    out = pbf.with_suffix(".geojsonl")
    run(["osmium", "export", pbf, "-f", "geojsonseq", "-o", out, "--overwrite", "--add-unique-id=type_id",
         "-x", "print_record_separator=false"])
    return out


def _lines(path: Path):
    with open(path) as handle:
        for line in handle:
            if line := line.strip("\x1e\n "):
                yield json.loads(line)


def _fields_polygon(tagged: Path, out: Path) -> None:
    """Every aerodrome outline merged into one shape, for cutting the buildings inside them out of the extract."""
    from osgeo import ogr  # Only in the pipeline image; the tests never fetch.
    union = ogr.Geometry(ogr.wkbMultiPolygon)
    for feature in _lines(tagged):
        if (feature.get("properties") or {}).get("aeroway") == "aerodrome" and feature["geometry"]["type"] != "Point":
            shape = ogr.CreateGeometryFromJson(json.dumps(feature["geometry"])).MakeValid()
            for part in range(shape.GetGeometryCount()) if shape.GetGeometryType() == ogr.wkbMultiPolygon else [None]:
                piece = shape if part is None else shape.GetGeometryRef(part)
                if piece.GetGeometryType() == ogr.wkbPolygon:
                    union.AddGeometry(piece)
    out.write_text(json.dumps({"type": "Feature", "properties": {},
                               "geometry": json.loads(union.UnionCascaded().ExportToJson())}))


def fetch(cache: Path, now: datetime) -> Path:
    """Surface detail for every US airport as cache rows, one JSON object per line. Rebuilt from the Geofabrik US
    extract when older than MAX_AGE; a failed rebuild keeps the older rows, so a nav cycle never waits on it."""
    out = cache / "surface.jsonl"
    if out.exists() and now.timestamp() - out.stat().st_mtime < MAX_AGE.total_seconds():
        return out
    try:
        return _rebuild(cache, now, out)
    except Exception as error:
        if not out.exists():
            raise
        print(f"surface: kept the rows from {datetime.fromtimestamp(out.stat().st_mtime):%Y-%m-%d}, refresh failed: {error}")
        return out


def _rebuild(cache: Path, now: datetime, out: Path) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    pbf = cache / "us.osm.pbf"
    if not pbf.exists() or now.timestamp() - pbf.stat().st_mtime > MAX_AGE.total_seconds():
        part = cache / "us.osm.pbf.part"
        run(["curl", "-fsSL", "--retry", "3", "-o", part, US_EXTRACT])
        part.rename(pbf)
    tagged, inside, buildings = cache / "tagged.pbf", cache / "inside.pbf", cache / "buildings.pbf"
    run(["osmium", "tags-filter", pbf, "nwr/aeroway", "nwr/building=hangar", "-o", tagged, "--overwrite"])
    tagged_rows = _export(tagged)
    fields = cache / "fields.geojson"
    _fields_polygon(tagged_rows, fields)
    run(["osmium", "extract", "-p", fields, pbf, "-o", inside, "--overwrite"])
    run(["osmium", "tags-filter", inside, "nwr/building", "-o", buildings, "--overwrite"])
    building_rows = _export(buildings)
    part, seen, count = out.with_suffix(".part"), set(), 0
    with open(part, "w") as target:
        for source in (tagged_rows, building_rows):
            for feature in _lines(source):
                # A hangar is in both files.
                if feature.get("id") in seen:
                    continue
                seen.add(feature.get("id"))
                for row in classify(feature):
                    target.write(json.dumps(row, separators=(",", ":")) + "\n")
                    count += 1
    part.rename(out)
    for path in (pbf, tagged, inside, buildings, tagged_rows, building_rows, fields):
        path.unlink(missing_ok=True)
    print(f"surface: {count} rows from OpenStreetMap")
    return out


def _inside(point, ring) -> bool:
    x, y, found = point[0], point[1], False
    for (ax, ay), (bx, by) in zip(ring, ring[1:] + ring[:1]):
        if (ay > y) != (by > y) and x < ax + (y - ay) * (bx - ax) / (by - ay):
            found = not found
    return found


def _simplify(points: list, tolerance: float) -> list:
    """Douglas-Peucker on [x, y] points."""
    if len(points) < 3:
        return points
    (ax, ay), (bx, by) = points[0], points[-1]
    dx, dy = bx - ax, by - ay
    length = math.hypot(dx, dy)
    far, index = 0.0, 0
    for i in range(1, len(points) - 1):
        px, py = points[i]
        d = abs(dy * (px - ax) - dx * (py - ay)) / length if length else math.hypot(px - ax, py - ay)
        if d > far:
            far, index = d, i
    if far <= tolerance:
        return [points[0], points[-1]]
    return _simplify(points[:index + 1], tolerance)[:-1] + _simplify(points[index:], tolerance)


def _area(ring: list) -> float:
    return abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(ring, ring[1:] + ring[:1]))) / 2


def _cell(lon: float, lat: float) -> tuple[int, int]:
    return math.floor(lon * 10), math.floor(lat * 10)


def pack(points: list) -> bytes | None:
    """Little-endian 16-bit feet east and north, or None when a point is out of range."""
    flat = [round(v) for p in points for v in p]
    return struct.pack(f"<{len(flat)}h", *flat) if all(-LIMIT <= v <= LIMIT for v in flat) else None


def unpack(blob: bytes) -> list[tuple[int, int]]:
    values = struct.unpack(f"<{len(blob) // 2}h", blob)
    return list(zip(values[::2], values[1::2]))


def insert(db: sqlite3.Connection, rows: Path) -> int:
    """Give each cached feature to its airport and write it, simplified and in feet, to the surface table."""
    airports, cells = {}, {}
    for number, ident, icao, lat, lon in db.execute(
            "SELECT id, ident, icao, lat, lon FROM airports WHERE type = 'A' AND status = 'O'"):
        airports[number] = (ident, icao, lat, lon)
        cells.setdefault(_cell(lon, lat), []).append(number)
    by_code = {}
    for number, (ident, icao, _, _) in airports.items():
        by_code.setdefault(ident, number)
        if icao:
            by_code.setdefault(icao, number)

    features, fields = [], []
    for row in _lines(rows):
        (fields if row["k"] == "field" else features).append(row)
    # Each outline belongs to the airport its codes name, else to the one whose point is inside it.
    field_cells = {}
    for field in fields:
        ring = [tuple(p) for p in field["g"]]
        owner = by_code.get(field.get("faa")) or by_code.get(field.get("icao"))
        xs, ys = [p[0] for p in ring], [p[1] for p in ring]
        box = (min(xs), min(ys), max(xs), max(ys))
        if not owner:
            for cx in range(_cell(box[0], box[1])[0], _cell(box[2], box[3])[0] + 1):
                for cy in range(_cell(box[0], box[1])[1], _cell(box[2], box[3])[1] + 1):
                    for number in cells.get((cx, cy), []):
                        if not owner and _inside((airports[number][3], airports[number][2]), ring):
                            owner = number
        if owner:
            for cx in range(_cell(box[0], box[1])[0], _cell(box[2], box[3])[0] + 1):
                for cy in range(_cell(box[0], box[1])[1], _cell(box[2], box[3])[1] + 1):
                    field_cells.setdefault((cx, cy), []).append((box, ring, owner))

    def owner_of(lon: float, lat: float) -> int | None:
        for box, ring, number in field_cells.get(_cell(lon, lat), []):
            if box[0] <= lon <= box[2] and box[1] <= lat <= box[3] and _inside((lon, lat), ring):
                return number
        best, near = None, NEAR_FT
        cx, cy = _cell(lon, lat)
        for x in (cx - 1, cx, cx + 1):
            for y in (cy - 1, cy, cy + 1):
                for number in cells.get((x, y), []):
                    _, _, alat, alon = airports[number]
                    kx, ky = feet_per_degree(alat)
                    d = math.hypot((lon - alon) * kx, (lat - alat) * ky)
                    if d < near:
                        best, near = number, d
        return best

    count = 0
    for row in features:
        kind, geometry = row["k"], row["g"]
        middle = geometry[len(geometry) // 2]
        number = owner_of(*middle)
        if number is None:
            continue
        _, _, alat, alon = airports[number]
        kx, ky = feet_per_degree(alat)
        points = [((lon - alon) * kx, (lat - alat) * ky) for lon, lat in geometry]
        if kind in MIN_AREA_FT2:
            # Rings are written open.
            points = _simplify(points, SIMPLIFY_FT)[:-1]
            if len(points) < 3 or _area(points) < MIN_AREA_FT2[kind]:
                continue
        elif len(points) > 1:
            points = _simplify(points, SIMPLIFY_FT)
            if kind != "hold" and sum(math.dist(a, b) for a, b in zip(points, points[1:])) < MIN_LINE_FT:
                continue
        if (blob := pack(points)) is None:
            continue
        db.execute("INSERT INTO surface(airport_id, kind, name, points) VALUES (?, ?, ?, ?)",
                   (number, kind, row.get("n"), blob))
        count += 1
    return count
