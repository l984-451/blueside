import hashlib
import json
import sqlite3
import subprocess
from pathlib import Path

from .build import run

STATE_CODES = (
    "AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ "
    "NM NY NC ND OH OK OR PA PR RI SC SD TN TX UT VT VA WA WV WI WY"
).split()


class BadPack(Exception):
    pass


def tiles_to_mbtiles(tiles_dir: Path, out: Path, name: str) -> int:
    """Pack a z/x/y.webp folder into MBTiles."""
    out.unlink(missing_ok=True)
    db = sqlite3.connect(out)
    db.executescript(
        "CREATE TABLE metadata (name TEXT, value TEXT);"
        "CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);"
        "CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);"
    )
    zooms, count = set(), 0
    for path in tiles_dir.glob("*/*/*.webp"):
        z, x, y = int(path.parts[-3]), int(path.parts[-2]), int(path.stem)
        # MBTiles rows count from the south.
        db.execute("INSERT INTO tiles VALUES (?,?,?,?)", (z, x, 2**z - 1 - y, path.read_bytes()))
        zooms.add(z)
        count += 1
    if count == 0:
        db.close()
        out.unlink()
        raise BadPack(f"no tiles in {tiles_dir}")
    meta = {"name": name, "format": "webp", "type": "baselayer", "minzoom": min(zooms), "maxzoom": max(zooms)}
    db.executemany("INSERT INTO metadata VALUES (?,?)", [(k, str(v)) for k, v in meta.items()])
    db.commit()
    db.close()
    return count


def to_pmtiles(mbtiles: Path, out: Path) -> None:
    # Scratch data goes beside the output, on the mounted volume.
    run(["pmtiles", "convert", f"--tmpdir={out.parent}", mbtiles, out])


def zoom_range(pmtiles: Path) -> tuple[int, int]:
    header = json.loads(subprocess.run(["pmtiles", "show", "--header-json", str(pmtiles)],
                                       check=True, capture_output=True, text=True).stdout)
    return header["minzoom"], header["maxzoom"]


def check_zooms(pmtiles: Path, expected: tuple[int, int]) -> None:
    # go-pmtiles can write a wrong max zoom when many tiles are identical.
    found = zoom_range(pmtiles)
    if found != expected:
        raise BadPack(f"{pmtiles.name}: zoom range {found}, expected {expected}")


def extract_overview(national: Path, out: Path, max_zoom: int) -> None:
    run(["pmtiles", "extract", national, out, f"--maxzoom={max_zoom}"])


def extract_state(national: Path | str, state_code: str, states_shp: Path, out: Path, work: Path, top_zoom: int) -> bool:
    """Every tile touching the state. Returns False and leaves no file if it has none at the top zoom."""
    region = work / f"{state_code}.geojson"
    run(["ogr2ogr", "-f", "GeoJSON", "-t_srs", "EPSG:4326", "-where", f"STUSPS='{state_code}'", region, states_shp])
    # national may be a URL; the extract then reads it by range requests.
    run(["pmtiles", "extract", national, out, f"--region={region}", f"--maxzoom={top_zoom}", "--download-threads=8"])
    # Low-zoom tiles span many states, so only top-zoom tiles show the state is covered.
    probe = work / f"{state_code}.probe.pmtiles"
    run(["pmtiles", "extract", out, probe, f"--minzoom={top_zoom}"])
    with open(probe, "rb") as handle:
        handle.seek(64)  # PMTiles v3 header: tile data length, uint64 little-endian
        empty = int.from_bytes(handle.read(8), "little") == 0
    probe.unlink()
    if empty:
        out.unlink()
    return not empty


def missing_states(packs, layer="vfr", optional=("AK", "HI", "PR")) -> list[str]:
    """State codes that must have a pack for the layer and have none."""
    return sorted(set(STATE_CODES) - set(optional) - {p["region"] for p in packs if p["layer"] == layer})


def describe(pmtiles: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    with open(pmtiles, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return pmtiles.stat().st_size, digest.hexdigest()
