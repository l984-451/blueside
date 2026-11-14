import re
import urllib.request
from datetime import datetime, timedelta, timezone

VFR_PAGE = "https://www.faa.gov/air_traffic/flight_info/aeronav/digital_products/vfr/"

# Conterminous sheets only. Alaska and Pacific zips are left out: they have no outline files,
# and two Alaska sheets cross the 180 degree meridian.
ENROUTE_ZIPS = {
    "ifr-low": [f"enr_l{n:02d}" for n in range(1, 37)],
    "ifr-area": ["enr_a01", "enr_a02"],
    "ifr-high": [f"enr_h{n:02d}" for n in range(1, 13)],
}

_LINK = re.compile(
    r"//aeronav\.faa\.gov/visual/(\d\d)-(\d\d)-(\d{4})/(sectional-files|tac-files)/([A-Za-z0-9_.-]+\.zip)"
)


def parse_editions(html: str) -> dict[str, list[str]]:
    """Cycle id (YYYY-MM-DD) -> sorted zip URLs for sectionals and terminal area charts."""
    editions: dict[str, set[str]] = {}
    for mm, dd, yyyy, kind, name in _LINK.findall(html):
        url = f"https://aeronav.faa.gov/visual/{mm}-{dd}-{yyyy}/{kind}/{name}"
        editions.setdefault(f"{yyyy}-{mm}-{dd}", set()).add(url)
    return {cycle: sorted(urls) for cycle, urls in sorted(editions.items())}


def ifr_urls(cycle_id: str) -> dict[str, list[str]]:
    """Layer -> enroute zip URLs. Enroute editions carry the same dates as the visual ones."""
    yyyy, mm, dd = cycle_id.split("-")
    base = f"https://aeronav.faa.gov/enroute/{mm}-{dd}-{yyyy}"
    return {layer: [f"{base}/{name}.zip" for name in names] for layer, names in ENROUTE_ZIPS.items()}


def cycle_dates(cycle_id: str) -> tuple[datetime, datetime]:
    effective = datetime.strptime(cycle_id, "%Y-%m-%d").replace(hour=9, minute=1, tzinfo=timezone.utc)
    return effective, effective + timedelta(days=56)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# How a good file of each kind starts. The d-TPP metafile carries a byte order mark.
MAGIC = {"zip": (b"PK\x03\x04",), "pdf": (b"%PDF",), "xml": (b"<?xml", b"\xef\xbb\xbf<?xml")}


def check_kind(name: str, body: bytes) -> None:
    """Raises when a download is not the kind of file its name says, such as an error page served with 200."""
    kind = name.rsplit(".", 1)[-1].lower()
    if kind in MAGIC and not body.startswith(MAGIC[kind]):
        raise ValueError(f"{name}: not a {kind} file, starts {body[:16]!r}")


def fetch(url: str) -> bytes:
    # FAA servers reject requests without a browser-like user agent.
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()
