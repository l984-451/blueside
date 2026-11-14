"""Where an approach plate's plan view sits on the earth, read from the FAA's GeoPDF viewport."""
import re
import zlib

_NUM = rb"(-?\d*\.?\d+)"
_VP = re.compile(rb"/VP\s*\[\s*<<.*?/BBox\s*\[([^\]]*)\].*?/GPTS\s*\[([^\]]*)\].*?/LPTS\s*\[([^\]]*)\]", re.S)
_MEDIA = re.compile(rb"/MediaBox\s*\[([^\]]*)\]")
_STROKE = {b"S", b"s", b"B", b"B*", b"b", b"b*"}
_PAINT = _STROKE | {b"f", b"F", b"f*", b"n"}
_TOKEN = re.compile(rb"\((?:\\.|[^\\)])*\)|<[^<>]*>|/[^\s/\[\]()<>]+|-?\d*\.?\d+|[A-Za-z*'\"]+")


def _floats(raw: bytes) -> list[float]:
    return [float(x) for x in raw.split()]


def _solve3(m: list[list[float]], v: list[float]) -> list[float]:
    """Cramer's rule for a 3x3 system."""
    def det(a):
        return (a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]))
    d = det(m)
    return [det([[v[r] if c == i else m[r][c] for c in range(3)] for r in range(3)]) / d for i in range(3)]


def _affine(points: list[tuple[float, float]], values: list[float]):
    """Least squares value = a*x + b*y + c over the points."""
    rows = [(x, y, 1.0) for x, y in points]
    ata = [[sum(r[i] * r[j] for r in rows) for j in range(3)] for i in range(3)]
    atv = [sum(r[i] * v for r, v in zip(rows, values)) for i in range(3)]
    return _solve3(ata, atv)


def _content(pdf: bytes) -> bytes:
    """The decompressed content streams of the (single) page."""
    contents = re.search(rb"/Contents\s*(\[[^\]]*\]|\d+ 0 R)", pdf)
    out = b""
    for ref in re.findall(rb"(\d+) 0 R", contents.group(1)) if contents else []:
        obj = re.search(rb"(?:^|\s)%s 0 obj\s*<<.*?>>\s*stream\r?\n" % ref, pdf, re.S)
        if obj:
            try:
                out += zlib.decompressobj().decompress(pdf[obj.end():]) + b"\n"
            except zlib.error:
                pass
    return out


def _lines(content: bytes, least: float = 20):
    """Horizontal (y, x0, x1) and vertical (x, y0, y1) path edges over 20 points long, in page points:
    every painted one, then the stroked ones alone, since a filled area's edge rules nothing off."""
    h, v, hs, vs, path, stack, ctm, nums, cur = [], [], [], [], [], [], (1.0, 0.0, 0.0, 1.0, 0.0, 0.0), [], None
    for tok in _TOKEN.findall(content):
        if tok[:1] in b"-.0123456789":
            nums.append(float(tok))
            continue
        a, b, c, d, e, f = ctm
        if tok == b"q":
            stack.append(ctm)
        elif tok == b"Q":
            ctm = stack.pop() if stack else ctm
        elif tok == b"cm" and len(nums) >= 6:
            p, q, r, s, t, u = nums[-6:]
            ctm = (p * a + q * c, p * b + q * d, r * a + s * c, r * b + s * d, t * a + u * c + e, t * b + u * d + f)
        elif tok in (b"m", b"l") and len(nums) >= 2:
            x, y = nums[-2] * a + nums[-1] * c + e, nums[-2] * b + nums[-1] * d + f
            if tok == b"l" and cur:
                (x0, y0) = cur
                if abs(y - y0) < 0.5 and abs(x - x0) > least:
                    path.append((h, (y, min(x, x0), max(x, x0))))
                elif abs(x - x0) < 0.5 and abs(y - y0) > least:
                    path.append((v, (x, min(y, y0), max(y, y0))))
            cur = (x, y)
        elif tok in _PAINT:
            for into, line in path:
                into.append(line)
                if tok in _STROKE:
                    (hs if into is h else vs).append(line)
            path = []
        nums = []
    return h, v, hs, vs


