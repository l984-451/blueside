import json
import os
from datetime import datetime, timedelta
from pathlib import Path

from . import manifest as manifest_module

# Unlisted chart keys younger than this are left alone.
GRACE = timedelta(days=1)
# A pack this much bigger or smaller than the same pack last cycle waits for --force-size.
SIZE_CHANGE = 0.25


class R2Store:
    def __init__(self, client, bucket: str):
        self.client, self.bucket = client, bucket

    def read_manifest(self) -> dict | None:
        try:
            body = self.client.get_object(Bucket=self.bucket, Key="manifest.json")["Body"].read()
        except self.client.exceptions.NoSuchKey:
            return None
        return json.loads(body)

    def upload(self, local: Path, key: str) -> None:
        self.client.upload_file(str(local), self.bucket, key,
                                ExtraArgs={"ContentType": "application/octet-stream"})

    def write_manifest(self, value: dict) -> None:
        self.client.put_object(Bucket=self.bucket, Key="manifest.json",
                               Body=json.dumps(value).encode(),
                               ContentType="application/json", CacheControl="no-cache")

    def delete_unlisted(self, listed: dict, now: datetime) -> list[str]:
        """Remove chart keys the manifest does not name. Keys newer than GRACE stay: another job may be mid-upload."""
        keep = manifest_module.paths(listed)
        if not keep:
            raise ValueError("refusing to delete every chart pack")
        gone = []
        for page in self.client.get_paginator("list_objects_v2").paginate(Bucket=self.bucket, Prefix="charts/"):
            for item in page.get("Contents", []):
                if item["Key"] not in keep and item["LastModified"] < now - GRACE:
                    self.client.delete_object(Bucket=self.bucket, Key=item["Key"])
                    gone.append(item["Key"])
        return gone


def r2_store_from_env() -> R2Store:
    import boto3
    client = boto3.client(
        "s3",
        endpoint_url=f"https://{os.environ['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        region_name="auto",
    )
    return R2Store(client, os.environ["R2_BUCKET"])


def newest_other(current: dict | None, cycle_id: str) -> dict | None:
    """The newest cycle in the manifest other than this one."""
    return max((c for c in (current or {}).get("cycles", []) if c["id"] != cycle_id), key=lambda c: c["id"], default=None)


def check_sizes(current: dict | None, cycle_id: str, packs: list[dict]) -> None:
    """Refuses packs whose size differs from the same layer and region in the newest other cycle by more than
    SIZE_CHANGE: a chart that lost tiles, or a state that lost plates, must not go public unnoticed."""
    newest = newest_other(current, cycle_id)
    before = {(p["layer"], p["region"]): p["bytes"] for p in newest["packs"]} if newest else {}
    changed = [f"{p['layer']}/{p['region']} {before[key]} -> {p['bytes']} bytes" for p in packs
               if (key := (p["layer"], p["region"])) in before and abs(p["bytes"] - before[key]) > SIZE_CHANGE * before[key]]
    if changed:
        raise ValueError(f"{cycle_id}: packs changed size by more than {SIZE_CHANGE:.0%} since {newest['id']} "
                         f"(pass --force-size if that is meant): {changed}")


def lost_regions(current: dict | None, cycle_entry: dict) -> list[str]:
    """Layer/region pairs that the newest other cycle in the manifest has and this entry lacks."""
    newest = newest_other(current, cycle_entry["id"])
    if newest is None:
        return []
    have = {(p["layer"], p["region"]) for p in cycle_entry["packs"]}
    # Cycle-free layers live in the base section, not in any cycle.
    return sorted(f"{p['layer']}/{p['region']}" for p in newest["packs"]
                  if (p["layer"], p["region"]) not in have and p["layer"] not in manifest_module.CYCLE_FREE)


def with_live_packs(current: dict | None, cycle_entry: dict, replace=()) -> tuple[dict, list[dict]]:
    """The entry to publish and the packs to upload. Live packs stay exactly as listed, except in the layers to replace."""
    live = next((c for c in (current or {}).get("cycles", []) if c["id"] == cycle_entry["id"]), None)
    if live is None:
        return cycle_entry, cycle_entry["packs"]
    kept = [p for p in live["packs"] if p["layer"] not in replace]
    have = {(p["layer"], p["region"]) for p in kept}
    new = [p for p in cycle_entry["packs"] if (p["layer"], p["region"]) not in have]
    return {**live, "packs": kept + new}, new


def publish_cycle(store, cycle_entry: dict, pack_files: dict[str, Path], now: datetime, replace=(),
                  force_size: bool = False) -> None:
    """Upload the packs that are not live yet or are being replaced, then the manifest."""
    current = store.read_manifest()
    entry, new = with_live_packs(current, cycle_entry, replace)
    uploads = [(pack_files[p["path"]], p["path"]) for p in new]
    gone = lost_regions(current, entry)
    if entry is not cycle_entry:
        # The cycle is already live: judge the layers being added, not packs it never had.
        gone = [g for g in gone if g.split("/")[0] in {p["layer"] for p in new}]
    # A state that silently dropped out of the build must not go public.
    if gone:
        raise ValueError(f"{entry['id']}: the previous cycle has packs this one lacks: {gone}")
    if not force_size:
        check_sizes(current, entry["id"], new)
    for local, key in uploads:
        store.upload(local, key)
    # Read again: another job may have published while the packs were uploading.
    current = store.read_manifest()
    live = next((c for c in (current or {}).get("cycles", []) if c["id"] == entry["id"]), entry)
    sent = {p["path"] for p in new}
    entry = {**live, "packs": [p for p in live["packs"] if p["path"] not in sent and p["layer"] not in replace] + new}
    merged = manifest_module.merge(current, entry, now)
    store.write_manifest(merged)


def publish_base(store, packs: list[dict], files: dict[str, Path], now: datetime) -> None:
    """Upload base packs not already live, then list them in place of every live base pack of their layers."""
    current = store.read_manifest()
    layers = {p["layer"] for p in packs}
    have = {(p["layer"], p["region"]) for p in packs}
    gone = sorted(f"{p['layer']}/{p['region']}" for p in (current or {}).get("base", [])
                  if p["layer"] in layers and (p["layer"], p["region"]) not in have)
    if gone:
        raise ValueError(f"base: the live packs have regions this build lacks: {gone}")
    live = manifest_module.paths(current)
    for p in packs:
        if p["path"] not in live:
            store.upload(files[p["path"]], p["path"])
    # Read again: another job may have published while the packs were uploading.
    current = store.read_manifest()
    base = [p for p in (current or {}).get("base", []) if p["layer"] not in layers] + packs
    store.write_manifest(manifest_module.merge(current, None, now, base))
