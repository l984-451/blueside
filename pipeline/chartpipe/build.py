import hashlib
import json
import math
import os
import shutil
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from pathlib import Path

Z12 = 38.218514142588134
Z13 = Z12 / 2
Z11 = Z12 * 2
# Part of every warp cache key. Bump it whenever warp() would write different pixels.
WARP_VERSION = "1"
# Cached warps unused this long are deleted.
CACHE_DAYS = 60
# Seconds spent per (layer, stage) in this run, for the closing summary.
STAGES: dict[tuple[str, str], float] = {}


def run(cmd: list) -> None:
    subprocess.run([str(part) for part in cmd], check=True)


def info(path: Path) -> dict:
    result = subprocess.run(["gdalinfo", "-json", str(path)], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def is_paletted(source: dict) -> bool:
    return "colorTable" in source["bands"][0]


def pixel_size(source: dict) -> float:
    """Ground size of one source pixel, in the units of the chart's own projection."""
    transform = source["geoTransform"]
    return math.hypot(transform[1], transform[4])


def coarsest_first(sizes: dict[Path, float]) -> list[Path]:
    """Stacking order for sheets of mixed scale: coarse ones underneath, name order within one scale."""
    return sorted(sizes, key=lambda path: (-round(sizes[path], 1), path.name))


@contextmanager
def stage(layer: str, name: str):
    """Time one step, log it and add it to the run's summary."""
    start = time.monotonic()
    try:
        yield
    finally:
        took = time.monotonic() - start
        STAGES[layer, name] = STAGES.get((layer, name), 0.0) + took
        print(f"stage {layer} {name}: {took:.0f} s", flush=True)


def stage_summary() -> str:
    rows = [f"{layer:<9} {name:<9} {took:>8.0f} s" for (layer, name), took in STAGES.items()]
    return "\n".join([f"{'layer':<9} {'stage':<9} {'time':>10}", *rows])


def cgroup_cpus() -> int:
    """CPUs this container may use: its quota if it has one, else every core."""
    try:
        quota, period = Path("/sys/fs/cgroup/cpu.max").read_text().split()
        if quota != "max":
            return max(1, int(quota) // int(period))
    except (OSError, ValueError):
        pass
    return os.cpu_count() or 1


def cgroup_memory_gb() -> int:
    try:
        limit = Path("/sys/fs/cgroup/memory.max").read_text().strip()
        if limit != "max":
            return int(limit) // 2**30
    except (OSError, ValueError):
        pass
    return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") // 2**30


def pool_size(cpus: int | None = None, memory_gb: int | None = None) -> tuple[int, int]:
    """Concurrent warps and threads for each: 3 CPUs and 4 GB a warp (2 GB -wm plus GDAL cache)."""
    cpus = cpus or cgroup_cpus()
    memory_gb = memory_gb or cgroup_memory_gb()
    workers = max(1, min(cpus // 3, memory_gb // 4))
    return workers, max(1, cpus // workers)


def file_sha(path: Path) -> str:
    with open(path, "rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def outline_sha(path: Path) -> str:
    """Hash of an outline's shapes and projection, so a rewritten but equal GeoPackage still matches."""
    from osgeo import ogr
    ogr.UseExceptions()
    digest = hashlib.sha256()
    for layer in ogr.Open(str(path)):
        srs = layer.GetSpatialRef()
        digest.update((srs.ExportToWkt() if srs else "").encode())
        for feature in layer:
            digest.update(feature.GetGeometryRef().ExportToIsoWkb())
    return digest.hexdigest()


def place(src: Path, dst: Path) -> None:
    """Hard link src at dst, or copy it across file systems. Trimming replaces sheets, never edits them."""
    dst.unlink(missing_ok=True)
    try:
        os.link(src, dst)
    except OSError:
        shutil.copyfile(src, dst)


def cached_warp(src_tif: Path, outline: Path, out_tif: Path, res: float, cache: Path, threads: int = 0) -> bool:
    """warp(), reusing an earlier result for the same source, outline, resolution and code. True on a hit."""
    from osgeo import gdal
    key = hashlib.sha256(" ".join([file_sha(src_tif), outline_sha(outline), repr(res), WARP_VERSION,
                                    gdal.__version__]).encode()).hexdigest()
    hit, seal = cache / f"{key}.tif", cache / f"{key}.sha256"
    if hit.exists() and seal.exists() and seal.read_text() == file_sha(hit):
        for path in (hit, seal):
            os.utime(path)
        place(hit, out_tif)
        return True
    warp(src_tif, outline, out_tif, res, threads)
    cache.mkdir(parents=True, exist_ok=True)
    # Sheet first, then its seal: a run killed in between leaves a mismatch that is rebuilt.
    part = cache / f"{key}.part"
    place(out_tif, part)
    os.replace(part, hit)
    seal.with_suffix(".part").write_text(file_sha(out_tif))
    os.replace(seal.with_suffix(".part"), seal)
    return False


def prune_cache(cache: Path, days: int = CACHE_DAYS) -> None:
    cutoff = time.time() - days * 86400
    for path in cache.glob("*"):
        if path.stat().st_mtime < cutoff:
            path.unlink(missing_ok=True)


def warp_all(jobs: list[tuple[Path, Path, Path]], res: float, cache: Path | None = None,
             size: tuple[int, int] | None = None) -> list[Path]:
    """Warp (source, outline, out) jobs concurrently. Returns the outs in job order."""
    workers, threads = size or pool_size()

    def one(job):
        src, outline, out = job
        if cache is None:
            warp(src, outline, out, res, threads)
            return False
        return cached_warp(src, outline, out, res, cache, threads)

    with ThreadPoolExecutor(workers) as pool:
        hits = list(pool.map(one, jobs))
    if cache is not None:
        print(f"warp cache: {sum(hits)} of {len(jobs)} sheets reused", flush=True)
    return [out for _, _, out in jobs]


def warp(src_tif: Path, outline: Path, out_tif: Path, res: float, threads: int = 0) -> None:
    """Trim a chart to its outline and reproject it onto the tile pixel grid."""
    src = src_tif
    if is_paletted(info(src_tif)):
        # Resampling palette indices gives garbage, so expand to colour first.
        src = out_tif.with_suffix(".rgb.vrt")
        run(["gdal_translate", "-q", "-of", "VRT", "-expand", "rgb", src_tif, src])
    run(["gdalwarp", "-q", "-overwrite", "-t_srs", "EPSG:3857", "-tr", res, res, "-tap",
         "-r", "lanczos", "-cutline", outline, "-crop_to_cutline", "-dstalpha",
         "-multi", "-wo", f"NUM_THREADS={threads or 'ALL_CPUS'}", "-wm", "2048",
         "--config", "GDAL_NUM_THREADS", threads or "ALL_CPUS",
         "-co", "TILED=YES", "-co", "COMPRESS=ZSTD", "-co", "PREDICTOR=2",
         "-co", "BLOCKXSIZE=512", "-co", "BLOCKYSIZE=512", src, out_tif])
    # Three colours plus alpha. Anything else would tile without an error and look wrong.
    bands = len(info(out_tif)["bands"])
    if bands != 4:
        raise ValueError(f"{out_tif.name}: {bands} bands after trimming, expected 4")


def mosaic(tifs: list[Path], out_vrt: Path) -> None:
    """Stitch charts in the order given. Later files win overlaps."""
    run(["gdalbuildvrt", "-q", "-overwrite", out_vrt, *tifs])


def tile(src: Path, out_dir: Path, min_zoom: int, max_zoom: int) -> None:
    run(["gdal", "raster", "tile", "-q", "--format", "WEBP", "--co", "QUALITY=75",
         "--min-zoom", min_zoom, "--max-zoom", max_zoom, "--skip-blank", "--webviewer", "none",
         "-r", "average", "--overview-resampling", "average", src, out_dir])
