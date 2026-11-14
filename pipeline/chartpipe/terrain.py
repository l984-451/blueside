"""Terrain base: elevation tint under hillshade, from the Mapzen terrain tiles on AWS (public, no key)."""
import math
import os
import shutil
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import build, faa, pack

LAYER = "terrain"
DEM = "https://elevation-tiles-prod.s3.amazonaws.com/geotiff/{z}/{x}/{y}.tif"
# 512 px source tiles at zoom 10 have 76 m pixels, the detail of 256 px tiles at zoom 11, the pack's top.
DEM_ZOOM = 10
ZOOMS = (0, 11)
# Part of the finished pack's cache key. Bump it whenever the look changes.
VERSION = "1"
# Metres to colour, sectional style: water blue, greens low, tans and browns, white peaks.
RAMP = """nv 0 0 0 0
-11000 170 205 232
-0.1 170 205 232
0 176 207 158
150 196 219 160
300 216 227 168
600 232 228 176
900 234 214 160
1200 222 192 140
1800 200 166 122
2400 178 146 112
3000 196 182 170
3600 232 230 226
4500 255 255 255
"""
# Relief drawn this many times steeper than it is, so the low hills of flat states still read.
EXAGGERATION = 2


def tile_range(west: float, south: float, east: float, north: float, zoom: int) -> tuple[range, range]:
    n = 2 ** zoom

    def y(lat):
        lat = math.radians(max(min(lat, 85.05), -85.05))
        return int((1 - math.log(math.tan(lat) + 1 / math.cos(lat)) / math.pi) / 2 * n)
    x0, x1 = (int((lon + 180) / 360 * n) for lon in (west, east))
    return range(max(x0, 0), min(x1, n - 1) + 1), range(max(y(north), 0), min(y(south), n - 1) + 1)


def state_tiles(states_shp: Path, code: str, pad: int = 1) -> set[tuple[int, int]]:
    """Source tiles over every part of a state, with a margin so relief at its edge is whole."""
    from osgeo import ogr
    ogr.UseExceptions()
    source = ogr.Open(str(states_shp))
    layer = source.GetLayer()
    layer.SetAttributeFilter(f"STUSPS = '{code}'")
    n = 2 ** DEM_ZOOM
    found = set()
    for feature in layer:
        geometry = feature.GetGeometryRef()
        # Parts one at a time: Alaska's islands past 180 would otherwise stretch its box round the world.
        parts = [geometry.GetGeometryRef(i) for i in range(geometry.GetGeometryCount())] \
            if geometry.GetGeometryType() in (ogr.wkbMultiPolygon, ogr.wkbMultiPolygon25D) else [geometry]
        for part in parts:
            west, east, south, north = part.GetEnvelope()
            xs, ys = tile_range(west, south, east, north, DEM_ZOOM)
            found |= {(x, y) for x in range(xs.start - pad, xs.stop + pad) for y in range(ys.start - pad, ys.stop + pad)
                      if 0 <= x < n and 0 <= y < n}
    return found


def fetch(tiles: set[tuple[int, int]], cache: Path) -> list[Path]:
    """Source tiles, downloaded once into cache: elevation does not change between chart cycles."""
    def one(tile):
        x, y = tile
        path = cache / str(DEM_ZOOM) / str(x) / f"{y}.tif"
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            part = path.with_suffix(".part")
            # Thousands of requests per state: a dropped handshake gets tried again.
            for attempt in range(4):
                try:
                    part.write_bytes(faa.fetch(DEM.format(z=DEM_ZOOM, x=x, y=y)))
                    break
                except OSError:
                    if attempt == 3:
                        raise
                    time.sleep(2 ** attempt)
            os.replace(part, path)
        return path
    with ThreadPoolExecutor(32) as pool:
        return list(pool.map(one, sorted(tiles)))


def relief_scale(dems: list[Path]) -> float:
    """Ground metres per Mercator metre at the middle row, over the exaggeration."""
    rows = sorted(int(d.stem) for d in dems)
    y = (rows[0] + rows[-1] + 1) / 2 / 2 ** DEM_ZOOM
    return math.cos(math.atan(math.sinh(math.pi * (1 - 2 * y)))) / EXAGGERATION


def render(dems: list[Path], tiles: Path, work: Path) -> None:
    """Tint, shade and cut into z/x/y.webp. Each side of 180 is drawn alone, the west last so it keeps zoom 0."""
    ramp = work / "terrain-ramp.txt"
    ramp.write_text(RAMP)
    scale = round(relief_scale(dems), 4)
    half = 2 ** (DEM_ZOOM - 1)
    sides = [[d for d in dems if int(d.parent.name) >= half], [d for d in dems if int(d.parent.name) < half]]
    for index, side in enumerate(s for s in sides if s):
        stem = work / f"terrain-{index}"
        vrt, shade, map_ = (stem.with_suffix(s) for s in (".vrt", ".shade.json", ".map.json"))
        build.run(["gdalbuildvrt", "-q", "-overwrite", vrt, *side])
        # Streamed steps: nothing is written at full size before tiling.
        build.run(["gdal", "raster", "hillshade", "-q", "--overwrite", "-f", "GDALG", "--variant", "Igor",
                   "--xscale", scale, "--yscale", scale, vrt, shade])
        # Gaps colour black, which no shaded tint reaches, and nodata 0 makes them clear when tiled.
        # One pipeline: blend drops an alpha band, and nodata-to-alpha on a streamed file crashes GDAL 3.13.
        build.run(["gdal", "raster", "pipeline", "-q", "read", vrt, "!", "color-map", "--color-map", ramp,
                   "!", "blend", "--overlay", shade, "--operator", "multiply", "--opacity", "75",
                   "!", "edit", "--nodata", "0", "!", "write", "-f", "GDALG", "--overwrite", map_])
        build.tile(map_, tiles, *ZOOMS)


def state_pack(code: str, states_shp: Path, out: Path, work: Path, cache: Path) -> dict | None:
    """One state's pack, cut to the state like the chart packs. Kept in cache and reused by later cycles."""
    kept = cache / f"v{VERSION}" / f"{code}.pmtiles"
    if not kept.exists():
        here = work / f"terrain-{code}"
        here.mkdir(parents=True, exist_ok=True)
        tiles = state_tiles(states_shp, code)
        if not tiles:
            return None
        render(fetch(tiles, cache / "dem"), here / "tiles", here)
        pack.tiles_to_mbtiles(here / "tiles", here / "box.mbtiles", LAYER)
        pack.to_pmtiles(here / "box.mbtiles", here / "box.pmtiles")
        cut = here / "cut.pmtiles"
        if not pack.extract_state(here / "box.pmtiles", code, states_shp, cut, here, ZOOMS[1]):
            return None
        pack.check_zooms(cut, ZOOMS)
        kept.parent.mkdir(parents=True, exist_ok=True)
        os.replace(cut, kept)
        shutil.rmtree(here)
    target = out / LAYER / f"{code}.pmtiles"
    target.parent.mkdir(parents=True, exist_ok=True)
    build.place(kept, target)
    size, sha = pack.describe(target)
    return {"layer": LAYER, "region": code, "bytes": size, "sha256": sha}
