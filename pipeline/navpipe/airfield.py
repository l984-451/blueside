"""What the map needs to know about an airfield beyond its row: display name, runway heading, radio."""
import math
import re
import sqlite3

PAVED = ("ASPH", "CONC", "PEM")
MILITARY = ("MA", "MN", "MR", "CG")
# The sectional draws a field to scale when a paved runway is longer than 8,069 ft.
LONG_RUNWAY = 8070
FT = 0.3048
# An outline this many feet off the published length means the FAA's own figures disagree.
MAX_LENGTH_GAP = 50
_UPPER = {"AFB", "AAF", "NAS", "MCAS", "ARB", "JRB", "ANGB", "NOLF", "CGAS", "LZ", "USAF", "II", "III", "IV"}
_SPECIAL = {"DEKALB": "DeKalb", "DUPAGE": "DuPage", "LAGUARDIA": "LaGuardia", "MACARTHUR": "MacArthur",
            "MACDILL": "MacDill"}
_HOW = r"(?: (?:INDEFLY|INDEF|PERMLY|PERM|UFN))?"
# The whole first sentence must be the closure. Hours, a weight, a user or a part of the runway leave it open.
_CLOSED = re.compile(r"^(?:(?:TURF )?(?:RWY|RY|HELIPAD)(?: (?P<id>(?=\S*[\d/])\S+))? |ALL RWYS )?CLSD" + _HOW
                     + r"(?:$|\s*[,-]\s*(?:NOT INSP|(?:PAVEMENT )?UNUSBL)$| (?:DUE TO|AND MKD) (?P<why>.+)"
                     + r"| EXE?CEPT FOR TAXIING$)")
_WORDS = (r"WHEN|IF|UNLESS|UNTIL|EXCP?|EXCEPT|PPR|NOTAMS?|ONLY|OPE?N|WINTER|SUMMER|SS|SR|"
          r"JAN|FEB|MAR|APR|JUN|JUL|AUG|SEP|OCT|NOV|DEC")
# A reason that holds a date or one of these words is a condition, and the runway stays open.
_CONDITION = re.compile(r"\d|\b(?:" + _WORDS + r"|THRU|SNOW|MAY)\b")
# A later sentence can take the closure back. There a digit, THRU, SNOW or MAY may only describe damage.
_EXCEPTION = re.compile(r"\b(?:" + _WORDS + r"|\d{4}-\d{4})\b")
_NAMED = re.compile(r"^RWY (\d{1,2}[LRC]?[/-]\d{1,2}[LRC]?) CLSD" + _HOW + "$")


def _word(word: str) -> str:
    if word in _UPPER or any(character.isdigit() for character in word):
        return word
    if word in _SPECIAL:
        return _SPECIAL[word]
    if len(word) > 3 and word.startswith("MC"):
        return "Mc" + word[2:].capitalize()
    head, mark, tail = word.partition("'")
    # O'HARE keeps a capital after the mark; MARY'S does not.
    if mark and len(head) == 1:
        return head + mark + tail.capitalize()
    return word.capitalize()


def title(name: str) -> str:
    """Mixed case for display: MC KINNEY FLD becomes McKinney Fld. The FAA's spelling is kept."""
    joined = re.sub(r"\bMC (?=[A-Z]{3})", "MC", name.strip())
    return re.sub(r"[^\s/\-()&.,]+", lambda found: _word(found.group()), joined)


def _padded(name: str) -> str:
    """A runway id as the runway rows spell it: 08/26 for 8/26 or 8-26."""
    return "/".join(re.sub(r"^(\d\D?)$", r"0\1", end) for end in re.split("[/-]", name))


def closed_runways(db: sqlite3.Connection) -> set[tuple[int, str]]:
    """Runways the FAA's remarks close outright. A seasonal, night, partial or conditional closure does not count."""
    known = set(db.execute("SELECT airport_id, rwy_id FROM runways"))
    found = set()
    for airport_id, element, remark in db.execute(
            "SELECT airport_id, element, remark FROM remarks WHERE remark LIKE '%CLSD%'"):
        parts = [part.strip() for part in re.split(r"[.;]", remark.strip().upper())]
        # The closure may follow a sentence about the surface. A condition just before it or anywhere after keeps it
        # open; earlier sentences limit other uses of the runway.
        at = next((i for i, part in enumerate(parts) if "CLSD" in part), 0)
        first, others = parts[at], parts[max(at - 1, 0):at] + parts[at + 1:]
        if _EXCEPTION.search(" ".join(others)):
            continue
        if (airport_id, element) in known:
            # Some remarks open with the runway's own id: H2 CLSD INDEFLY.
            if first.startswith(element + " "):
                first = first[len(element) + 1:]
            match = _CLOSED.match(first)
            # A remark that names another runway, or one end of this one, closes nothing.
            if (match and (not match["id"] or _padded(match["id"]) == _padded(element))
                    and not _CONDITION.search(match["why"] or "")):
                found.add((airport_id, element))
        elif not element and (named := _NAMED.match(first)):
            if (airport_id, _padded(named[1])) in known:
                found.add((airport_id, _padded(named[1])))
    return found


