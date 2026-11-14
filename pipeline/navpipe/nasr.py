import http.client
import json
import re
import time
import urllib.error
import urllib.request
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

from chartpipe import faa

INDEX = "https://www.faa.gov/air_traffic/flight_info/aeronav/aero_data/NASR_Subscription/"
FILES = "https://nfdc.faa.gov/webContent/28DaySub"
SUA_LAYER = ("https://services6.arcgis.com/ssFJjBXIUyZDrSYZ/arcgis/rest/services/"
             "Special_Use_Airspace/FeatureServer/0")
MIN_SUA = 1000
OBSTACLES = "https://aeronav.faa.gov/Obst_Data/DAILY_DOF_CSV.ZIP"
_MONTHS = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()


def parse_cycles(html: str) -> list[str]:
    """Cycle ids (YYYY-MM-DD) linked from the subscription page, oldest first."""
    return sorted(set(re.findall(r"NASR_Subscription/(\d{4}-\d{2}-\d{2})", html)))


def cycle_dates(cycle_id: str, days: int = 28) -> tuple[datetime, datetime]:
    effective, _ = faa.cycle_dates(cycle_id)
    return effective, effective + timedelta(days=days)


def csv_url(cycle_id: str) -> str:
    year, month, day = cycle_id.split("-")
    return f"{FILES}/extra/{day}_{_MONTHS[int(month) - 1]}_{year}_CSV.zip"


def airspace_url(cycle_id: str) -> str:
    return f"{FILES}/{cycle_id}/class_airspace_shape_files.zip"


def exists(url: str) -> bool:
    # This host answers HEAD with 503 for every file, so ask for one byte instead.
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Range": "bytes=0-0"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.status in (200, 206)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise


def _fetch(url: str, attempts: int = 3) -> bytes:
    # A large answer is sometimes cut off part way, and nobody is there to rerun the job.
    for attempt in range(1, attempts + 1):
        try:
            return faa.fetch(url)
        except (OSError, http.client.HTTPException):
            if attempt == attempts:
                raise
            time.sleep(10 * attempt)


def download(url: str, target: Path, attempts: int = 3) -> Path:
    """Fetch to target unless it is already there. A part file or an error page never passes for the file."""
    if target.exists():
        return target
    body = _fetch(url, attempts)
    faa.check_kind(target.name, body)
    target.parent.mkdir(parents=True, exist_ok=True)
    part = target.with_name(target.name + ".part")
    part.write_bytes(body)
    part.rename(target)
    return target


def fetch_cycle(cycle_id: str, work: Path) -> tuple[Path, Path]:
    """Download and unpack one cycle. Returns the CSV folder and the class airspace shapefile."""
    tables = download(csv_url(cycle_id), work / "zips" / "csv.zip")
    shapes = download(airspace_url(cycle_id), work / "zips" / "class_airspace.zip")
    csv_dir, shp_dir = work / "csv", work / "shp"
    with zipfile.ZipFile(tables) as archive:
        archive.extractall(csv_dir, [name for name in archive.namelist() if name.endswith(".csv")])
    with zipfile.ZipFile(shapes) as archive:
        archive.extractall(shp_dir)
    return csv_dir, shp_dir / "Shape_Files" / "Class_Airspace.shp"


def fetch_obstacles(work: Path) -> Path:
    """Download the FAA daily obstacle file and unpack it. Returns the CSV."""
    archive = download(OBSTACLES, work / "zips" / "dof.zip")
    with zipfile.ZipFile(archive) as source:
        source.extract("DOF.CSV", work / "dof")
    return work / "dof" / "DOF.CSV"


def fetch_sua(target: Path, pending: bool = False) -> str:
    """Save every special use airspace shape as GeoJSON. Returns when the source data last changed."""
    # The pending service holds the shapes that take effect with the next cycle.
    source = SUA_LAYER.replace("Special_Use_Airspace", "Pending_Special_Use_Airspace") if pending else SUA_LAYER
    layer = json.loads(_fetch(source + "?f=json"))
    edited = datetime.fromtimestamp(layer["editingInfo"]["dataLastEditDate"] / 1000, timezone.utc)
    where = "/query?where=1%3D1"
    count = json.loads(_fetch(source + where + "&returnCountOnly=true&f=json"))["count"]
    # The service sometimes answers with an error body; ask again before failing the cycle.
    for attempt in range(3):
        body = _fetch(source + where + "&outFields=*&outSR=4326&f=geojson")
        found = len(json.loads(body).get("features", []))
        if found == count:
            break
        time.sleep(30 * (attempt + 1))
    # One answer is capped at 2000 rows; a short answer must not pass for the whole set.
    if found != count or count < MIN_SUA:
        raise ValueError(f"special use airspace: got {found} of {count} shapes, need at least {MIN_SUA}")
    target.write_bytes(body)
    return faa.iso(edited)
