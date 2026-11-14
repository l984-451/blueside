"""Move the join between overlapping sheets onto pixels where the sheets agree."""
import os
import resource
import shutil
import sys
import time
from pathlib import Path

from . import build

# Seams are found on cells of this many pixels a side.
FACTOR = 4
# A colour difference above this is visible as a step at a join.
DIFFERS = 32
# Cells. A shallower or shorter overlap keeps its fixed outline.
MIN_DEPTH = 8
MIN_RUN = 16
# Mean colour difference along the best path above which two sheets do not show the same ground.
MAX_MEAN = 120.0
BLOCKED = 1e9
# Named by the side that is on top after 0, 1, 2 and 3 quarter turns anticlockwise.
SIDES = ("north", "east", "south", "west")
# Pixels. Alpha is rewritten in blocks of this size, the block size of the warped sheets.
BLOCK = 512
# Sheets whose join step failed and that kept their fixed outline, for the end-of-run report.
FAILED: list[str] = []


def difference(a, b):
    """Largest channel difference per pixel between two (3, h, w) colour arrays."""
    import numpy as np
    return np.abs(a.astype(np.int16) - b.astype(np.int16)).max(0)


def origin(data) -> tuple[int, int]:
    """Column and row of a raster's top-left pixel on the layer's pixel grid; rows grow southward."""
    transform = data.GetGeoTransform()
    return round(transform[0] / transform[1]), round(-transform[3] / transform[1])


def window(data, x: int, y: int, w: int, h: int, bands: list[int]):
    """Bands of a raster for a window in its own pixels; zero where the window leaves the raster."""
    import numpy as np
    out = np.zeros((len(bands), h, w), np.uint8)
    x0, y0, x1, y1 = max(x, 0), max(y, 0), min(x + w, data.RasterXSize), min(y + h, data.RasterYSize)
    if x1 > x0 and y1 > y0:
        got = data.ReadAsArray(x0, y0, x1 - x0, y1 - y0, band_list=bands)
        out[:, y0 - y:y1 - y, x0 - x:x1 - x] = np.asarray(got).reshape(len(bands), y1 - y0, x1 - x0)
    return out


def spread(cells):
    """Each cell takes the largest value among itself and its eight neighbours."""
    import numpy as np
    padded = np.pad(cells, 1, mode="edge")
    height, width = cells.shape
    out = cells.copy()
    for dy in range(3):
        for dx in range(3):
            np.maximum(out, padded[dy:dy + height, dx:dx + width], out=out)
    return out


def runs(flags, part=0) -> list[tuple[int, int]]:
    """First index and end (exclusive) of each stretch of true values; a change in `part` also ends a stretch."""
    import numpy as np
    marks = np.concatenate(([0], np.where(flags, part + 1, 0), [0]))
    change, real = marks[1:] != marks[:-1], marks[1:-1] > 0
    return [(int(first), int(last) + 1) for first, last in
            zip(np.flatnonzero(change[:-1] & real), np.flatnonzero(change[1:] & real))]


def closing(column, own, beyond, bare):
    """Cost of the straight joins left at the end of a stretch, for a path that ends on each row.

    Above the path where the sheet carries on sideways; below it where only the mosaic beneath does."""
    import numpy as np
    step = np.where(column < BLOCKED, column, 0.0)
    # The sheet's own edge is there already: it costs what its cells differ by, not what lies beside them.
    above, below = np.where(beyond, step, 0.0), np.where(bare & (column < BLOCKED), own, 0.0)
    return np.cumsum(above) - above + below.sum() - np.cumsum(below)


