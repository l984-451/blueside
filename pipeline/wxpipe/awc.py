import csv
import gzip
import http.client
import io
import json
import re
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

from chartpipe import faa

CACHE = "https://aviationweather.gov/data/cache/"
# Center Weather Advisories have no cache file. The API answers 204 with no body when none are out.
CWAS = "https://aviationweather.gov/api/data/cwa?format=json"
# The live files are rewritten every minute; the station list only once a day.
STALE_FILE = timedelta(minutes=20)
# The station list codes territories separately.
US_COUNTRIES = {"US", "PR", "VI", "GU", "MP", "AS", "UM"}
REPORT_TYPES = ("PIREP", "Urgent PIREP")
USER_AGENT = "BluesideWeatherMirror/1.0 (https://pub-b4d06f1c406b4312b314d87c67ecf862.r2.dev)"
# Seconds per request. Short, so a host that answers nothing cannot use up the whole turn.
TIMEOUT = 10
MIN_STATIONS, MIN_METARS, MIN_TAFS = 2000, 1000, 300
# Sources published in this run with part of their decoding missing.
DEGRADED: list[str] = []
# A file whose newest record is older than this has stopped changing at the source.
STALE_METARS, STALE_TAFS, STALE_GAIRMETS = timedelta(minutes=45), timedelta(hours=7), timedelta(hours=7)
CATEGORIES = ("VFR", "MVFR", "IFR", "LIFR")
# Positions in the METAR file. Its header repeats names, so columns are read by position.
_RAW, _ID, _TIME, _LAT, _LON, _TEMP, _DEWP, _WDIR, _WSPD, _GUST, _VIS, _ALTIM = range(12)
_SKY, _CAT = (22, 24, 26, 28), 30
_LAYOUT = {0: "raw_text", 1: "station_id", 2: "observation_time", 3: "latitude", 4: "longitude",
           7: "wind_dir_degrees", 10: "visibility_statute_mi", 11: "altim_in_hg",
           22: "sky_cover", 28: "sky_cover", 29: "cloud_base_ft_agl", 30: "flight_category"}
_VARIABLE_WIND = re.compile(r"\sVRB\d{2,3}(G\d{2,3})?KT\b")


class BadSource(Exception):
    pass


def fetch(url: str, attempts: int = 2) -> bytes:
    """GET with the project User-Agent. Short timeout and one retry: the next run is minutes away."""
    for attempt in range(1, attempts + 1):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                if url.startswith(CACHE) and "stations" not in url:
                    stamp = response.headers.get("Last-Modified")
                    if not stamp or datetime.now(timezone.utc) - parsedate_to_datetime(stamp) > STALE_FILE:
                        raise BadSource(f"{url.rsplit('/', 1)[1]}: last written {stamp}")
                return response.read()
        except (OSError, http.client.HTTPException):
            if attempt == attempts:
                raise
            time.sleep(1)


def offline(folder: Path):
    """A fetch that reads saved files, named by the last part of the address."""
    def read(url: str) -> bytes:
        listing = "goes_listing.xml" if "noaa-goes" in url else "mrms_listing.xml"
        name = listing if "list-type=2" in url else url.rsplit("/", 1)[1].split("?")[0]
        return (Path(folder) / name).read_bytes()
    return read


def iso(text: str) -> str:
    """A source time as UTC text without fractions. A time with no zone is UTC."""
    moment = datetime.fromisoformat(text.strip().replace("Z", "+00:00"))
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return faa.iso(moment)


def _dump(value) -> bytes:
    return json.dumps(value, separators=(",", ":")).encode()


def _number(text: str):
    if text == "":
        return None
    value = float(text)
    return int(value) if value == int(value) else value


def _whole(text: str):
    return None if text == "" else int(float(text))


def us_ids(stations_gz: bytes) -> set[str]:
    stations = json.loads(gzip.decompress(stations_gz))
    ids = {s["icaoId"] or s["id"] for s in stations if s.get("country") in US_COUNTRIES}
    if len(ids) < MIN_STATIONS:
        raise BadSource(f"stations: only {len(ids)} US stations")
    return ids


