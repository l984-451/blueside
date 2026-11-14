"""Where an airport diagram sits on earth, read from the latitude and longitude lines printed on it.

Diagrams carry no GeoPDF viewport, but each is drawn north up (a few a quarter turn) with a graticule
line or tick at whole or half minutes, labeled like 33°34'N. The labels name the lines, the lines give
the exact page positions, and the airport's surveyed runway ends, which must fall on the drawn runways,
check the result.
"""
import html
import math
import re
import subprocess
import tempfile
from pathlib import Path

from . import geo

DPI = 150
# Farthest a runway end or centerline may sit from where the diagram draws it.
LIMIT_M = 30.0
# A label sits on its line; this far off in points it names some other line.
LABEL_GAP = 5.0
_LABEL = re.compile(r"^(\d{1,3})°(\d{1,2}(?:\.\d+)?)'([NSEW])$")
_WORD = re.compile(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">([^<]*)</word>')
_PAGE = re.compile(r'<page width="([\d.]+)" height="([\d.]+)">')
DARK = 110


def labels(path: Path) -> tuple[float, float, list[tuple[str, float, float, float]]]:
    """Page size and every latitude or longitude label as ("lat" or "lon", degrees, middle x, middle y),
    y from the bottom as in the PDF."""
    text = subprocess.run(["pdftotext", "-bbox", "-f", "1", "-l", "1", str(path), "-"],
                          check=True, capture_output=True, text=True, errors="replace").stdout
    page = _PAGE.search(text)
    if not page:
        return 0, 0, []
    width, height = float(page.group(1)), float(page.group(2))
    words = [(*map(float, w[:4]), html.unescape(w[4]).replace("’", "'")) for w in _WORD.findall(text)]
    # Some diagrams draw the degree sign as a picture, which splits "43" from "09'N", or space the
    # hemisphere off as "2.5' W"; join them back.
    joined = []
    for w in words:
        last = joined[-1] if joined else None
        near = last and abs(last[1] - w[1]) < 1 and 0 <= w[0] - last[2] < 12
        if near and re.fullmatch(r"\d{1,3}", last[4]) and re.fullmatch(r"\d{1,2}(?:\.\d+)?'[NSEW]", w[4]):
            joined[-1] = (last[0], min(last[1], w[1]), w[2], max(last[3], w[3]), f"{last[4]}°{w[4]}")
        elif near and re.fullmatch(r"\d{1,3}°\d{1,2}(?:\.\d+)?'", last[4]) and w[4] in ("N", "S", "E", "W"):
            joined[-1] = (last[0], min(last[1], w[1]), w[2], max(last[3], w[3]), last[4] + w[4])
        else:
            joined.append(w)
    found = []
    for x0, y0, x1, y1, word in joined:
        if m := _LABEL.match(word):
            value = (int(m.group(1)) + float(m.group(2)) / 60) * (1 if m.group(3) in "NE" else -1)
            found.append(("lat" if m.group(3) in "NS" else "lon", value, (x0 + x1) / 2, height - (y0 + y1) / 2))
    return width, height, found


def _fit(pairs: list[tuple[float, float]]) -> tuple[float, float, float]:
    """Least squares value = slope * position + offset, and the largest miss in the value's units."""
    n = len(pairs)
    mx, my = sum(p for p, _ in pairs) / n, sum(v for _, v in pairs) / n
    slope = sum((p - mx) * (v - my) for p, v in pairs) / sum((p - mx) ** 2 for p, _ in pairs)
    offset = my - slope * mx
    return slope, offset, max(abs(slope * p + offset - v) for p, v in pairs)


def _lines_at(found, positions: set[float], kind: str, axis: str) -> dict[float, float]:
    """Each label's value keyed by the graticule line across axis that it sits on or ends at."""
    out: dict[float, float] = {}
    for k, value, x, y in found:
        at = x if axis == "x" else y
        near = [p for p in positions if abs(p - at) < LABEL_GAP] if k == kind else []
        if near:
            out[min(near, key=lambda p: abs(p - at))] = value
    return out


def _graticule(lines, low: float, high: float, start_side: float, end_side: float) -> set[float]:
    """Positions of the lines that cross most of the frame, drawn in pieces or whole, and of the short
    ticks standing on its sides where a diagram draws no lines."""
    total: dict[float, float] = {}
    ticks = set()
    for at, start, end in lines:
        if low + 1 < at < high - 1:
            total[round(at, 1)] = total.get(round(at, 1), 0) + end - start
            if end - start < 30 and (abs(start - start_side) < 1.5 or abs(end - end_side) < 1.5):
                ticks.add(round(at, 1))
    return ticks | {at for at, length in total.items() if length > (end_side - start_side) / 2}


def _scale(found, positions, lat_axis: str):
    """latitude = a * p + c and longitude = b * q + d, with p the page coordinate along lat_axis and
    q the other one, and the latitude and longitude lines used. None when the labels do not agree."""
    lats = _lines_at(found, positions[lat_axis], "lat", lat_axis)
    lon_axis = "x" if lat_axis == "y" else "y"
    lons = _lines_at(found, positions[lon_axis], "lon", lon_axis)
    if not lats or not lons or len(lats) + len(lons) < 3:
        return None
    squeeze = math.cos(math.radians(sum(lats.values()) / len(lats)))
    # A turned diagram is turned, never mirrored: latitude on y climbs the way longitude climbs on x,
    # latitude on x the opposite way to longitude on y.
    turn = 1 if lat_axis == "y" else -1
    if len(lats) >= 2:
        a, c, lat_miss = _fit(list(lats.items()))
    if len(lons) >= 2:
        b, d, lon_miss = _fit(list(lons.items()))
    if len(lats) < 2:
        a = b * squeeze * turn
        (p, v), = lats.items()
        c, lat_miss = v - a * p, 0
    if len(lons) < 2:
        b = a / squeeze * turn
        (p, v), = lons.items()
        d, lon_miss = v - b * p, 0
    # The same scale both ways, as every diagram is drawn; anything else is a misread label.
    if a * b * turn <= 0 or abs(abs(a) / (abs(b) * squeeze) - 1) > 0.03 \
            or max(lat_miss, lon_miss * squeeze) * 111_320 > 5:
        return None
    return (a, c, b, d), lats, lons


def _frame(h_all, v_all, width: float):
    """The diagram's frame (left, bottom, right, top): the widest ruled box short of the page edge."""
    spans = [(round(x1 - x0), y, x0, x1) for y, x0, x1 in h_all if 100 < x1 - x0 < width - 5]
    if not spans:
        return None
    widest = max(s[0] for s in spans)
    rules = [s for s in spans if s[0] >= widest - 1]
    if len(rules) < 2:
        return None
    left, right = rules[0][2], rules[0][3]
    bottom, top = min(s[1] for s in rules), max(s[1] for s in rules)
    sides = [x for x, y0, y1 in v_all if y1 - y0 > (top - bottom) * 0.9]
    if top - bottom < 100 or not any(abs(x - left) < 1 for x in sides) or not any(abs(x - right) < 1 for x in sides):
        return None
    return left, bottom, right, top


def _gray(path: Path) -> tuple[int, int, bytes]:
    """The first page in gray at DPI: width, height and one byte a pixel, rows from the top."""
    with tempfile.TemporaryDirectory() as folder:
        stem = Path(folder) / "page"
        subprocess.run(["pdftoppm", "-r", str(DPI), "-gray", "-f", "1", "-l", "1", "-singlefile", str(path), str(stem)],
                       check=True, capture_output=True)
        data = stem.with_suffix(".pgm").read_bytes()
    fields, at = [], 0
    while len(fields) < 4:
        while data[at:at + 1].isspace():
            at += 1
        if data[at:at + 1] == b"#":
            at = data.index(b"\n", at)
            continue
        end = at
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[at:end])
        at = end
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[at + 1:at + 1 + w * h]