def _variation(magvar: str | None) -> int | None:
    if not magvar or magvar[-1] not in "EW" or not magvar[:-1].isdigit():
        return None
    return int(magvar[:-1]) * (1 if magvar[-1] == "E" else -1)


def bearing(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """True course from the first point to the second, in degrees."""
    a, b, d = math.radians(lat1), math.radians(lat2), math.radians(lon2 - lon1)
    return math.degrees(math.atan2(math.sin(d) * math.cos(b),
                                   math.cos(a) * math.sin(b) - math.sin(a) * math.cos(b) * math.cos(d))) % 360


def heading(end_id, true_hdg, here, there, magvar) -> tuple[int | None, str | None]:
    """True heading of one runway end and where it came from. Positions are (lat, lon) or None."""
    if true_hdg is not None:
        return true_hdg % 360, "surveyed"
    if here and there:
        return round(bearing(*here, *there)) % 360, "derived"
    variation = _variation(magvar)
    if end_id[:2].isdigit() and 1 <= int(end_id[:2]) <= 36 and variation is not None:
        # A runway number is the magnetic heading in tens of degrees.
        return (int(end_id[:2]) * 10 + variation) % 360, "derived"
    return None, None


def backwards(end_id, true_hdg, here, there, magvar) -> bool:
    """True when an end's surveyed heading or its number points away from the far end. Positions are (lat, lon)."""
    stated = true_hdg
    if stated is None and end_id[:2].isdigit() and 1 <= int(end_id[:2]) <= 36:
        # With no variation on file the bare number still tells one end from the other.
        stated = int(end_id[:2]) * 10 + (_variation(magvar) or 0)
    return stated is not None and abs((stated - bearing(*here, *there) + 180) % 360 - 180) > 90


def summary(db: sqlite3.Connection) -> dict[int, dict]:
    """Per airport: the longest open runway and longest open paved runway in feet, the paved and lighted
    flags, and the longest runway's heading. Pads and water lanes count only where nothing better is open."""
    closed = closed_runways(db)
    ends = {}
    for airport_id, rwy_id, end_id, true_hdg, lat, lon in db.execute(
            "SELECT airport_id, rwy_id, end_id, true_hdg, lat, lon FROM runway_ends ORDER BY rowid"):
        position = (lat, lon) if lat is not None and lon is not None else None
        ends.setdefault((airport_id, rwy_id), []).append((end_id, true_hdg, position))
    magvar = dict(db.execute("SELECT id, magvar FROM airports"))
    seaplane = {number for number, in db.execute("SELECT id FROM airports WHERE type = 'C'")}
    open_rows, has_runway = {}, set()
    for airport_id, rwy_id, length, surface, lights in db.execute(
            "SELECT airport_id, rwy_id, length, surface, lights FROM runways ORDER BY rowid"):
        if not rwy_id.startswith("H"):
            has_runway.add(airport_id)
        if (airport_id, rwy_id) not in closed:
            open_rows.setdefault(airport_id, []).append((rwy_id, length or 0, surface or "", lights or ""))
    found, longest = {}, {}
    for airport_id, rows in open_rows.items():
        # A helipad says nothing about the runways of a field that has any, open or closed.
        if airport_id in has_runway:
            rows = [row for row in rows if not row[0].startswith("H")]
            if not rows:
                continue
        # Nor does a water lane describe an airport that has an open land runway. A seaplane base is its lanes.
        if airport_id not in seaplane:
            rows = [row for row in rows if not row[2].startswith("WATER")] or rows
        paved =[length for _, length, surface, _ in rows if surface.split("-")[0] in PAVED]
        first = max(rows, key=lambda row: row[1])
        entry = found[airport_id] = {"rwy": first[1], "hard": int(bool(paved)), "paved_len": max(paved, default=0)}
        longest[airport_id] = first[0]
        # Nonstandard lighting is not shown as lighted.
        if any(lights.strip() not in ("", "NSTD") for *_, lights in rows):
            entry["lit"] = 1
    for airport_id, rwy_id in longest.items():
        pair = ends.get((airport_id, rwy_id), [])
        if pair:
            end_id, true_hdg, here = pair[0]
            there = pair[1][2] if len(pair) > 1 else None
            hdg, source = heading(end_id, true_hdg, here, there, magvar.get(airport_id))
            if hdg is not None:
                # A runway bar looks the same from either end.
                found[airport_id].update(hdg=hdg % 180, hdg_src=source)
    return found


def _vhf(freq: str) -> bool:
    try:
        return 118 <= float(freq) < 137
    except ValueError:
        return False


def frequencies(db: sqlite3.Connection) -> dict[int, dict]:
    """The CTAF, and the tower frequency where the FAA's rows leave only one answer."""
    ctaf, local = {}, {}
    for airport_id, kind, freq in db.execute(
            "SELECT airport_id, kind, freq FROM frequencies WHERE kind = 'ctaf' OR use LIKE 'LCL/P%'"):
        if kind == "ctaf":
            ctaf[airport_id] = freq.strip()
        elif _vhf(freq):
            local.setdefault(airport_id, set()).add(freq.strip())
    found = {}
    for airport_id in ctaf.keys() | local.keys():
        entry = found[airport_id] = {}
        towers = local.get(airport_id, set())
        if airport_id in ctaf:
            entry["ctaf"] = ctaf[airport_id]
        if ctaf.get(airport_id) in towers:
            entry["ct"] = ctaf[airport_id]
        elif len(towers) == 1:
            entry["ct"] = next(iter(towers))
    return found


def _metres_per_degree(lat: float) -> tuple[float, float]:
    """Metres per degree of longitude and latitude on the WGS84 ellipsoid."""
    lat0 = math.radians(lat)
    return (111412.84 * math.cos(lat0) - 93.5 * math.cos(3 * lat0) + 0.118 * math.cos(5 * lat0),
            111132.92 - 559.82 * math.cos(2 * lat0) + 1.175 * math.cos(4 * lat0))


def offset(lat: float, lon: float, true_hdg: float, feet: float) -> tuple[float, float]:
    """The (lat, lon) this many feet away on a true heading. Good over a runway's length."""
    kx, ky = _metres_per_degree(lat)
    angle, metres = math.radians(true_hdg), feet * FT
    return lat + metres * math.cos(angle) / ky, lon + metres * math.sin(angle) / kx


def estimated_ends(rwy_id, filed, length, magvar, arp, single) -> list[tuple] | None:
    """Two ends rows (end_id, true_hdg, lat, lon, displaced) for a runway the FAA did not survey at both ends:
    from the one surveyed end along its heading, or centered on the airport's point when it is the only runway.
    filed is its end rows in file order; arp is (lat, lon)."""
    names = rwy_id.split("/")
    if len(names) != 2 or not length:
        return None
    rows = {row[0]: row for row in filed}
    located = [row for row in filed if row[2] is not None and row[3] is not None]
    base = located[0] if len(located) == 1 else rows.get(names[0], (names[0], None, None, None, None))
    hdg, _ = heading(base[0], base[1], None, None, magvar)
    if hdg is None or (len(located) != 1 and not single):
        return None
    far_id = names[1] if base[0] == names[0] else names[0]
    far = rows.get(far_id, (far_id, None, None, None, None))
    if len(located) == 1:
        start = base[2], base[3]
    else:
        start = offset(*arp, hdg + 180, length / 2)
    end = offset(*start, hdg, length)
    return [(base[0], base[1], *start, base[4]), (far_id, far[1], *end, far[4])]


def rectangle(a: tuple[float, float], b: tuple[float, float], width_ft: float) -> tuple[list, float]:
    """Outline of a runway from its two ends (lon, lat) and its width. Also returns the built length in feet."""
    kx, ky = _metres_per_degree((a[1] + b[1]) / 2)
    dx, dy = (b[0] - a[0]) * kx, (b[1] - a[1]) * ky
    length = math.hypot(dx, dy)
    nx, ny = -dy / length * width_ft * FT / 2, dx / length * width_ft * FT / 2
    ring = [(a[0] + nx / kx, a[1] + ny / ky), (b[0] + nx / kx, b[1] + ny / ky),
            (b[0] - nx / kx, b[1] - ny / ky), (a[0] - nx / kx, a[1] - ny / ky)]
    ring.append(ring[0])
    return [[round(x, 7), round(y, 7)] for x, y in ring], length / FT
