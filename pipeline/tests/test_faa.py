from datetime import datetime, timezone

from chartpipe import faa

HTML = """
<a href="https://aeronav.faa.gov/visual/09-03-2026/sectional-files/Houston.zip">x</a>
<a href="https://aeronav.faa.gov/visual/09-03-2026/sectional-files/Dallas-Ft_Worth.zip">x</a>
<a href="https://aeronav.faa.gov/visual/09-03-2026/sectional-files/Dallas-Ft_Worth.zip">dup</a>
<a href="https://aeronav.faa.gov/visual/09-03-2026/tac-files/Dallas-Ft_Worth_TAC.zip">x</a>
<a href="//aeronav.faa.gov/visual/10-29-2026/sectional-files/Houston.zip">x</a>
<a href="https://aeronav.faa.gov/visual/09-03-2026/PDFs/Houston.pdf">not a chart zip</a>
<a href="https://aeronav.faa.gov/visual/09-03-2026/heli-files/Houston_HEL.zip">not wanted</a>
"""


def test_groups_links_by_edition_and_removes_duplicates():
    editions = faa.parse_editions(HTML)
    assert list(editions) == ["2026-09-03", "2026-10-29"]
    assert editions["2026-09-03"] == [
        "https://aeronav.faa.gov/visual/09-03-2026/sectional-files/Dallas-Ft_Worth.zip",
        "https://aeronav.faa.gov/visual/09-03-2026/sectional-files/Houston.zip",
        "https://aeronav.faa.gov/visual/09-03-2026/tac-files/Dallas-Ft_Worth_TAC.zip",
    ]
    assert editions["2026-10-29"] == ["https://aeronav.faa.gov/visual/10-29-2026/sectional-files/Houston.zip"]


def test_page_with_no_chart_links_gives_nothing():
    assert faa.parse_editions("<html>maintenance</html>") == {}


def test_cycle_dates_are_0901_utc_and_56_days():
    effective, expires = faa.cycle_dates("2026-09-03")
    assert effective == datetime(2026, 9, 3, 9, 1, tzinfo=timezone.utc)
    assert expires == datetime(2026, 10, 29, 9, 1, tzinfo=timezone.utc)


def test_iso_has_no_fractional_seconds():
    assert faa.iso(datetime(2026, 9, 3, 9, 1, 0, 123456, tzinfo=timezone.utc)) == "2026-09-03T09:01:00Z"


def test_enroute_zips_follow_the_edition_date():
    urls = faa.ifr_urls("2026-09-03")
    assert list(urls) == ["ifr-low", "ifr-area", "ifr-high"]
    assert urls["ifr-high"][-1] == "https://aeronav.faa.gov/enroute/09-03-2026/enr_h12.zip" and len(urls["ifr-high"]) == 12
    assert len(urls["ifr-low"]) == 36 and len(urls["ifr-area"]) == 2
    assert urls["ifr-low"][0] == "https://aeronav.faa.gov/enroute/09-03-2026/enr_l01.zip"
    assert urls["ifr-low"][-1] == "https://aeronav.faa.gov/enroute/09-03-2026/enr_l36.zip"
    assert urls["ifr-area"] == ["https://aeronav.faa.gov/enroute/09-03-2026/enr_a01.zip",
                                "https://aeronav.faa.gov/enroute/09-03-2026/enr_a02.zip"]
    assert faa.ifr_urls("2026-10-29")["ifr-low"][16].endswith("/10-29-2026/enr_l17.zip")
    assert not [u for found in urls.values() for u in found if "akl" in u or "enr_p" in u]
