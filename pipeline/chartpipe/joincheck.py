"""Measure and picture the joins between the sheets of a built layer. A tool; the build does not call it."""
import math
import sys
from pathlib import Path

from . import build, joins
from .joins import DIFFERS

# Width and height of a crop, in pixels.
SHOT = (1600, 1000)


def touching(mask):
    """Pixels with a true neighbour above, below, left or right."""
    import numpy as np
    out = np.zeros_like(mask)
    out[1:] |= mask[:-1]
    out[:-1] |= mask[1:]
    out[:, 1:] |= mask[:, :-1]
    out[:, :-1] |= mask[:, 1:]
    return out


def join_share(shown, first: int, second: int, a, b) -> dict:
    """How much of the join between two sheets runs through pixels where they differ.

    a and b are (4, h, w) windows of the two sheets. A trimmed sheet keeps its colours under the
    cleared alpha, so a pixel counts as present when any of its four bands is non-zero."""
    one, two = shown == first, shown == second
    edge = ((one & touching(two)) | (two & touching(one))) & a.any(0) & b.any(0)
    apart = joins.difference(a[:3], b[:3])[edge]
    if not apart.size:
        return {"pixels": 0, "differ": 0.0, "mean": 0.0}
    return {"pixels": int(apart.size), "differ": float((apart > DIFFERS).mean()), "mean": float(apart.mean())}


def owners(sheets: list[Path], x: int, y: int, w: int, h: int):
    """Index of the sheet shown at each pixel of a window on the layer grid; -1 where there is none."""
    import numpy as np
    from osgeo import gdal
    gdal.UseExceptions()
    shown = np.full((h, w), -1, np.int16)
    for index, path in enumerate(sheets):
        data = gdal.Open(str(path))
        ox, oy = joins.origin(data)
        shown[joins.window(data, x - ox, y - oy, w, h, [4])[0] > 0] = index
    return shown


def measure(sheets: list[Path], first: int, second: int) -> dict:
    """The join share for two sheets of a stack given bottom first, over the box both rasters cover."""
    from osgeo import gdal
    gdal.UseExceptions()
    one, two = gdal.Open(str(sheets[first])), gdal.Open(str(sheets[second]))
    (ax, ay), (bx, by) = joins.origin(one), joins.origin(two)
    # One pixel wider than the shared box, so a join on a raster's own edge is seen.
    x0, y0 = max(ax, bx) - 1, max(ay, by) - 1
    x1 = min(ax + one.RasterXSize, bx + two.RasterXSize) + 1
    y1 = min(ay + one.RasterYSize, by + two.RasterYSize) + 1
    if x1 - x0 <= 2 or y1 - y0 <= 2:
        return {"pixels": 0, "differ": 0.0, "mean": 0.0}
    w, h = x1 - x0, y1 - y0
    return join_share(owners(sheets, x0, y0, w, h), first, second,
                      joins.window(one, x0 - ax, y0 - ay, w, h, [1, 2, 3, 4]),
                      joins.window(two, x0 - bx, y0 - by, w, h, [1, 2, 3, 4]))


def save(pixels, out: Path) -> None:
    from osgeo import gdal
    mem = gdal.GetDriverByName("MEM").Create("", pixels.shape[2], pixels.shape[1], 3, gdal.GDT_Byte)
    mem.WriteArray(pixels)
    gdal.GetDriverByName("PNG").CreateCopy(str(out), mem)


def shot(sheets: list[Path], vrt: Path, lon: float, lat: float, plain: Path, lined: Path) -> None:
    """Two crops of the mosaic centred on a point: as built, and with every join painted magenta."""
    import numpy as np
    from osgeo import gdal
    gdal.UseExceptions()
    data = gdal.Open(str(vrt))
    res = data.GetGeoTransform()[1]
    ox, oy = joins.origin(data)
    x = round(lon * 20037508.342789244 / 180 / res) - SHOT[0] // 2
    y = round(-math.log(math.tan(math.radians(45 + lat / 2))) * 6378137 / res) - SHOT[1] // 2
    pixels = joins.window(data, x - ox, y - oy, *SHOT, [1, 2, 3])
    save(pixels, plain)
    shown = owners(sheets, x, y, *SHOT)
    line = np.zeros(shown.shape, bool)
    line[:, 1:] |= shown[:, 1:] != shown[:, :-1]
    line[1:] |= shown[1:] != shown[:-1]
    for band, value in enumerate((255, 0, 255)):
        pixels[band][line] = value
    save(pixels, lined)


def main(argv: list[str]) -> int:
    command, folder, prefix = argv[0], Path(argv[1]), argv[2]
    sheets = sorted(folder.glob(f"{prefix}_*.tif"))
    if command == "measure":
        for first in range(len(sheets)):
            for second in range(first + 1, len(sheets)):
                got = measure(sheets, first, second)
                if got["pixels"]:
                    print(f"{sheets[first].stem} | {sheets[second].stem}: {got['pixels']} px, "
                          f"differ {got['differ']:.1%}, mean {got['mean']:.1f}", flush=True)
        return 0
    out, suffix = Path(argv[3]), argv[4]
    out.mkdir(parents=True, exist_ok=True)
    vrt = out / f"{prefix}-{suffix}.vrt"
    build.mosaic(sheets, vrt)
    for spot in argv[5:]:
        name, place = spot.split("=")
        lon, lat = (float(value) for value in place.split(","))
        shot(sheets, vrt, lon, lat, out / f"{name}-{suffix}.png", out / f"{name}-{suffix}-line.png")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
