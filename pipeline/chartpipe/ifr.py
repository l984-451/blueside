"""Trim outlines for enroute sheets, taken from the frame line printed around the map."""
import json
from pathlib import Path

from . import charts

# Hand-entered pixel outlines for sheets whose frame cannot be found unaided:
# [x0, y0, x1, y1], or a list of [x, y] corners when the map is not a rectangle.
# For flyway sheets the outline is a rough guide that the traced frame line replaces.
OVERRIDES: dict[str, list] = json.loads((Path(__file__).parent / "ifr_outlines.json").read_text())
# Sheets trimmed with a shape file because no frame rectangle was safe. The caller reports and clears it.
FALLBACKS: list[str] = []
# A frame edge counts as unbroken when at least this share of its outermost pixel line is dark.
SOLID = 0.95
# A flyway frame sample is on the traced outline when it lies within this many pixels of it.
WANDER = 2


def thick_runs(counts, length: int, share: float, min_px: int) -> list[tuple[int, int]]:
    """Runs of rows or columns that are dark across more than `share` of the sheet and at least min_px thick."""
    runs: list[list[int]] = []
    for i, dark in enumerate(counts):
        if dark <= share * length:
            continue
        if runs and i - runs[-1][1] <= 2:
            runs[-1][1] = i
        else:
            runs.append([i, i])
    return [(first, last) for first, last in runs if last - first + 1 >= min_px]


def corners(shape) -> list[tuple[int, int]]:
    """Corner points of an outline given as (x0, y0, x1, y1) or as a list of points."""
    if isinstance(shape[0], int):
        x0, y0, x1, y1 = shape
        return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    return [tuple(point) for point in shape]


def bounds(shape) -> tuple[int, int, int, int]:
    """Smallest rectangle around an outline."""
    xs, ys = zip(*corners(shape))
    return min(xs), min(ys), max(xs), max(ys)


def frame_px(name: str) -> int:
    """Thinnest frame line: flyway sheets have a hairline frame, enroute sheets a thick one."""
    return 1 if (charts.classify(name) or ("",))[0] == "flyway" else 7


def detect(rows, cols, width: int, height: int, min_px: int = 7) -> tuple[int, int, int, int] | None:
    """Outer edge of the frame as (x0, y0, x1, y1). None unless there are exactly two lines each way."""
    across, down = thick_runs(rows, width, 0.25, min_px), thick_runs(cols, height, 0.25, min_px)
    if len(across) != 2 or len(down) != 2:
        return None
    return down[0][0], across[0][0], down[1][1] + 1, across[1][1] + 1


def on_frame(rect, rows, cols, width: int, height: int) -> tuple[int, int, int, int] | None:
    """The rectangle moved onto the outer side of the long dark lines of this sheet.

    None when an edge is more than 3 pixels from every such line."""
    across, down = thick_runs(rows, width, 0.4, 5), thick_runs(cols, height, 0.4, 5)
    x0, y0, x1, y1 = rect

    def snap(value, lines):
        return min((line for line in lines if abs(value - line) <= 3), key=lambda line: abs(value - line),
                   default=None)

    moved = (snap(x0, [first for first, _ in down]), snap(y0, [first for first, _ in across]),
             snap(x1, [last + 1 for _, last in down]), snap(y1, [last + 1 for _, last in across]))
    return None if None in moved else moved


def leg_points(points) -> list[list[tuple[int, int]]]:
    """For each side of an outline, 46 pixels spread along it, 3 pixels inside the outline."""
    turn = sum(ax * by - bx * ay for (ax, ay), (bx, by) in zip(points, (*points[1:], points[0])))
    inward = 3 if turn > 0 else -3
    legs = []
    for (ax, ay), (bx, by) in zip(points, (*points[1:], points[0])):
        dx, dy = bx - ax, by - ay
        length = (dx * dx + dy * dy) ** 0.5
        legs.append([(round(ax + dx * step / 100 - dy / length * inward),
                      round(ay + dy * step / 100 + dx / length * inward)) for step in range(5, 96, 2)])
    return legs