def plan_view(pdf: bytes, height: float):
    """The plan view box (left, bottom, right, top) in page points, the airport sketch box inside it if any,
    and the boxed insets drawn at no scale (an alternate missed approach fix, say), each (left, bottom, right, top).

    Plates share one layout: full width rules frame the briefing strip above the plan view, and the
    profile's top rule below it stops where the airport sketch, drawn at its own scale, takes the corner.
    Insets hang off the plan view's frame: a vertical rule meeting a horizontal one that runs to a side.
    """
    h_all, v_all, h_stroked, v_stroked = _lines(_content(pdf))
    h = [line for line in h_all if _span(line) > 100 and 10 < line[0] < height - 10]
    v = [line for line in v_all if _span(line) > 50]
    if not h:
        return None
    width = max(_span(line) for line in h)
    full = [line for line in h if _span(line) > width - 1]
    left, right = full[0][1], full[0][2]
    mid = height / 2
    # The plan view starts under the frequency boxes, whose lower rule may be broken by box edges: the lowest
    # rule reaching both sides with another a box's height above it (an inset row has none), else the lowest.
    rows: dict[float, list] = {}
    for y, x0, x1 in h_all:
        rows.setdefault(round(y), []).append((y, x0, x1))
    ruled = [min(p[0] for p in pieces) for pieces in rows.values() if pieces[0][0] > mid
             and min(p[1] for p in pieces) < left + 1 and max(p[2] for p in pieces) > right - 1
             and sum(map(_span, pieces)) > (right - left) / 2]
    stacked = [y for y in ruled if any(y + 1 < z < y + 40 for z in ruled)]
    bottoms = [line for line in h if line[0] < mid and _span(line) > 200 and line[1] > left - 1 and line[2] < right + 1]
    if not ruled or not bottoms:
        return None
    top = min(stacked or ruled)
    bottom, bx0, bx1 = max(bottoms)
    sketch = None
    edge = bx0 if bx0 > left + 5 else bx1 if bx1 < right - 5 else None
    if edge is not None:
        heights = [y1 for x, _, y1 in v if abs(x - edge) < 0.5 and bottom < y1 < mid]
        if heights:
            sketch = (left, bottom, edge, max(heights)) if edge == bx0 else (edge, bottom, right, max(heights))
    return (left, bottom, right, top), sketch, _insets((left, bottom, right, top), h_stroked, v_stroked)


def _insets(frame, h_stroked, v_stroked) -> list[tuple]:
    """Boxes hanging off the frame: a vertical rule meeting a horizontal one that runs to a side."""
    left, bottom, right, top = frame
    insets = []
    for x, y0, y1 in v_stroked:
        if not (left + 5 < x < right - 5 and y0 > bottom - 1 and y1 < top + 1):
            continue
        for y in (y0, y1):
            for hy, hx0, hx1 in h_stroked:
                # The frame's own top and bottom rules close no inset.
                if abs(hy - y) > 1 or abs(hy - top) < 1 or abs(hy - bottom) < 1:
                    continue
                if abs(hx1 - x) < 1 and abs(hx0 - left) < 1:
                    side = (left, x)
                elif abs(hx0 - x) < 1 and abs(hx1 - right) < 1:
                    side = (x, right)
                else:
                    continue
                # ponytail: narrower boxes are airspace labels on the frame; a fixed width, not a text read.
                if side[1] - side[0] > 45 and (box := (side[0], y0, side[1], y1)) not in insets:
                    insets.append(box)
    return insets


def _span(line) -> float:
    return line[2] - line[1]


def georef(pdf: bytes) -> dict | None:
    """Plan view corners as [lon, lat] (top left, top right, bottom right, bottom left), and the plan view,
    airport sketch and not to scale insets as [left, top, right, bottom] fractions of the page from its top left.
    None when the PDF carries no geospatial viewport or the plan view cannot be found."""
    vp, media = _VP.search(pdf), _MEDIA.search(pdf)
    if not vp or not media or re.search(rb"/Rotate\s+[1-9]", pdf):
        return None
    bbox, gpts, lpts = (_floats(g) for g in vp.groups())
    _, _, page_w, page_h = _floats(media.group(1))
    if len(bbox) != 4 or len(gpts) < 6 or len(gpts) != len(lpts):
        return None
    points = [(bbox[0] + lx * (bbox[2] - bbox[0]), bbox[1] + ly * (bbox[3] - bbox[1]))
              for lx, ly in zip(lpts[0::2], lpts[1::2])]
    lat, lon = _affine(points, gpts[0::2]), _affine(points, gpts[1::2])
    found = plan_view(pdf, page_h)
    if not found:
        return None
    (left, bottom, right, top), sketch, insets = found
    if top - bottom < 100:
        return None

    def where(x, y):
        return [round(lon[0] * x + lon[1] * y + lon[2], 6), round(lat[0] * x + lat[1] * y + lat[2], 6)]

    def frac(box):
        return [round(box[0] / page_w, 4), round(1 - box[3] / page_h, 4), round(box[2] / page_w, 4), round(1 - box[1] / page_h, 4)]

    out = {"corners": [where(left, top), where(right, top), where(right, bottom), where(left, bottom)],
           "plan": frac((left, bottom, right, top))}
    if sketch:
        out["sketch"] = frac(sketch)
    if insets:
        out["insets"] = [frac(box) for box in insets]
    return out