def top_drop(cost, apart, covered, beneath, seam):
    """Cells to clear along the top side: the overlap above the cheapest left-to-right path through it.

    seam is what each cell costs to clear. Returns the cells and one log line per stretch of overlap."""
    import numpy as np
    height, width = covered.shape
    started = np.maximum.accumulate(covered, axis=0)
    band = started & ~np.maximum.accumulate(started & ~beneath, axis=0)
    band &= np.cumsum(band, axis=0, dtype=np.int32) <= height // 3
    # Where a neighbouring side cuts across this one the sheet's edge jumps from column to column;
    # a column with no neighbour at its own level is that side's.
    has, first = covered.any(0), covered.argmax(0)
    level = (np.abs(np.diff(first)) <= 1) & has[1:] & has[:-1]
    band &= np.concatenate(([False], level)) | np.concatenate((level, [False]))
    depth = band.sum(0)
    drop, notes = np.zeros(band.shape, bool), []
    for x0, x1 in runs((depth > 0) & (depth < MIN_DEPTH)):
        notes.append(f"{x0}-{x1}: FIXED, overlap too thin")
    # A path cannot follow a jump in the sheet's edge, so a stretch ends there.
    for x0, x1 in runs(depth >= MIN_DEPTH, np.concatenate(([0], np.cumsum(~level)))):
        if x1 - x0 < MIN_RUN:
            notes.append(f"{x0}-{x1}: FIXED, overlap too short")
            continue
        # Deeper than long. Where the sheet's edge ends there it is the end of the overlap along
        # a neighbouring side, which that side moves; away from a corner no side does.
        if np.median(depth[x0:x1]) > x1 - x0:
            corner = x0 == 0 or x1 == width or not (level[x0 - 1] and level[x1 - 1])
            notes.append(f"{x0}-{x1}: unchanged, the end of a neighbouring side's overlap" if corner
                         else f"{x0}-{x1}: FIXED, overlap deeper than it is long")
            continue
        rows = int(np.flatnonzero(band[:, x0:x1].any(1))[-1]) + 1
        inside = band[:rows, x0:x1] & covered[:rows, x0:x1]
        c = np.where(inside, cost[:rows, x0:x1], BLOCKED)
        # Past each end of the stretch: where the sheet carries on, and where only the mosaic beneath does.
        before, after = ((covered[:rows, x], beneath[:rows, x] & ~covered[:rows, x]) if 0 <= x < width
                         else (np.zeros(rows, bool),) * 2 for x in (x0 - 1, x1))
        # A path pays for its own cells and for every cell cleared above them.
        priced = np.cumsum(seam[:rows, x0:x1], 0, dtype=np.float32)
        priced -= seam[:rows, x0:x1]
        priced += c
        total = priced[:, 0] + closing(c[:, 0], apart[:rows, x0].astype(float), *before)
        back = np.zeros(c.shape, np.int8)
        for x in range(1, x1 - x0):
            options = np.stack([np.concatenate(([np.inf], total[:-1])), total,
                                np.concatenate((total[1:], [np.inf]))])
            back[:, x] = options.argmin(0) - 1
            total = priced[:, x] + options.min(0)
        y = int((total + closing(c[:, -1], apart[:rows, x1 - 1].astype(float), *after)).argmin())
        path = [y]
        for x in range(x1 - x0 - 1, 0, -1):
            y += int(back[y, x])
            path.append(y)
        path = np.array(path[::-1])
        along = c[path, np.arange(x1 - x0)]
        if along.max() >= BLOCKED:
            notes.append(f"{x0}-{x1}: FIXED, no path through the overlap")
        elif along.mean() > MAX_MEAN:
            notes.append(f"{x0}-{x1}: FIXED, sheets differ by {along.mean():.0f} on the best path")
        else:
            clear = band[:rows, x0:x1] & (np.arange(rows)[:, None] < path[None, :])
            drop[:rows, x0:x1] = clear
            what = "moved" if clear.any() else "unchanged"
            share = float((apart[path, np.arange(x0, x1)] > DIFFERS).mean())
            notes.append(f"{x0}-{x1}: {what}, difference {along.mean():.1f} on the path, "
                         f"{share:.0%} of it on differing cells")
    return drop, notes


def find_drop(sheet, under, owner=None):
    """Cells of a sheet to clear so that its joins with the mosaic beneath run where the two agree.

    Both are (4, h, w) arrays on one cell grid; owner says which sheet of the mosaic each cell shows.
    Returns the cells and log lines."""
    import numpy as np
    covered = sheet[3] > 0
    # A reduced cell is marked opaque as soon as one of its pixels is, so shrink by a cell before trusting it.
    beneath = ~spread(under[3] < 255)
    apart = np.where(covered & beneath, difference(sheet[:3], under[:3]), 0).astype(np.uint8)
    # The path keeps a cell away from ink: each cell costs the largest difference among its neighbours.
    cost = spread(apart)
    # Clearing the sheet over a join in the mosaic shows that join: it costs what the sheet differs by there.
    edge = np.zeros(covered.shape, bool)
    if owner is not None:
        for cells, mark in ((owner, edge), (owner.T, edge.T)):
            meet = (cells[1:] != cells[:-1]) & (cells[1:] >= 0) & (cells[:-1] >= 0)
            mark[1:] |= meet
            mark[:-1] |= meet
    seam = cost * edge
    drop, notes = np.zeros(covered.shape, bool), []
    for turns, side in enumerate(SIDES):
        part, said = top_drop(*(np.rot90(cells, turns) for cells in (cost, apart, covered, beneath, seam)))
        drop |= np.rot90(part, -turns)
        notes += [f"{side} {line}" for line in said]
    return drop, notes