def choose(name: str, rows, cols, width: int, height: int, edges):
    """The outline to trim a sheet to and where it came from, or None and the reason.

    `edges(shape)` gives the dark share of the left, right, top and bottom lines of a rectangle, or of
    each side of a many-cornered outline. Raises MissingOutline when the frame holds more than the map,
    because the sheet's shape file would keep the extra panel too."""
    shape = OVERRIDES.get(name)
    if shape and not isinstance(shape[0], int):
        outline = tuple(corners(shape))
        if not on_frame(bounds(shape), rows, cols, width, height):
            raise charts.MissingOutline(f"{name}: the hand-entered outline is off the frame line, "
                                        "and the map on this sheet is not a rectangle")
        off = [str(leg) for leg, share in enumerate(edges(outline), 1) if share < SOLID]
        if off:
            raise charts.MissingOutline(f"{name}: leg {', '.join(off)} of the hand-entered outline "
                                        "is not on a dark line")
        return outline, "override"
    if shape:
        rect, how = on_frame(shape, rows, cols, width, height), "override"
        if rect is None:
            return None, "the hand-entered rectangle is off the frame line"
    else:
        px = frame_px(name)
        rect, how = detect(rows, cols, width, height, px), "detected"
        if rect is None:
            across, down = thick_runs(rows, width, 0.25, px), thick_runs(cols, height, 0.25, px)
            return None, f"found {len(across)} horizontal and {len(down)} vertical frame lines"
    gaps = [side for side, share in zip(("left", "right", "top", "bottom"), edges(rect)) if share < SOLID]
    if gaps:
        raise charts.MissingOutline(f"{name}: the frame line has gaps on the {', '.join(gaps)}, "
                                    "so another panel may be printed inside it")
    return rect, how


def follow(dark, shape, search: int = 40, step: int = 8, piece: int = 1000):
    """Trace a hairline frame that may slant or bow a few pixels, starting from a rough outline.

    Each leg is sampled every `step` pixels: the dark line nearest the rough leg, within `search`
    pixels, gives the outer edge there. The traced outline has a corner at the median of each
    `piece` of a leg. Returns the corners and, per leg, the share of samples within WANDER of it."""
    import numpy as np
    points = corners(shape)
    pairs = list(zip(points, (*points[1:], points[0])))
    turn = 1 if sum(ax * by - bx * ay for (ax, ay), (bx, by) in pairs) > 0 else -1
    height, width = dark.shape
    legs = []
    for (ax, ay), (bx, by) in pairs:
        across = abs(bx - ax) >= abs(by - ay)  # True: the leg runs along x
        t0, t1, p0, p1 = (ax, bx, ay, by) if across else (ay, by, ax, bx)
        out = turn * (-1 if across else 1) * (1 if t1 > t0 else -1)
        lo, hi = sorted((t0, t1))
        ts = np.arange(lo + search, hi - search, step)
        found = np.full(len(ts), np.nan)
        for i, t in enumerate(ts):
            guess = round(p0 + (p1 - p0) * (t - t0) / (t1 - t0))
            first, last = max(guess - search, 0), min(guess + search + 1, height if across else width)
            line = dark[first:last, t] if across else dark[t, first:last]
            hits = np.flatnonzero(line)
            if not len(hits):
                continue
            a = b = hits[np.abs(hits + first - guess).argmin()]
            while a > 0 and line[a - 1]:
                a -= 1
            while b + 1 < len(line) and line[b + 1]:
                b += 1
            found[i] = first + (b + 1 if out > 0 else a)
        centers = []
        for part in np.array_split(np.arange(len(ts)), max(2, round((hi - lo) / piece))):
            seen = found[part][~np.isnan(found[part])]
            if not len(seen):
                return None, "a stretch of the frame line is missing"
            centers.append((float(ts[part].mean()), float(np.median(seen))))
        centers.sort(reverse=t1 < t0)
        legs.append((across, ts, found, [(t, p) if across else (p, t) for t, p in centers]))

    def meet(p, q, r, s):
        """Where the line through p and q crosses the line through r and s."""
        d = (p[0] - q[0]) * (r[1] - s[1]) - (p[1] - q[1]) * (r[0] - s[0])
        u = ((p[0] - r[0]) * (r[1] - s[1]) - (p[1] - r[1]) * (r[0] - s[0])) / d
        return p[0] + u * (q[0] - p[0]), p[1] + u * (q[1] - p[1])

    turns = [meet(*legs[i - 1][3][-2:], *legs[i][3][:2]) for i in range(len(legs))]
    outline, shares = [], []
    for i, (across, ts, found, centers) in enumerate(legs):
        path = [turns[i], *centers, turns[(i + 1) % len(legs)]]
        along = [(x if across else y, y if across else x) for x, y in path]
        along.sort()
        traced = np.interp(ts, [t for t, _ in along], [p for _, p in along])
        shares.append(float(np.mean(np.abs(found - traced) <= WANDER)))
        outline += [turns[i], *centers]
    return tuple((round(x), round(y)) for x, y in outline), shares


def choose_flyway(name: str, dark):
    """Like choose, for a flyway sheet: the outline follows its hairline frame, which may slant or bow.

    A hand-entered outline is only a rough guide here. Raises MissingOutline when a leg is broken."""
    rows, cols = dark.sum(1).tolist(), dark.sum(0).tolist()
    height, width = dark.shape
    rough, how = OVERRIDES.get(name), "override"
    if rough is None:
        rough, how = detect(rows, cols, width, height, 1), "detected"
    if rough is None:
        across, down = thick_runs(rows, width, 0.25, 1), thick_runs(cols, height, 0.25, 1)
        return None, f"found {len(across)} horizontal and {len(down)} vertical frame lines"
    outline, shares = follow(dark, rough)
    if outline is None:
        raise charts.MissingOutline(f"{name}: {shares} near the outline")
    off = [str(leg) for leg, share in enumerate(shares, 1) if share < SOLID]
    if off:
        raise charts.MissingOutline(f"{name}: the frame line has gaps on leg {', '.join(off)}, "
                                    "so another panel may be printed inside it")
    return outline, how