def stations(fetch, work: Path) -> set[str]:
    """US station ids. The list changes once a day, so a copy on disk is reused for a day."""
    saved = Path(work) / "stations.cache.json.gz"
    if saved.exists() and time.time() - saved.stat().st_mtime < 86400:
        try:
            return us_ids(saved.read_bytes())
        except Exception:
            # A copy cut short on disk counts as no copy.
            pass
    try:
        body = fetch(CACHE + "stations.cache.json.gz")
        ids = us_ids(body)
    except Exception:
        # An old list is better than no METARs.
        if saved.exists():
            return us_ids(saved.read_bytes())
        raise
    saved.parent.mkdir(parents=True, exist_ok=True)
    saved.write_bytes(body)
    return ids


def metars_json(csv_gz: bytes, us: set[str], now: datetime | None = None) -> bytes:
    rows = list(csv.reader(io.StringIO(gzip.decompress(csv_gz).decode("utf-8"), newline="")))
    header = rows[0] if rows else []
    if len(header) <= max(_LAYOUT) or any(header[i] != name for i, name in _LAYOUT.items()):
        raise BadSource("metars: column layout changed")
    out = []
    for row in rows[1:]:
        if len(row) != len(header) or row[_ID] not in us:
            continue
        try:
            raw, vis = row[_RAW], row[_VIS]
            variable = _VARIABLE_WIND.search(raw.split(" RMK")[0]) is not None
            bases = [_whole(row[i + 1]) for i in _SKY if row[i] in ("BKN", "OVC", "OVX") and row[i + 1]]
            item = {
                "id": row[_ID], "lat": float(row[_LAT]), "lon": float(row[_LON]),
                # Anything but the four known words is "not known", never VFR.
                "cat": row[_CAT] if row[_CAT] in CATEGORIES else None,
                "ceil": min(bases) if bases else None,
                "sky": [{"cover": row[i], "base": _whole(row[i + 1])} for i in _SKY if row[i]],
                "vis": float(vis.rstrip("+")) if vis else None,
                # The file writes 0 for variable wind, so the report text decides.
                "wdir": None if variable else _whole(row[_WDIR]),
                "wspd": _whole(row[_WSPD]), "gust": _whole(row[_GUST]),
                "temp": _number(row[_TEMP]), "dewp": _number(row[_DEWP]), "altim": _number(row[_ALTIM]),
                "t": iso(row[_TIME]), "raw": raw,
            }
        except ValueError:
            continue
        if variable:
            item["vrb"] = True
        if vis.endswith("+"):
            item["visp"] = True
        out.append(item)
    if len(out) < MIN_METARS:
        raise BadSource(f"metars: only {len(out)} US reports")
    newest = max(item["t"] for item in out)
    # A file that has stopped changing must not keep its source marked current.
    if now is not None and newest < faa.iso(now - STALE_METARS):
        raise BadSource(f"metars: newest report is from {newest}")
    return _dump(out)


def _records(xml_gz: bytes, tag: str, name: str) -> list:
    """Records of one XML cache file, after checking the envelope the server wraps them in."""
    root = ET.fromstring(gzip.decompress(xml_gz))
    data, errors = root.find("data"), root.find("errors")
    if root.tag != "response" or data is None or (errors is not None and len(errors) > 0):
        raise BadSource(f"{name}: unexpected envelope")
    records = data.findall(tag)
    if str(len(records)) != data.get("num_results"):
        raise BadSource(f"{name}: {len(records)} records, envelope says {data.get('num_results')}")
    return records


# Change words of a forecast period, ranked for periods that start together: a BECMG changes the FM it starts with.
_GROUP_RANK = {None: 0, "FM": 1, "BECMG": 2, "TEMPO": 3, "PROB": 3}