def runway_miss(image, to_pixel, runway, meters_per_pixel: float) -> float:
    """Meters between a runway's surveyed ends and centerline and where the diagram draws it.
    Each end walks along the centerline to the edge of the drawn (dark) runway; the middle looks across it."""
    w, h, pixels = image

    def dark(x, y):
        xi, yi = round(x), round(y)
        return 0 <= xi < w and 0 <= yi < h and pixels[yi * w + xi] < DARK

    (ax, ay), (bx, by) = to_pixel(*runway[0]), to_pixel(*runway[1])
    length = math.hypot(bx - ax, by - ay)
    if length < 4:
        return math.inf
    ux, uy = (bx - ax) / length, (by - ay) / length
    reach = int(LIMIT_M * 3 / meters_per_pixel) + 2
    misses = []
    for (ex, ey), (dx, dy) in (((ax, ay), (-ux, -uy)), ((bx, by), (ux, uy))):
        if dark(ex, ey):
            # Outward to the first two light pixels: the drawn end is that far past the surveyed one.
            step = next((t for t in range(reach) if not dark(ex + dx * t, ey + dy * t)
                         and not dark(ex + dx * (t + 1), ey + dy * (t + 1))), None)
        else:
            step = next((t for t in range(reach) if dark(ex - dx * t, ey - dy * t)), None)
        misses.append(math.inf if step is None else step)
    runs = []
    for f in (0.3, 0.5, 0.7):
        cx, cy = ax + (bx - ax) * f, ay + (by - ay) * f
        across = [t for t in range(-reach, reach + 1) if dark(cx - uy * t, cy + ux * t)]
        # The dark run holding the centerline, or the nearest one.
        if not across:
            return math.inf
        nearest = min(across, key=abs)
        run = [nearest]
        while run[-1] + 1 in across:
            run.append(run[-1] + 1)
        while run[0] - 1 in across:
            run.insert(0, run[0] - 1)
        runs.append(run)
    # A look across where another runway crosses sees both, wider than the runway itself: it says nothing.
    narrow = min(len(r) for r in runs)
    misses += [abs((r[0] + r[-1]) / 2) for r in runs if len(r) <= narrow * 1.5 + 2]
    return max(misses) * meters_per_pixel


