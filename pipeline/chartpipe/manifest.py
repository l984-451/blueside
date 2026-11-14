from datetime import datetime

from . import faa


# Layers whose data does not follow the FAA cycle: one copy under charts/base, listed once in "base".
CYCLE_FREE = ("street", "terrain")


def pack_path(cycle_id: str, layer: str, region: str) -> str:
    return f"charts/{cycle_id}/{layer}/{region}.pmtiles"


def base_entries(packs: list[dict], version: str) -> list[dict]:
    """Named by content, so a rebuild with the same bytes keeps its key and is not uploaded again."""
    return [{**p, "version": version, "path": f"charts/base/{p['layer']}/{p['region']}-{p['sha256'][:16]}.pmtiles"}
            for p in packs]


def missing_base(existing: dict | None, versions: dict[str, str]) -> list[str]:
    """Cycle-free layers with no base packs at the version the code builds."""
    have = {p["layer"] for p in (existing or {}).get("base", []) if p.get("version") == versions[p["layer"]]}
    return [layer for layer in versions if layer not in have]


def paths(existing: dict | None) -> set[str]:
    return {p["path"] for c in (existing or {}).get("cycles", []) for p in c["packs"]} | \
        {p["path"] for p in (existing or {}).get("base", [])}


def cycle_entry(cycle_id: str, packs: list[dict]) -> dict:
    effective, expires = faa.cycle_dates(cycle_id)
    return {
        "id": cycle_id,
        "effective": faa.iso(effective),
        "expires": faa.iso(expires),
        "packs": [{**p, "path": pack_path(cycle_id, p["layer"], p["region"])} for p in packs],
    }


def known_cycles(existing: dict | None) -> set[str]:
    return {c["id"] for c in (existing or {}).get("cycles", [])}


def missing_layers(existing: dict | None, cycle_id: str, layers) -> list[str]:
    """The layers this cycle has no pack for in the manifest. Every layer, if the cycle is not listed."""
    have = {p["layer"] for c in (existing or {}).get("cycles", []) if c["id"] == cycle_id for p in c["packs"]}
    return [layer for layer in layers if layer not in have]


def merge(existing: dict | None, cycle: dict | None, now: datetime, base: list[dict] | None = None) -> dict:
    """Add or replace one cycle and drop every cycle that has already expired. A base layer leaves the cycles."""
    cycles = {c["id"]: c for c in (existing or {}).get("cycles", [])}
    if cycle:
        cycles[cycle["id"]] = cycle
    base = (existing or {}).get("base", []) if base is None else base
    moved = {p["layer"] for p in base}
    live = [{**c, "packs": [p for p in c["packs"] if p["layer"] not in moved]}
            for c in cycles.values() if c["expires"] > faa.iso(now)]
    return {"version": 1, "cycles": sorted(live, key=lambda c: c["effective"]), **({"base": base} if base else {})}