def _taf_group(forecast) -> dict:
    """One forecast period. A value the source leaves out is left out here, never written as zero."""
    def text(tag):
        return (forecast.findtext(tag) or "").strip()

    kind = text("change_indicator") or None
    if kind not in _GROUP_RANK:
        raise ValueError(f"change indicator {kind}")
    direction, vis = text("wind_dir_degrees"), text("visibility_statute_mi")
    group = {
        "from": iso(text("fcst_time_from")), "to": iso(text("fcst_time_to")), "kind": kind,
        "prob": _whole(text("probability")),
        "becoming": iso(text("time_becoming")) if kind == "BECMG" else None,
        "wdir": None if direction == "VRB" else _whole(direction),
        "vrb": True if direction == "VRB" else None,
        "wspd": _whole(text("wind_speed_kt")), "gust": _whole(text("wind_gust_kt")),
        "vis": _number(vis.rstrip("+")), "visp": True if vis.endswith("+") else None,
        "wx": text("wx_string") or None, "vv": _whole(text("vert_vis_ft")),
    }
    if group["from"] >= group["to"] or (kind == "PROB" and group["prob"] is None):
        raise ValueError("forecast period")
    sky = []
    for layer in forecast.findall("sky_condition"):
        cover, base, cloud = layer.get("sky_cover"), layer.get("cloud_base_ft_agl"), layer.get("cloud_type")
        if not cover:
            raise ValueError("sky layer without a cover")
        # CB or TCU, on the layers the forecast marks.
        found = {"cover": cover, "base": _whole(base) if base else None, "type": cloud or None}
        sky.append({key: value for key, value in found.items() if value is not None})
    group["sky"] = sky or None
    return {key: value for key, value in group.items() if value is not None}


# Where the report text starts a new period, and the wind shear group: height in hundreds of feet, then the wind.
_PERIOD_START = re.compile(r"\s(FM\d{6}|BECMG \d{4}|TEMPO|PROB\d{2})")
_WIND_SHEAR = re.compile(r"WS(\d{3})/(\d{3})(\d{2,3})KT")


def _add_wind_shear(groups: list, raw: str) -> None:
    """Puts each wind shear group of the report text on its period. The source's own fields leave it out."""
    periods = {}
    for group in groups:
        start, kind = group["from"], group.get("kind")
        day_hour = start[8:10] + start[11:13]
        if kind in (None, "FM", "BECMG"):
            periods[{None: "", "FM": "FM" + day_hour + start[14:16], "BECMG": "BECMG " + day_hour}[kind]] = group
    parts = _PERIOD_START.split(" ".join(raw.split()))
    # Fewer period starts found in the text than the file lists would put wind shear on an earlier period.
    counted = len(parts) // 2 + 1 == len(groups)
    for head, body in zip([""] + parts[1::2], parts[0::2]):
        for token in body.split():
            if not token.startswith("WS"):
                continue
            shear, group = _WIND_SHEAR.fullmatch(token), periods.get(head)
            # Wind shear in a TEMPO or PROB period, on a period the file lacks, or in another form is not guessed at.
            if shear is None or group is None or "ws" in group or not counted:
                raise ValueError(f"wind shear {token}")
            group["ws"] = {"hgt": int(shear[1]) * 100, "dir": int(shear[2]), "spd": int(shear[3])}


def _taf_groups(taf) -> list:
    """A TAF's forecast periods by start time. The source lists them out of order."""
    groups = [_taf_group(forecast) for forecast in taf.findall("forecast")]
    if len([group for group in groups if "kind" not in group]) != 1:
        raise ValueError("opening period")
    _add_wind_shear(groups, taf.findtext("raw_text"))
    return sorted(groups, key=lambda group: (group["from"], _GROUP_RANK[group.get("kind")]))