def dark_mask(tif: Path):
    """True where a pixel is dark in all three color bands. Needs the GDAL bindings."""
    import numpy as np
    from osgeo import gdal
    gdal.UseExceptions()
    sheet = gdal.Open(rgb(tif))
    dark = np.ones((sheet.RasterYSize, sheet.RasterXSize), bool)
    for band in (1, 2, 3):
        dark &= sheet.GetRasterBand(band).ReadAsArray() < 90
    return dark


def dark_counts(tif: Path) -> tuple[list[int], list[int], int, int]:
    """Dark pixels per row and per column, then the sheet width and height. Needs the GDAL bindings."""
    dark = dark_mask(tif)
    return dark.sum(1).tolist(), dark.sum(0).tolist(), dark.shape[1], dark.shape[0]


def edge_shares(tif: Path, shape) -> tuple[float, ...]:
    """Dark share of the outermost pixel line of the left, right, top and bottom edges of a rectangle,
    or of the pixels just inside each side of a many-cornered outline. Needs GDAL."""
    from osgeo import gdal
    gdal.UseExceptions()
    sheet = gdal.Open(rgb(tif))

    def share(x, y, w, h):
        return float((sheet.ReadAsArray(x, y, w, h, band_list=[1, 2, 3]) < 90).all(0).mean())

    if not isinstance(shape[0], int):
        return tuple(sum(share(x, y, 1, 1) for x, y in leg) / len(leg) for leg in leg_points(shape))
    x0, y0, x1, y1 = shape

    # The two column reads decode the sheet again. Share one mask with dark_counts if build time matters.
    return (share(x0, y0, 1, y1 - y0), share(x1 - 1, y0, 1, y1 - y0),
            share(x0, y0, x1 - x0, 1), share(x0, y1 - 1, x1 - x0, 1))


def write_cutline(tif: Path, shape, out: Path) -> None:
    """Write the pixel outline as a polygon in the chart's own projection, where its edges are straight."""
    from osgeo import gdal, ogr
    gdal.UseExceptions()
    sheet = gdal.Open(str(tif))
    transform = sheet.GetGeoTransform()
    points = corners(shape)
    ring = ogr.Geometry(ogr.wkbLinearRing)
    for px, py in (*points, points[0]):
        ring.AddPoint_2D(*gdal.ApplyGeoTransform(transform, float(px), float(py)))
    polygon = ogr.Geometry(ogr.wkbPolygon)
    polygon.AddGeometry(ring)
    out.unlink(missing_ok=True)
    data = ogr.GetDriverByName("GPKG").CreateDataSource(str(out))
    layer = data.CreateLayer("cut", sheet.GetSpatialRef(), ogr.wkbPolygon)
    feature = ogr.Feature(layer.GetLayerDefn())
    feature.SetGeometry(polygon)
    layer.CreateFeature(feature)
    data = None  # dropping the last reference writes the file


def rgb(tif: Path) -> str:
    """The sheet with three color bands: a paletted one is expanded in memory."""
    from osgeo import gdal
    gdal.UseExceptions()
    sheet = gdal.Open(str(tif))
    if sheet.GetRasterBand(1).GetColorTable() is None:
        return str(tif)
    out = f"/vsimem/{tif.stem}.rgb.vrt"
    gdal.Translate(out, str(tif), format="VRT", rgbExpand="rgb")
    return out


def settle(tif: Path):
    """Read a sheet and choose its outline."""
    if frame_px(tif.name) == 1:
        return choose_flyway(tif.name, dark_mask(tif))
    return choose(tif.name, *dark_counts(tif), lambda rect: edge_shares(tif, rect))


def check(tif: Path, fallback: Path | None = None) -> None:
    """Raise MissingOutline unless this sheet has a usable frame outline or a fallback shape."""
    shape, how = settle(tif)
    if shape is None and fallback is None:
        raise charts.MissingOutline(f"{tif.name}: {how}, and there is no fallback outline")


def cutline(tif: Path, fallback: Path | None, out: Path) -> Path:
    """The outline to trim this sheet with: its own frame, or the fallback shape if the frame is not found."""
    shape, how = settle(tif)
    if shape:
        print(f"outline {tif.name}: {how} {shape}", flush=True)
        write_cutline(tif, shape, out)
        return out
    if fallback is None:
        raise charts.MissingOutline(f"{tif.name}: {how}, and there is no fallback outline")
    print(f"outline {tif.name}: FALLBACK to {fallback.name} ({how})", flush=True)
    FALLBACKS.append(tif.name)
    return fallback