# Page and earth bearings of a runway agree this closely (degrees) once the diagram's turn is known.
BEARING = 3.0
# A graticule line placed from the runways is named by the nearest half minute when this close to it (m).
GRID_M = 230.0
# Meters per point of every diagram drawn: a runway fit outside this matched the wrong marks.
SCALES = (2.0, 30.0)
_RECT = re.compile(rb"(?<![\w.])(-?\d*\.?\d+)\s+(-?\d*\.?\d+)\s+(-?\d*\.?\d+)\s+(-?\d*\.?\d+)\s+re\b")
_FILL = {b"f", b"F", b"f*", b"b", b"B", b"b*", b"B*"}
_STROKED = {b"S", b"s", b"b", b"B", b"b*", b"B*"}


def _unrect(content: bytes) -> bytes:
    """Rectangles spelled out as the four-sided paths they are, so frames drawn as one show their sides."""
    def path(m):
        x, y, w, h = (float(v) for v in m.groups())
        return b"%g %g m %g %g l %g %g l %g %g l %g %g l" % (x, y, x + w, y, x + w, y + h, x, y + h, x, y)
    return _RECT.sub(path, content)


def _shade(nums: list[float]) -> float:
    """Lightness, 0 black to 1, of a gray, RGB or CMYK color."""
    if len(nums) >= 4:
        return 1 - min(1, nums[-1] + max(nums[-4:-1]))
    return sum(nums[-3:]) / 3 if len(nums) == 3 else nums[-1]


