import re
from pathlib import Path

# Images left out on purpose. Every entry needs a reason.
SKIP: dict[str, str] = {
    "Western Aleutian Islands East SEC.tif": "crosses the 180 degree meridian, untested",
    "Western Aleutian Islands West SEC.tif": "crosses the 180 degree meridian, untested",
    "Honolulu Inset SEC.tif": "inset outside every state pack",
    "Mariana Islands Inset SEC.tif": "inset outside every state pack",
    "Samoan Islands Inset SEC.tif": "inset outside every state pack",
    "ENR_L23_WILM_INSET.tif": "inset image, left out of the enroute layer for now",
    "ENR_L34_BOST_INSET.tif": "inset image, left out of the enroute layer for now",
}

_SUFFIXES = ((" SEC", "sectional"), (" TAC", "terminal"), (" FLY", "flyway"))
_ENROUTE = re.compile(r"ENR_([LAH])\d\d\w*")
# Kinds trimmed to the frame found in the image itself. For these a shape file is only a fallback.
PIXEL_FRAME = ("enroute_low", "enroute_area", "enroute_high", "flyway")


# Images a whole edition holds, skipped ones included. Fewer means a renamed file or a dropped link.
EXPECTED = {"sectional": 57, "terminal": 34, "flyway": 21, "enroute_low": 39, "enroute_area": 14, "enroute_high": 12}


class MissingOutline(Exception):
    pass


class Incomplete(Exception):
    pass


def classify(tif_name: str) -> tuple[str, str] | None:
    if not tif_name.lower().endswith(".tif"):
        return None
    stem = tif_name[:-4]
    if found := _ENROUTE.fullmatch(stem):
        return {"L": "enroute_low", "A": "enroute_area", "H": "enroute_high"}[found[1]], stem.lower()
    for suffix, kind in _SUFFIXES:
        if stem.endswith(suffix):
            return kind, re.sub(r"[^a-z0-9]+", "_", stem[: -len(suffix)].lower()).strip("_")
    return None


def check_complete(tif_names: list[str], kinds=("sectional", "terminal")) -> None:
    found = [pair[0] for pair in map(classify, tif_names) if pair]
    short = [f"{found.count(kind)} {kind} images, expected {EXPECTED[kind]}"
             for kind in kinds if found.count(kind) < EXPECTED[kind]]
    if short:
        raise Incomplete("; ".join(short))


def plan(tif_names: list[str], outline_dir: Path) -> list[tuple[str, str, Path | None]]:
    result, missing = [], []
    for name in sorted(tif_names):
        found = classify(name)
        if found is None or name in SKIP:
            continue
        kind, slug = found
        outline = outline_dir / kind / f"{slug}.shp"
        if outline.exists():
            result.append((name, kind, outline))
        elif kind in PIXEL_FRAME:
            result.append((name, kind, None))
        else:
            missing.append(name)
    if missing:
        raise MissingOutline("no outline for: " + ", ".join(missing))
    return result