def tafs_json(xml_gz: bytes, us: set[str], now: datetime | None = None) -> bytes:
    out, unread = [], 0
    for taf in _records(xml_gz, "TAF", "tafs"):
        station, raw = taf.findtext("station_id"), taf.findtext("raw_text")
        if station not in us or not raw:
            continue
        try:
            item = {"id": station, "issued": iso(taf.findtext("issue_time")),
                    "from": iso(taf.findtext("valid_time_from")), "to": iso(taf.findtext("valid_time_to")),
                    "raw": raw}
        except (AttributeError, ValueError):
            continue
        try:
            item["groups"] = _taf_groups(taf)
        except (AttributeError, ValueError, OverflowError):
            # Periods that cannot all be read are left out whole. The report text is still right.
            unread += 1
        out.append(item)
    if len(out) < MIN_TAFS:
        raise BadSource(f"tafs: only {len(out)} US forecasts")
    newest = max(item["issued"] for item in out)
    # New forecasts come at least every six hours, so a file with none has stopped changing.
    if now is not None and newest < faa.iso(now - STALE_TAFS):
        raise BadSource(f"tafs: newest forecast is from {newest}")
    if unread:
        print(f"tafs: forecast periods unreadable in {unread} of {len(out)}", file=sys.stderr)
        # One odd forecast is published as text. Most of them unreadable means the format changed.
        if unread * 2 > len(out):
            DEGRADED.append("tafs")
    return _dump(out)


def feature(kind: str, points: list, properties: dict) -> dict:
    """One GeoJSON feature. A polygon ring is closed here if the source left it open."""
    if kind == "Polygon":
        if points and points[0] != points[-1]:
            points = points + [points[0]]
        if len(points) < 4:
            raise BadSource("area with fewer than three corners")
        coordinates = [points]
    else:
        if len(points) < 2:
            raise BadSource("line with fewer than two points")
        coordinates = points
    return {"type": "Feature", "geometry": {"type": kind, "coordinates": coordinates}, "properties": properties}


def collection(features: list) -> bytes:
    return _dump({"type": "FeatureCollection", "features": features})


def _points(area) -> list:
    return [[float(p.findtext("longitude")), float(p.findtext("latitude"))] for p in area.findall("point")]


def _feet(text):
    """Feet as a whole number, or None for a missing value or a filler such as -1."""
    return int(text) if text and text.isdigit() else None


def _level(text):
    """G-AIRMET altitude text: digits become plain feet, SFC and FZL stay, fillers become None."""
    text = (text or "").strip()
    if text.isdigit():
        return str(int(text))
    if text.startswith("SFC"):
        return "SFC"
    return "FZL" if text == "FZL" else None


def sigmets_geojson(xml_gz: bytes) -> bytes:
    found = []
    for record in _records(xml_gz, "AIRSIGMET", "sigmets"):
        hazard, areas = record.find("hazard"), record.findall("area")
        if hazard is None or not hazard.get("type") or not areas:
            # A SIGMET that cannot be drawn must not vanish quietly.
            raise BadSource("sigmets: a record has no hazard or no area")
        altitude = record.find("altitude")
        heights = altitude.attrib if altitude is not None else {}
        properties = {
            "hazard": hazard.get("type"), "severity": hazard.get("severity") or None,
            "kind": record.findtext("airsigmet_type"),
            "from": iso(record.findtext("valid_time_from")), "to": iso(record.findtext("valid_time_to")),
            "base_ft": _feet(heights.get("min_ft_msl")), "top_ft": _feet(heights.get("max_ft_msl")),
            "raw": (record.findtext("raw_text") or "").strip(),
        }
        found += [feature("Polygon", _points(area), properties) for area in areas]
    return collection(found)