def _shape(points) -> tuple | None:
    """A filled outline as (centerline start, end, width) when it is a long, thin, near rectangular area."""
    n, area, cx, cy, sxx, syy, sxy = len(points), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
    for i in range(n):
        (x0, y0), (x1, y1) = points[i], points[(i + 1) % n]
        cross = x0 * y1 - x1 * y0
        area += cross / 2
        cx, cy = cx + (x0 + x1) * cross / 6, cy + (y0 + y1) * cross / 6
        sxx += (x0 * x0 + x0 * x1 + x1 * x1) * cross / 12
        syy += (y0 * y0 + y0 * y1 + y1 * y1) * cross / 12
        sxy += (x0 * y1 + 2 * x0 * y0 + 2 * x1 * y1 + x1 * y0) * cross / 24
    if abs(area) < 4:
        return None
    cx, cy = cx / area, cy / area
    angle = 0.5 * math.atan2(2 * (sxy / area - cx * cy), (sxx / area - cx * cx) - (syy / area - cy * cy))
    u, v = (math.cos(angle), math.sin(angle)), (-math.sin(angle), math.cos(angle))
    along = [(x - cx) * u[0] + (y - cy) * u[1] for x, y in points]
    across = [(x - cx) * v[0] + (y - cy) * v[1] for x, y in points]
    length, wide = max(along) - min(along), max(across) - min(across)
    if wide < 1 or length < 4 * wide or abs(area) < 0.6 * length * wide:
        return None
    mid = (max(across) + min(across)) / 2
    ends = [(cx + u[0] * t + v[0] * mid, cy + u[1] * t + v[1] * mid) for t in (min(along), max(along))]
    return ends[0], ends[1], wide


def _merge(strips: list) -> list:
    """Pieces of one straight strip, cut where another crosses it, joined back up."""
    while True:
        out = []
        for p, q, w in sorted(strips, key=lambda s: -math.dist(s[0], s[1])):
            for i, (p2, q2, w2) in enumerate(out):
                size, wide = math.dist(p2, q2), max(w, w2)
                u = ((q2[0] - p2[0]) / size, (q2[1] - p2[1]) / size)
                ts = [(x - p2[0]) * u[0] + (y - p2[1]) * u[1] for x, y in (p, q)]
                off = [abs((y - p2[1]) * u[0] - (x - p2[0]) * u[1]) for x, y in (p, q)]
                if max(off) < wide / 2 + 0.5 and min(ts) < size + 3 * wide and max(ts) > -3 * wide:
                    lo, hi = min(0.0, *ts), max(size, *ts)
                    out[i] = ((p2[0] + u[0] * lo, p2[1] + u[1] * lo), (p2[0] + u[0] * hi, p2[1] + u[1] * hi), wide)
                    break
            else:
                out.append((p, q, w))
        if len(out) == len(strips):
            return out
        strips = out


def _strips(content: bytes) -> list[tuple[tuple, tuple, float]]:
    """Every dark, long, thin mark on the page, filled or stroked thick, as centerline ends and width in
    points: the runways, among others."""
    found, subs, stack, nums = [], [], [], []
    ctm, fill, stroke, width = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0), 0.0, 0.0, 1.0
    for tok in geo._TOKEN.findall(content):
        if tok[:1] in b"-.0123456789":
            nums.append(float(tok))
            continue
        a, b, c, d, e, f = ctm
        if tok == b"q":
            stack.append((ctm, fill, stroke, width))
        elif tok == b"Q" and stack:
            ctm, fill, stroke, width = stack.pop()
        elif tok == b"cm" and len(nums) >= 6:
            p, q, r, s, t, u = nums[-6:]
            ctm = (p * a + q * c, p * b + q * d, r * a + s * c, r * b + s * d, t * a + u * c + e, t * b + u * d + f)
        elif tok in (b"g", b"rg", b"k", b"sc", b"scn") and nums:
            fill = _shade(nums)
        elif tok in (b"G", b"RG", b"K", b"SC", b"SCN") and nums:
            stroke = _shade(nums)
        elif tok == b"w" and nums:
            width = nums[-1] * math.sqrt(abs(a * d - b * c))
        elif tok == b"m" and len(nums) >= 2:
            subs.append([(nums[-2] * a + nums[-1] * c + e, nums[-2] * b + nums[-1] * d + f)])
        elif tok in (b"l", b"c", b"v", b"y") and len(nums) >= 2 and subs:
            subs[-1].append((nums[-2] * a + nums[-1] * c + e, nums[-2] * b + nums[-1] * d + f))
        elif tok in _FILL or tok in _STROKED or tok == b"n":
            if tok in _FILL and fill < 0.35:
                found += [s for s in map(_shape, (p for p in subs if len(p) >= 3)) if s]
            if tok in _STROKED and stroke < 0.35 and width >= 1.5:
                found += [(p, q, width) for path in subs for p, q in zip(path, path[1:]) if math.dist(p, q) > 4 * width]
            subs = []
        nums = []
    return _merge(found)


