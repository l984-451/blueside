"""One label point per airspace shape, and the check that no label states an altitude where it does not apply."""
import heapq
import json
import math
import re
from pathlib import Path

from chartpipe.pack import BadPack

PRECISION = 0.02  # the search stops when no cell can beat the best point by this share of the shape's size
LABEL_ZOOM = 7
NM = 60           # nautical miles in one degree of latitude
TEXT_REACH = 0.05  # degrees south of an airport point that its ident and data line cover at zoom 9
# Most restrictive first. A label for stacked areas of different types takes the first one present.
SEVERITY = ("P", "R", "W", "D", "MOA", "A")


def _polygons(geometry: dict) -> list:
    return [geometry["coordinates"]] if geometry["type"] == "Polygon" else geometry["coordinates"]


def _rings(geometry: dict) -> list:
    """Every ring of every part in one list. Even-odd counting then handles holes and parts alike."""
    return [ring for polygon in _polygons(geometry) for ring in polygon]


def _area(shape: list) -> float:
    # A hole adds to the figure instead of taking away; good enough to tell two footprints apart.
    return sum(abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(ring, ring[1:]))) / 2 for ring in shape)


def _box(shape: list) -> tuple[float, float, float, float]:
    xs = [point[0] for ring in shape for point in ring]
    ys = [point[1] for ring in shape for point in ring]
    return min(xs), min(ys), max(xs), max(ys)


def _overlap(a: tuple, b: tuple) -> bool:
    return a[0] <= b[2] and b[0] <= a[2] and a[1] <= b[3] and b[1] <= a[3]


def inside(shape: list, x: float, y: float) -> bool:
    hit = False
    for ring in shape:
        for a, b in zip(ring, ring[1:]):
            if (a[1] > y) != (b[1] > y) and x < a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1]):
                hit = not hit
    return hit


def _edge(shape: list, x: float, y: float, k: float) -> float:
    """Distance to the nearest edge in degrees of latitude. k squeezes longitude."""
    best = math.inf
    for ring in shape:
        for a, b in zip(ring, ring[1:]):
            dx, dy, px, py = (b[0] - a[0]) * k, b[1] - a[1], (x - a[0]) * k, y - a[1]
            t = max(0.0, min(1.0, (px * dx + py * dy) / ((dx * dx + dy * dy) or 1e-18)))
            best = min(best, (px - t * dx) ** 2 + (py - t * dy) ** 2)
    return math.sqrt(best)


def floor_ft(p: dict) -> float:
    """The floor in feet, for ordering. A height above ground counts as written, which errs low."""
    return (p.get("lower") or 0) * (100 if p.get("lower_uom") == "FL" else 1)


def ceiling_ft(p: dict) -> float:
    if p.get("upper") is None:
        return math.inf
    return p["upper"] * (100 if p.get("upper_uom") == "FL" else 1)


def _blank(p: dict) -> bool:
    """Floor and ceiling both 0: the source gives no limits, so there is nothing true to print."""
    return p.get("lower") == 0 and p.get("upper") == 0


def _airport(x: float, y: float, ax: float, ay: float, k: float) -> float:
    """Distance in degrees of latitude to an airport symbol and the text printed below it."""
    return math.hypot((x - ax) * k, y - min(ay, max(ay - TEXT_REACH, y)))


def load(path: Path) -> list[dict]:
    """The shapes of one layer file that can carry a label. Every vertex is kept, so room is measured truly."""
    shapes = []
    with open(path) as handle:
        for line in handle:
            feature = json.loads(line)
            if _blank(feature["properties"]):
                continue
            everything = _rings(feature["geometry"])
            largest = max(_polygons(feature["geometry"]), key=lambda polygon: _area(polygon[:1]))
            shapes.append({"p": feature["properties"], "id": feature.get("id"), "own": largest,
                           "all": everything, "box": _box(everything), "area": _area(everything)})
    return shapes


