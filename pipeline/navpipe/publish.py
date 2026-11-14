import json
from datetime import datetime
from pathlib import Path

from chartpipe import faa, manifest, pack

from . import nasr

MANIFEST_KEY = "nav/manifest.json"
FILES = {"nav-db": "nav.sqlite", "nav-tiles": "nav.pmtiles"}


def cycle_entry(cycle_id: str, folder: Path) -> tuple[dict, dict[str, Path]]:
    """Manifest entry for one built cycle, and the local file behind each path."""
    effective, expires = nasr.cycle_dates(cycle_id)
    packs, files = [], {}
    for layer, name in FILES.items():
        size, sha = pack.describe(folder / name)
        path = f"nav/{cycle_id}/{name}"
        packs.append({"layer": layer, "region": "US", "bytes": size, "sha256": sha, "path": path})
        files[path] = folder / name
    entry = {"id": cycle_id, "effective": faa.iso(effective), "expires": faa.iso(expires), "packs": packs}
    return entry, files


def read_manifest(store) -> dict | None:
    try:
        body = store.client.get_object(Bucket=store.bucket, Key=MANIFEST_KEY)["Body"].read()
    except store.client.exceptions.NoSuchKey:
        return None
    return json.loads(body)


def publish_nav(store, entry: dict, files: dict[str, Path], now: datetime) -> dict:
    """Upload both files, then the nav manifest. Nothing is deleted and no chart key is touched."""
    uploads = [(files[p["path"]], p["path"]) for p in entry["packs"]]
    prefix = f"nav/{entry['id']}/"
    if stray := [key for _, key in uploads if not key.startswith(prefix)]:
        raise ValueError(f"refusing to upload outside {prefix}: {stray}")
    for local, key in uploads:
        store.upload(local, key)
    merged = manifest.merge(read_manifest(store), entry, now)
    store.client.put_object(Bucket=store.bucket, Key=MANIFEST_KEY, Body=json.dumps(merged).encode(),
                            ContentType="application/json", CacheControl="no-cache")
    return merged