def _fit_ends(pairs, lat_axis: str, squeeze: float):
    """Least squares lat = a * p + c, lon = b * q + d through ((lat, lon), (x, y)) pairs, in the graticule's
    form: north up or a quarter turn, one scale both ways."""
    turn = 1 if lat_axis == "y" else -1
    rows = []
    for (lat, lon), (x, y) in pairs:
        p, q = (y, x) if lat_axis == "y" else (x, y)
        rows += [((p, 1.0, 0.0), lat), ((q, 0.0, 1.0), lon * squeeze * turn)]
    ata = [[sum(r[i] * r[j] for r, _ in rows) for j in range(3)] for i in range(3)]
    atv = [sum(r[i] * v for r, v in rows) for i in range(3)]
    try:
        a, c, shifted = geo._solve3(ata, atv)
    except ZeroDivisionError:
        return None
    return (a, c, a * turn / squeeze, shifted * turn / squeeze) if a else None


def _to_page(t, lat_axis: str, lat: float, lon: float) -> tuple[float, float]:
    a, c, b, d = t
    p, q = (lat - c) / a, (lon - d) / b
    return (q, p) if lat_axis == "y" else (p, q)


def _similar(pairs):
    """Least squares page = A * earth + B over (earth, page) complex pairs: turn, scale and shift, no mirror."""
    n = len(pairs)
    w0, z0 = sum(w for w, _ in pairs) / n, sum(z for _, z in pairs) / n
    spread = sum(abs(w - w0) ** 2 for w, _ in pairs)
    if not spread:
        return None
    a = sum((z - z0) * (w - w0).conjugate() for w, z in pairs) / spread
    return a, z0 - a * w0


def _match(strips, runways, earth):
    """The strips that are the runways and the turn, scale and shift they give: (A, B, [(runway, (page start,
    page end))]) with the most runways matched, then the closest; None if no strip is any runway at a likely scale.
    earth maps (lat, lon) to a complex east, north in degrees of latitude."""
    pages = [(complex(*u0), complex(*u1)) for u0, u1, _ in strips]
    pages += [(b, a) for a, b in pages]
    best, best_key = None, None

    def likely(fit):
        return fit and SCALES[0] < 111_320 / abs(fit[0]) < SCALES[1]

    for runway in runways:
        seed_ends = [earth(*e) for e in runway]
        for ends in pages:
            fit, matched = _similar(list(zip(seed_ends, ends))), []
            # Seed from one runway, then refit on every runway it lines up with.
            for _ in range(2):
                if not likely(fit):
                    matched = []
                    break
                a, b = fit
                matched = []
                for r in runways:
                    e0, e1 = (a * earth(*e) + b for e in r)
                    tol = max(4.0, abs(e1 - e0) * math.sin(math.radians(BEARING)))
                    miss, pair = min((max(abs(e0 - s0), abs(e1 - s1)), (s0, s1)) for s0, s1 in pages)
                    if miss < tol:
                        matched.append((r, pair))
                fit = _similar([(earth(*e), s) for r, pair in matched for e, s in zip(r, pair)]) if matched else None
            if not matched or not likely(fit):
                continue
            a, b = fit
            rms = math.sqrt(sum(abs(a * earth(*e) + b - s) ** 2 for r, pair in matched for e, s in zip(r, pair))
                            / (2 * len(matched)))
            # One runway fits any long mark exactly; then the one nearest north up or a quarter turn.
            turn = math.degrees(math.atan2(a.imag, a.real))
            off = min(abs(turn - angle) for angle in (-90, 0, 90))
            key = (len(matched), off < BEARING, -(off if len(matched) == 1 else rms))
            if best_key is None or key > best_key:
                best, best_key = (a, b, matched), key
    return best