def gairmets_geojson(xml_gz: bytes, now: datetime | None = None) -> bytes:
    found = []
    for record in _records(xml_gz, "GAIRMET", "gairmets"):
        hazard, area, kind = record.find("hazard"), record.find("area"), record.findtext("geometry_type")
        if hazard is None or not hazard.get("type") or area is None or kind not in ("AREA", "LINE"):
            raise BadSource("gairmets: a record has no hazard, no area or an unknown geometry type")
        heights = {}
        for altitude in record.findall("altitude"):
            heights.update(altitude.attrib)
        properties = {
            "product": record.findtext("product"), "tag": record.findtext("tag"),
            "hazard": hazard.get("type"), "severity": hazard.get("severity") or None,
            "issued": iso(record.findtext("issue_time")), "valid": iso(record.findtext("valid_time")),
            "expires": iso(record.findtext("expire_time")), "due_to": record.findtext("due_to"),
            "base": _level(heights.get("min_ft_msl")), "top": _level(heights.get("max_ft_msl")),
            "level": _level(heights.get("level_ft_msl")),
            "fzl_base": _level(record.findtext("fzl_altitude/min_ft_msl")),
            "fzl_top": _level(record.findtext("fzl_altitude/max_ft_msl")),
        }
        # A LINE is a contour such as the freezing level. Closing it would draw an area that is not there.
        found.append(feature("Polygon" if kind == "AREA" else "LineString", _points(area), properties))
    if not found:
        # Freezing level lines are part of every issue, so no records means a broken file.
        raise BadSource("gairmets: no records")
    newest = max(item["properties"]["issued"] for item in found)
    if now is not None and newest < faa.iso(now - STALE_GAIRMETS):
        raise BadSource(f"gairmets: newest issue is from {newest}")
    return collection(found)


def cwas_geojson(body: bytes) -> bytes:
    found = []
    for record in json.loads(body or b"[]"):
        points = [[float(p["lon"]), float(p["lat"])] for p in record.get("coords") or []]
        properties = {
            "cwsu": record["cwsu"], "series": str(record.get("seriesId") or ""),
            "hazard": record.get("hazard") or "", "qualifier": record.get("qualifier") or "",
            "from": faa.iso(datetime.fromtimestamp(record["validTimeFrom"], timezone.utc)),
            "to": faa.iso(datetime.fromtimestamp(record["validTimeTo"], timezone.utc)),
            "base_ft": _feet(str(record.get("base"))), "top_ft": _feet(str(record.get("top"))), "raw": (record.get("rawText") or "").strip(),
        }
        if len(points) < 2:
            # A one-point advisory has no shape to draw. Published without it, flagged for the operator.
            DEGRADED.append("cwas")
            continue
        # A ring needs three corners; two points are a line, such as a line of storms.
        found.append(feature("Polygon" if len(points) >= 3 else "LineString", points, properties))
    return collection(found)


INTENSITY = ("NEG", "NEGclr", "SMTH-LGT", "TRC", "TRC-LGT", "LGT", "LGT-MOD", "MOD", "MOD-SEV", "HVY", "SEV",
             "SEV-EXTM", "EXTM")


def _worst(record, tag: str, key: str):
    """The most severe intensity among a report's entries. An unknown word outranks every known one."""
    words = [e.get(key) for e in record.findall(tag) if e.get(key)]
    return max(words, key=lambda w: INTENSITY.index(w) if w in INTENSITY else len(INTENSITY), default=None)


def pireps_json(xml_gz: bytes) -> bytes:
    out, wanted = [], 0
    records = _records(xml_gz, "AircraftReport", "pireps")
    # Oceanic position reports arrive around the clock, so a file with no known record is a broken one.
    if not any(r.findtext("report_type") in REPORT_TYPES + ("AIREP",) for r in records):
        raise BadSource("pireps: no record has a known report type")
    for record in records:
        kind = record.findtext("report_type")
        if kind not in REPORT_TYPES:
            continue
        wanted += 1
        try:
            out.append({
                "t": iso(record.findtext("observation_time")),
                "lat": float(record.findtext("latitude")), "lon": float(record.findtext("longitude")),
                # The feed writes 0 for "during descent" and "unknown".
                "alt": _feet(record.findtext("altitude_ft_msl")) or None,
                "urgent": kind == "Urgent PIREP", "acft": record.findtext("aircraft_ref"),
                "turb": _worst(record, "turbulence_condition", "turbulence_intensity"),
                "ice": _worst(record, "icing_condition", "icing_intensity"),
                "raw": (record.findtext("raw_text") or "").strip(),
            })
        except (AttributeError, TypeError, ValueError):
            continue
    # One mistyped report is dropped. Most of them unreadable means the format changed.
    if len(out) * 2 < wanted:
        raise BadSource(f"pireps: {wanted - len(out)} of {wanted} reports unreadable")
    return _dump(out)
