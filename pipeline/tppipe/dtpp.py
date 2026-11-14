import csv
import io
import re
import zipfile
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta
from pathlib import Path

from navpipe import nasr

PAGE = "https://www.faa.gov/air_traffic/flight_info/aeronav/digital_products/dtpp/"
FILES = "https://aeronav.faa.gov/d-tpp"
_ZIP = re.compile(r"DDTPPA_(\d\d)(\d\d)(\d\d)\.zip")


def parse_cycles(html: str) -> list[str]:
    """Cycle ids (YYYY-MM-DD) named by the d-TPP page's zip links."""
    return sorted({f"20{yy}-{mm}-{dd}" for yy, mm, dd in _ZIP.findall(html)})


def cycle_number(cycle_id: str) -> str:
    """FAA's YYNN name for a cycle: NN counts 28 day cycles from the year's first."""
    day = date.fromisoformat(cycle_id)
    n = 1
    while (day - timedelta(days=28 * n)).year == day.year:
        n += 1
    return f"{day:%y}{n:02d}"


def metafile_url(cycle_id: str) -> str:
    return f"{FILES}/{cycle_number(cycle_id)}/xml_data/d-tpp_Metafile.xml"


def pdf_url(cycle_id: str, name: str) -> str:
    return f"{FILES}/{cycle_number(cycle_id)}/{name}"


def parse_metafile(xml: bytes) -> tuple[str, dict[str, list[dict]]]:
    """The metafile's effective date line and, per state code, every live chart record."""
    root = ET.fromstring(xml)
    states: dict[str, list[dict]] = {}
    for state in root.iter("state_code"):
        charts = states.setdefault(state.get("ID"), [])
        for airport in state.iter("airport_name"):
            for record in airport.iter("record"):
                name = record.findtext("pdf_name", "").strip()
                # A deleted chart keeps its row in a change notice; it has no file.
                if not name or record.findtext("useraction", "").strip() == "D" or name.startswith("DELETED"):
                    continue
                charts.append({
                    "airport": airport.get("apt_ident"),
                    "icao": airport.get("icao_ident") or "",
                    "name": record.findtext("chart_name", "").strip(),
                    "code": record.findtext("chart_code", "").strip(),
                    "file": name,
                })
    return root.get("from_edate", ""), states


def fetch_pdfs(cycle_id: str, names, folder: Path, workers: int = 8) -> dict[str, Path]:
    """Download each named PDF once into folder. Returns file name to local path."""
    names = sorted(set(names))
    with ThreadPoolExecutor(workers) as pool:
        paths = pool.map(lambda n: nasr.download(pdf_url(cycle_id, n), folder / n), names)
        return dict(zip(names, paths))


def runways(nasr_zip: Path) -> dict[str, list]:
    """Each airport's runways as ((lat, lon), (lat, lon)) end pairs, keyed by FAA ident, from the NASR CSV zip."""
    with zipfile.ZipFile(nasr_zip) as archive:
        name = next(n for n in archive.namelist() if n.endswith("APT_RWY_END.csv"))
        text = archive.read(name).decode("latin-1")
    ends: dict[tuple[str, str], list] = {}
    for r in csv.DictReader(io.StringIO(text)):
        if r["LAT_DECIMAL"].strip() and r["LONG_DECIMAL"].strip():
            ends.setdefault((r["ARPT_ID"], r["RWY_ID"]), []).append((float(r["LAT_DECIMAL"]), float(r["LONG_DECIMAL"])))
    out: dict[str, list] = {}
    for (airport, _), pair in ends.items():
        if len(pair) == 2:
            out.setdefault(airport, []).append(tuple(pair))
    return out