def place(own: list, under=(), airports=()) -> tuple[float, float, float] | None:
    """The allowed point with the most room around it, as (lon, lat, room in NM). None when no point is allowed."""
    west, south, east, north = _box(own)
    k = math.cos(math.radians((south + north) / 2))
    size = max((east - west) * k, north - south)
    if size <= 0:
        return None
    # An airport farther out than the shape is wide can never be the nearest thing to an inside point.
    near = [(ax, ay) for ax, ay in airports
            if west - size / k < ax < east + size / k and south - size < ay < north + size + TEXT_REACH]

    walls = [(other, _box(other)) for other in under]

    def room(x: float, y: float) -> float:
        # Positive inside the shape and outside every lower one; the smallest margin decides.
        value = _edge(own, x, y, k) * (1 if inside(own, x, y) else -1)
        for other, (w, s, e, n) in walls:
            # A lower shape whose box is farther off than the margin so far cannot lower it.
            # A point outside the own shape is refused already, so there every lower shape is skipped.
            if math.hypot(max(w - x, x - e, 0) * k, max(s - y, y - n, 0)) >= value:
                continue
            value = min(value, _edge(other, x, y, k) * (-1 if inside(other, x, y) else 1))
        for ax, ay in near:
            value = min(value, _airport(x, y, ax, ay, k))
        return value

    best = (-math.inf, 0.0, 0.0)
    cells = []

    def add(x: float, y: float, half: float) -> None:
        nonlocal best
        value = room(x, y)
        best = max(best, (value, x, y))
        # No point of a cell can beat its centre by more than the half diagonal.
        heapq.heappush(cells, (-(value + half * math.sqrt(2)), x, y, half))

    add((west + east) / 2, (south + north) / 2, size / 2)
    while cells:
        limit, x, y, half = heapq.heappop(cells)
        if -limit - best[0] <= size * PRECISION:
            break
        half /= 2
        for sx, sy in ((-1, -1), (-1, 1), (1, -1), (1, 1)):
            add(x + sx * half / k, y + sy * half, half)
    value, x, y = best
    clear = math.floor(value * NM * 10) / 10
    # A label with no room could never be drawn, so the shape is counted as unlabeled instead.
    if clear <= 0:
        return None
    return round(x, 5), round(y, 5), clear


def _label(properties: dict, number, found: tuple) -> dict:
    lon, lat, room = found
    return {"type": "Feature", "id": number, "tippecanoe": {"minzoom": LABEL_ZOOM},
            "geometry": {"type": "Point", "coordinates": [lon, lat]},
            "properties": {**{name: value for name, value in properties.items() if value is not None},
                           "room": room}}


def airspace_points(path: Path, airports=()) -> list[dict]:
    """One label point per shape, outside every shape of the same name that has a lower floor."""
    shapes = load(path)
    points = []
    for shape in shapes:
        p = shape["p"]
        under = [other["all"] for other in shapes
                 if other is not shape and other["p"].get("name") == p.get("name")
                 and floor_ft(other["p"]) < floor_ft(p) and _overlap(other["box"], shape["box"])]
        if found := place(shape["own"], under, airports):
            points.append(_label(p, shape["id"], found))
    return points


def same_footprint(a: dict, b: dict) -> bool:
    """Two loaded shapes that cover the same ground, give or take a redrawn edge."""
    slack = 0.02 * max(a["box"][2] - a["box"][0], a["box"][3] - a["box"][1])
    return (all(abs(p - q) <= slack for p, q in zip(a["box"], b["box"]))
            and abs(a["area"] - b["area"]) <= 0.05 * max(a["area"], b["area"]))


def sua_points(path: Path, airports=()) -> list[dict]:
    """One label point per footprint. Stacked areas share a label with the lowest floor and highest ceiling."""
    # Lowest floor first; of two areas with one floor the taller leads and gives the label its key.
    shapes = sorted(load(path), key=lambda shape: (floor_ft(shape["p"]), -ceiling_ft(shape["p"])))
    groups = []
    for shape in shapes:
        home = next((group for group in groups
                     if _overlap(group[0]["box"], shape["box"]) and same_footprint(group[0], shape)), None)
        if home is None:
            groups.append([shape])
        else:
            home.append(shape)
    placed, unplaced = [], []
    for group in groups:
        low = group[0]
        # A label never sits over another area that starts lower, stacked or not.
        under = [other["all"] for other in shapes if all(other is not shape for shape in group)
                 and floor_ft(other["p"]) < floor_ft(low["p"]) and _overlap(other["box"], low["box"])]
        found = place(low["own"], under, airports)
        (placed if found else unplaced).append((group, found))
    # An area with no label of its own joins every label inside it, so that label's ceiling covers it.
    for group, found in placed:
        group += [shape for upper, _ in unplaced if inside(upper[0]["all"], found[0], found[1]) for shape in upper]
    points = []
    for group, found in placed:
        low, high = group[0], max(group, key=lambda shape: ceiling_ft(shape["p"]))
        p = dict(low["p"])
        if len(group) > 1:
            names = list(dict.fromkeys(shape["p"]["name"] for shape in group))
            # R-6302A and R-6302B print as R-6302. Any other mix prints every name, so no designator is made up.
            stems = {m.group(1) if (m := re.fullmatch(r"(.*\d)[A-Z]?", name)) else None for name in names}
            short = (names[0] if len(names) == 1 else stems.pop() if len(stems) == 1 and None not in stems
                     else " / ".join(names))
            types = list(dict.fromkeys(shape["p"]["type"] for shape in group if shape["p"].get("type")))
            lead = min(types, key=lambda kind: SEVERITY.index(kind) if kind in SEVERITY else len(SEVERITY),
                       default=None)
            p.update({name: high["p"].get(name) for name in ("upper", "upper_uom", "upper_code")},
                     name=short, names=", ".join(names), keys=",".join(shape["p"]["key"] for shape in group),
                     n=len(group), hours=None, type=lead, types=",".join(types) or None)
        points.append(_label(p, low["id"], found))
    return points