def _named(t, lat_axis: str, positions) -> tuple[list, float]:
    """Unlabeled graticule lines as labels, each named with the half minute the runway fit puts it on,
    and the farthest any named line sits from its half minute in meters."""
    a, c, b, d = t
    out, worst = [], 0.0
    for axis in ("y", "x"):
        kind = "lat" if axis == lat_axis else "lon"
        slope, offset, squeeze = (a, c, 1.0) if kind == "lat" else (b, d, abs(a / b))
        # A half minute names only the line nearest it: a second line near by is some other mark.
        best = {}
        for at in positions[axis]:
            value = slope * at + offset
            half = round(value * 120) / 120
            gap = abs(value - half) * squeeze * 111_320
            if gap < GRID_M and gap < best.get(half, (GRID_M, 0))[0]:
                best[half] = (gap, at)
        out += [(kind, half, at, 0.0) if axis == "x" else (kind, half, 0.0, at) for half, (_, at) in best.items()]
        worst = max([worst] + [gap for gap, _ in best.values()])
    return out, worst


def _leave_one_out(pairs) -> float:
    """Largest miss in meters at a runway end when the fit is made without that end."""
    worst = 0.0
    for i, (w, z) in enumerate(pairs):
        fit = _similar(pairs[:i] + pairs[i + 1:])
        if not fit:
            return math.inf
        worst = max(worst, abs(fit[0] * w + fit[1] - z) / abs(fit[0]) * 111_320)
    return worst


def _on_axes(t, lat_axis: str):
    """Placement functions of a graticule form fit: to page (x, y), to earth [lon, lat], meters per point."""
    a, c, b, d = t

    def to_earth(x, y):
        p, q = (y, x) if lat_axis == "y" else (x, y)
        return [b * q + d, a * p + c]

    return (lambda lat, lon: _to_page(t, lat_axis, lat, lon)), to_earth, abs(a) * 111_320


def _from_drawing(content: bytes, runways, positions):
    """Where the diagram sits from its drawn runways matched to the surveyed ones: named graticule lines place a
    diagram drawn north up or a quarter turned, and two or more runways that agree place it alone.
    Returns every such placement (to page, to earth, meters per point, lats, lons, lat_axis) and why there is none."""
    lat0 = sum(e[0] for r in runways for e in r) / (2 * len(runways))
    lon0 = sum(e[1] for r in runways for e in r) / (2 * len(runways))
    squeeze = math.cos(math.radians(lat0))

    def earth(lat, lon):
        return complex((lon - lon0) * squeeze, lat - lat0)

    if not (match := _match(_strips(content), runways, earth)):
        return [], "no runway drawn"
    a, b, matched = match
    out, named = [], []
    pairs = [(earth(*e), s) for r, pair in matched for e, s in zip(r, pair)]
    # One runway reads as well end for end; the graticule names decide which way round it is.
    for flip in (False, True) if len(matched) == 1 else (False,):
        ends = [(e, (s.real, s.imag)) for r, pair in matched for e, s in zip(r, pair[::-1] if flip else pair)]
        turn = math.degrees(math.atan2(a.imag, a.real)) + (180 if flip else 0)
        turn = (turn + 180) % 360 - 180
        # North up is no turn; latitude along x turns the page a quarter either way.
        for lat_axis, sign, angle in (("y", 1, 0), ("x", 1, -90), ("x", -1, 90)):
            if abs(turn - angle) < BEARING:
                t = _fit_ends(ends, lat_axis, squeeze)
                if not t or t[0] * sign <= 0:
                    continue
                labeled, gap = _named(t, lat_axis, positions)
                if reading := _scale(labeled, positions, lat_axis):
                    named.append((gap, (*_on_axes(reading[0], lat_axis), reading[1], reading[2], lat_axis)))
    # The right way round puts the lines on their half minutes; the wrong one only near them.
    if named:
        out.append(min(named, key=lambda n: n[0])[1])
    # The runways alone, which must agree with one another.
    if len(matched) < 2 or _leave_one_out(pairs) > LIMIT_M:
        return out, "one runway" if len(matched) < 2 else "runways disagree"

    def to_earth(x, y):
        w = (complex(x, y) - b) / a
        return [lon0 + w.real / squeeze, lat0 + w.imag]

    def to_page(lat, lon):
        z = a * earth(lat, lon) + b
        return z.real, z.imag

    # Unnamed graticule lines still run to the frame, so they go along as lines that are not inset sides.
    out.append((to_page, to_earth, 111_320 / abs(a), dict.fromkeys(positions["y"]), dict.fromkeys(positions["x"]), "y"))
    return out, ""