def cell_box(transform, width: int, height: int):
    """A raster's extent grown outward to whole cells, as (west, south, east, north), then the pixels added left and top."""
    res = transform[1]
    x, y = round(transform[0] / res), round(-transform[3] / res)
    west, north = x // FACTOR * FACTOR, y // FACTOR * FACTOR
    east, south = -(-(x + width) // FACTOR) * FACTOR, -(-(y + height) // FACTOR) * FACTOR
    return (west * res, -south * res, east * res, -north * res), x - west, y - north


def reduced(src: Path, out: Path, box, res: float):
    """A (4, h, w) array of src averaged onto cells of FACTOR pixels inside box."""
    from osgeo import gdal
    gdal.UseExceptions()
    build.run(["gdalwarp", "-q", "-overwrite", "-te", *box, "-tr", res * FACTOR, res * FACTOR,
               "-r", "average", src, out])
    return gdal.Open(str(out)).ReadAsArray()


def owners(lower: list[Path], scratch: Path, box, res: float):
    """Which of the sheets beneath shows in each cell of box, -1 for none; None when fewer than two reach the box."""
    import numpy as np
    from osgeo import gdal
    west, south, east, north = box
    near = []
    for index, path in enumerate(lower):
        data = gdal.Open(str(path))
        x, step, _, y, _, _ = data.GetGeoTransform()
        if x < east and x + step * data.RasterXSize > west and y > south and y - step * data.RasterYSize < north:
            near.append((index, path))
    if len(near) < 2:
        return None
    owner = None
    for index, path in near:
        alpha = reduced(path, scratch / "lower.tif", box, res)[3]
        owner = np.full(alpha.shape, -1, np.int16) if owner is None else owner
        owner[alpha > 0] = index
    return owner


def block_mask(drop, py: int, px: int, rows: int, cols: int):
    """The cell mask as pixels, for the block that starts py rows and px columns into the cell grid."""
    import numpy as np
    cy, cx = py // FACTOR, px // FACTOR
    cells = drop[cy:(py + rows - 1) // FACTOR + 1, cx:(px + cols - 1) // FACTOR + 1]
    full = np.repeat(np.repeat(cells, FACTOR, 0), FACTOR, 1)
    return full[py - cy * FACTOR:py - cy * FACTOR + rows, px - cx * FACTOR:px - cx * FACTOR + cols]


def trim(sheet: Path, lower: list[Path], under_vrt: Path, scratch: Path) -> list[str]:
    """Clear the alpha of one warped sheet where the sheets beneath it, mosaicked in under_vrt, should show.

    Returns log lines."""
    from osgeo import gdal
    gdal.UseExceptions()
    data = gdal.Open(str(sheet))
    transform, width, height = data.GetGeoTransform(), data.RasterXSize, data.RasterYSize
    data.Close()
    box, left, top = cell_box(transform, width, height)
    drop, notes = find_drop(reduced(sheet, scratch / "sheet.tif", box, transform[1]),
                            reduced(under_vrt, scratch / "under.tif", box, transform[1]),
                            owners(lower, scratch, box, transform[1]))
    if not drop.any():
        return notes
    # Trimmed on a copy that takes the sheet's place only once it is closed: a failed write leaves the sheet whole.
    part = scratch / "part.tif"
    shutil.copyfile(sheet, part)
    data, under = gdal.Open(str(part), gdal.GA_Update), gdal.Open(str(under_vrt))
    (sx, sy), (ux, uy) = origin(data), origin(under)
    band, kept = data.GetRasterBand(4), 0
    for y in range(0, height, BLOCK):
        for x in range(0, width, BLOCK):
            rows, cols = min(BLOCK, height - y), min(BLOCK, width - x)
            mask = block_mask(drop, y + top, x + left, rows, cols)
            if not mask.any():
                continue
            alpha = band.ReadAsArray(x, y, cols, rows)
            mask = mask & (alpha > 0)
            # A pixel with no chart beneath it stays; checked on the real pixels, not on the reduced copy.
            solid = window(under, x + sx - ux, y + sy - uy, cols, rows, [4])[0] == 255
            kept += int((mask & ~solid).sum())
            mask &= solid
            if mask.any():
                alpha[mask] = 0
                band.WriteArray(alpha, x, y)
    band = None
    data.Close()
    os.replace(part, sheet)
    return notes + ([f"kept {kept} pixels that have no chart beneath them"] if kept else [])


def trim_layer(order: list[Path], work: Path) -> None:
    """Trim each sheet against the mosaic of the sheets stacked beneath it, bottom first."""
    start, moved, fixed, failed = time.monotonic(), 0, 0, 0
    scratch = work / "joins"
    scratch.mkdir(exist_ok=True)
    for index, sheet in enumerate(order[1:], 1):
        try:
            build.mosaic(order[:index], scratch / "under.vrt")
            notes = trim(sheet, order[:index], scratch / "under.vrt", scratch)
        except Exception as error:
            # Joins are looks only: a sheet that cannot be trimmed keeps its fixed outline and the build goes on.
            notes = [f"all sides: FIXED, {type(error).__name__}: {error}"]
            FAILED.append(sheet.stem)
            failed += 1
        for line in notes:
            print(f"join {sheet.stem} {line}", flush=True)
            moved += "moved" in line
            fixed += "FIXED" in line
    shutil.rmtree(scratch, ignore_errors=True)
    # The peak is reported in bytes on macOS and in kilobytes on Linux.
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (2 ** 20 if sys.platform == "darwin" else 2 ** 10)
    print(f"joins: {moved} moved, {fixed} left on the fixed outline, {failed} sheets failed, "
          f"{time.monotonic() - start:.0f} s, {peak:.0f} MB at peak", flush=True)