def violations(points: list[dict], shapes: Path, same_name: bool) -> list[tuple[str, str]]:
    """(key, reason) for each label outside its own shape or inside a lower one. Reads every vertex."""
    marks = [(q["key"], set(q.get("keys", q["key"]).split(",")), q.get("name"), floor_ft(q),
              *point["geometry"]["coordinates"]) for point in points for q in [point["properties"]]]
    found, seen = [], set()
    with open(shapes) as handle:
        for line in handle:
            feature = json.loads(line)
            p, shape = feature["properties"], _rings(feature["geometry"])
            if _blank(p):
                continue
            west, south, east, north = _box(shape)
            floor = floor_ft(p)
            for key, keys, name, level, x, y in marks:
                own = key == p["key"]
                if not own and (p["key"] in keys or level <= floor or (same_name and name != p.get("name"))):
                    continue
                within = west <= x <= east and south <= y <= north and inside(shape, x, y)
                if own:
                    seen.add(key)
                    if not within:
                        found.append((key, f"{name}: label is outside its own shape"))
                elif within:
                    found.append((key, f"{name} (floor {level:.0f}): label is inside {p.get('name')} "
                                       f"(floor {floor:.0f})"))
    found += [(key, f"{name}: label has no shape") for key, _, name, *_ in marks if key not in seen]
    return found


def check(points: Path, shapes: Path, airports, same_name: bool) -> None:
    """Refuse label points that would print an altitude where it does not apply."""
    with open(points) as handle:
        found = [json.loads(line) for line in handle]
    broken = [reason for _, reason in violations(found, shapes, same_name)]
    for point in found:
        (x, y), q = point["geometry"]["coordinates"], point["properties"]
        k, reach = math.cos(math.radians(y)), q["room"] / NM
        nearest = min((_airport(x, y, ax, ay, k) for ax, ay in airports if abs(y - ay) < reach + TEXT_REACH),
                      default=math.inf) * NM
        # A tenth of slack: the search measured east-west distance at the middle of the shape.
        if nearest < q["room"] * 0.9 - 0.05:
            broken.append(f"{q.get('name')}: an airport symbol or its text is {nearest:.1f} NM away, inside the "
                          f"stated room of {q['room']}")
    if broken:
        raise BadPack(f"{points.name}: {len(broken)} bad label points, first: {broken[:3]}")


def unlabeled(points: Path, shapes: Path) -> list[dict]:
    """The properties of every shape that no label covers, so the build can name them."""
    covered = set()
    with open(points) as handle:
        for line in handle:
            q = json.loads(line)["properties"]
            covered |= set(q.get("keys", q["key"]).split(","))
    with open(shapes) as handle:
        return [p for p in (json.loads(line)["properties"] for line in handle) if p["key"] not in covered]


def write(shapes: Path, out: Path, airports, merge: bool) -> int:
    """Write the label points of one shape layer and stop the build if any breaks a rule. Returns the count."""
    points = sua_points(shapes, airports) if merge else airspace_points(shapes, airports)
    # The search looked at the largest part only; a point that fails against the whole shape is left out.
    failed = {key for key, _ in violations(points, shapes, same_name=not merge)}
    points = [point for point in points if point["properties"]["key"] not in failed]
    with open(out, "w") as handle:
        for point in points:
            handle.write(json.dumps(point, separators=(",", ":")) + "\n")
    check(out, shapes, airports, same_name=not merge)
    return len(points)