def georef(path: Path, runways: list) -> tuple[dict | None, str, float | None]:
    """The diagram's frame corners as [lon, lat] (top left, top right, bottom right, bottom left), the frame as
    the plan view and any boxed insets, in the plates' geo form. Also why it failed, and the runway miss in meters.
    runways: ((lat, lon), (lat, lon)) end pairs from NASR."""
    pdf = path.read_bytes()
    if re.search(rb"/Rotate\s+[1-9]", pdf):
        return None, "rotated", None
    try:
        width, height, found = labels(path)
    except subprocess.CalledProcessError:
        return None, "unreadable", None
    content = _unrect(geo._content(pdf))
    h_all, v_all, h_stroked, v_stroked = geo._lines(content, least=3)
    frame = _frame(h_all, v_all, width)
    if not frame:
        return None, "no frame", None
    left, bottom, right, top = frame
    if not runways:
        return None, "no runways", None
    image = _gray(path)
    k = DPI / 72

    def check(placed):
        """The runway that lies closest to its drawing, in meters."""
        to_page, _, meters = placed[:3]

        def to_pixel(lat, lon):
            x, y = to_page(lat, lon)
            return x * k, (height - y) * k

        return min(runway_miss(image, to_pixel, r, meters / k) for r in runways)

    # Labeled lines first; military and some civil diagrams draw their lettering as outlines, so then the runways.
    placed, outcome, miss = None, "labels" if found else "no label text", None
    positions = {"y": _graticule(h_all, bottom, top, left, right), "x": _graticule(v_all, left, right, bottom, top)}
    # North up, or turned a quarter: the reading with more labels on their lines wins.
    readings = [(r, axis) for axis in ("y", "x") if (r := _scale(found, positions, axis))]
    if readings:
        (t, lats, lons), lat_axis = max(readings, key=lambda r: len(r[0][1]) + len(r[0][2]))
        placed = (*_on_axes(t, lat_axis), lats, lons, lat_axis)
        miss = check(placed)
        if miss > LIMIT_M:
            placed, outcome = None, "runways"
    if not placed:
        # Filled areas' edges are no graticule lines.
        stroked = {"y": _graticule(h_stroked, bottom, top, left, right),
                   "x": _graticule(v_stroked, left, right, bottom, top)}
        drawn, why = _from_drawing(content, runways, stroked)
        if not drawn:
            return None, outcome if found else why, miss
        # The same check as labeled lines get, best placement kept; a misnamed graticule line is half a minute off.
        drawn_miss, drawn = min(((check(d), d) for d in drawn), key=lambda m: m[0])
        if drawn_miss > LIMIT_M:
            return None, outcome if found else "runways", miss if found else drawn_miss
        placed, miss = drawn, drawn_miss
    _, to_earth, _, lats, lons, lat_axis = placed

    def where(x, y):
        return [round(v, 6) for v in to_earth(x, y)]

    def frac(box):
        return [round(box[0] / width, 4), round(1 - box[3] / height, 4),
                round(box[2] / width, 4), round(1 - box[1] / height, 4)]

    # Graticule lines run to the frame and would read as inset sides.
    ys, xs = (lats, lons) if lat_axis == "y" else (lons, lats)
    hs = [line for line in h_stroked if all(abs(line[0] - y) > 1 for y in ys)]
    vs = [line for line in v_stroked if all(abs(line[0] - x) > 1 for x in xs)]
    out = {"corners": [where(left, top), where(right, top), where(right, bottom), where(left, bottom)],
           "plan": frac(frame)}
    if insets := geo._insets(frame, hs, vs):
        out["insets"] = [frac(box) for box in insets]
    return out, "ok", miss
