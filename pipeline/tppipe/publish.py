import json
from datetime import datetime
from pathlib import Path

from chartpipe import faa, manifest, pack
from chartpipe import publish as chart_publish
from navpipe import nasr

MANIFEST_KEY = "plates/manifest.json"
LAYER = "plates"


def cycle_entry(cycle_id: str, files: dict[str, Path]) -> tuple[dict, dict[str, Path]]:
    """Manifest entry for one cycle's state packs, and the local file behind each path."""
    effective, expires = nasr.cycle_dates(cycle_id)
    packs, by_path = [], {}
    for state, local in sorted(files.items()):
        size, sha = pack.describe(local)
        path = f"plates/{cycle_id}/{state}.sqlite"
        packs.append({"layer": LAYER, "region": state, "bytes": size, "sha256": sha, "path": path})
        by_path[path] = local
    return {"id": cycle_id, "effective": faa.iso(effective), "expires": faa.iso(expires), "packs": packs}, by_path


def read_manifest(store) -> dict | None:
    try:
        body = store.client.get_object(Bucket=store.bucket, Key=MANIFEST_KEY)["Body"].read()
    except store.client.exceptions.NoSuchKey:
        return None
    return json.loads(body)


def publish_plates(store, entry: dict, files: dict[str, Path], now: datetime, force_size: bool = False) -> dict:
    """Upload every state pack, then the plates manifest. Touches nothing outside plates/."""
    prefix = f"plates/{entry['id']}/"
    if stray := [p["path"] for p in entry["packs"] if not p["path"].startswith(prefix)]:
        raise ValueError(f"refusing to upload outside {prefix}: {stray}")
    if not force_size:
        chart_publish.check_sizes(read_manifest(store), entry["id"], entry["packs"])
    for p in entry["packs"]:
        store.upload(files[p["path"]], p["path"])
    merged = manifest.merge(read_manifest(store), entry, now)
    store.client.put_object(Bucket=store.bucket, Key=MANIFEST_KEY, Body=json.dumps(merged).encode(),
                            ContentType="application/json", CacheControl="no-cache")
    return merged
