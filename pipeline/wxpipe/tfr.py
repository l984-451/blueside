import http.client
import json
import re
import sys
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

from chartpipe import faa

from . import awc

LIST = "https://tfr.faa.gov/tfrapi/getTfrList"
DETAIL = "https://tfr.faa.gov/download/detail_{}.xml"
_REFERENCE = {"ALT": "MSL", "HEI": "AGL"}
# Standing notices keep the real list far longer than this, so a shorter one has been cut off.
MIN_NOTICES = 20


def parse_list(body: bytes) -> list[dict]:
    """The notice list, after checking it still has the shape this code was written against."""
    try:
        items = json.loads(body)
    except ValueError as error:
        raise awc.BadSource(f"tfr list: {error}")
    if not isinstance(items, list):
        raise awc.BadSource("tfr list: not a list")
    if len(items) < MIN_NOTICES:
        raise awc.BadSource(f"tfr list: only {len(items)} notices")
    for item in items:
        # Both values become part of a file name and an address, so their form is checked strictly.
        if not (isinstance(item, dict) and re.fullmatch(r"\d/\d{4}", str(item.get("notam_id")))
                and re.fullmatch(r"\d{12}", str(item.get("mod_abs_time")))):
            raise awc.BadSource(f"tfr list: unexpected entry {str(item)[:80]}")
    return items


def degrees(text: str) -> float:
    """'114.08W' -> -114.08."""
    if text[-1] not in "NSEW":
        raise ValueError(text)
    value = float(text[:-1])
    return -value if text[-1] in "SW" else value


def _altitude(area, side: str, key: str) -> dict:
    value = area.findtext(f"aseTFRArea/valDistVer{side}")
    code = area.findtext(f"aseTFRArea/codeDistVer{side}")
    return {f"{key}_value": int(float(value)) if value else None,
            f"{key}_unit": area.findtext(f"aseTFRArea/uomDistVer{side}"),
            f"{key}_ref": _REFERENCE.get(code, code)}


def _span(starts: list, ends: list) -> dict:
    # Several time windows collapse to one span, so an area is shown between them and never hidden.
    start = None if None in starts else min(starts)
    end = None if None in ends else max(ends)
    return {"effective": awc.iso(start) if start else None, "expires": awc.iso(end) if end else None}


def _listed(item: dict) -> dict:
    """What the notice list says about a notice."""
    return {"notam": item["notam_id"], "kind": item.get("type"), "facility": item.get("facility"),
            "state": item.get("state"), "title": (item.get("description") or "").strip()}


# A detail that fails to download or parse makes only its own notice unreadable.
_UNREADABLE = (awc.BadSource, ValueError, AttributeError, TypeError, OSError, http.client.HTTPException)
# Once failed downloads have cost this long, the rest are not tried this run, so the turn's other sources still go out.
FAILING_BUDGET_S = 60
_NO_ALTITUDES = {f"{key}_{part}": None for key in ("upper", "lower") for part in ("value", "unit", "ref")}


def unreadable(item: dict) -> dict:
    """A notice whose detail cannot be read, listed with no shape: never drawn wrong, never hidden."""
    changed = datetime.strptime(item["mod_abs_time"], "%Y%m%d%H%M").replace(tzinfo=timezone.utc)
    return {"type": "Feature", "geometry": None, "properties": {
        **_listed(item), "rule": None, "issued": faa.iso(changed), "name": None, **_NO_ALTITUDES,
        "effective": None, "expires": None, "unreadable": True}}


def features(item: dict, detail_xml: bytes) -> list[dict]:
    """One feature per drawn area. A notice with no drawn area gives one feature without geometry."""
    try:
        root = ET.fromstring(detail_xml)
    except ET.ParseError as error:
        raise awc.BadSource(f"tfr {item['notam_id']}: {error}")
    notice = root.find("Group/Add/Not")
    if root.tag != "XNOTAM-Update" or notice is None:
        raise awc.BadSource(f"tfr {item['notam_id']}: not a notice file")
    base = {**_listed(item), "rule": notice.findtext("TfrNot/codeType"),
            "issued": awc.iso(notice.findtext("NotUid/dateIssued"))}
    whole = _span([notice.findtext("dateEffective")], [notice.findtext("dateExpire")])
    out = []
    for area in notice.findall("TfrNot/TFRAreaGroup"):
        windows = area.findall("aseTFRArea/ScheduleGroup")
        span = _span([w.findtext("dateEffective") for w in windows],
                     [w.findtext("dateExpire") for w in windows]) if windows else whole
        outlines = area.findall("abdMergedArea")
        if not outlines and area.find(".//Avx") is not None:
            # Corner points with no merged outline: drawing nothing would hide a real area.
            raise awc.BadSource(f"tfr {item['notam_id']}: area without a merged outline")
        for merged in outlines:
            ring = []
            for vertex in merged.findall("Avx"):
                if vertex.findtext("codeType") != "GRC":
                    # Arcs would need their centre and radius; drawing them as corners gives a wrong shape.
                    raise awc.BadSource(f"tfr {item['notam_id']}: vertex type {vertex.findtext('codeType')}")
                ring.append([degrees(vertex.findtext("geoLong")), degrees(vertex.findtext("geoLat"))])
            out.append(awc.feature("Polygon", ring, {
                **base, "name": area.findtext("aseTFRArea/txtName"),
                **_altitude(area, "Upper", "upper"), **_altitude(area, "Lower", "lower"), **span}))
    if not out:
        out.append({"type": "Feature", "geometry": None, "properties": {**base, "name": None, **_NO_ALTITUDES, **whole}})
    return out


def build(fetch, work: Path) -> bytes:
    """Every listed notice as GeoJSON. A detail file is fetched again only when its notice changes."""
    cache = Path(work) / "tfr"
    cache.mkdir(parents=True, exist_ok=True)
    wanted, found, unread, wasted = set(), [], [], 0.0
    items = parse_list(fetch(LIST))
    for item in items:
        name = item["notam_id"].replace("/", "_")
        saved = cache / f"{name}_{item['mod_abs_time']}.xml"
        wanted.add(saved.name)
        made = None
        if saved.exists():
            try:
                made = features(item, saved.read_bytes())
            except _UNREADABLE:
                # A saved copy that stopped parsing was cut short on disk, so it is fetched again.
                pass
        if made is None:
            started = time.monotonic()
            try:
                if wasted > FAILING_BUDGET_S:
                    raise awc.BadSource("not tried: detail downloads are failing")
                body = fetch(DETAIL.format(name))
                made = features(item, body)
            except _UNREADABLE as error:
                wasted += time.monotonic() - started
                # One notice that cannot be read must not hold back the rest. It goes out listed, unshaped.
                print(f"tfr {item['notam_id']} unreadable: {error}", file=sys.stderr)
                unread.append(item["notam_id"])
                made = [unreadable(item)]
            else:
                # Saved only after it parsed, so a broken download is fetched again next run.
                saved.write_bytes(body)
        found += made
    for old in cache.iterdir():
        if old.name not in wanted:
            old.unlink()
    if unread:
        # Most of them unreadable means the format changed or the host is failing: keep the last good file.
        if len(unread) * 2 > len(items):
            raise awc.BadSource(f"tfrs: {len(unread)} of {len(items)} notices unreadable")
        awc.DEGRADED.append("tfrs")
    return awc.collection(found)
