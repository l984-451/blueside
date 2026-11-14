import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from chartpipe import pack
from navpipe import navtiles
from wxpipe import awc, radar

FIX = Path(__file__).parent / "fixtures" / "wx"
LISTING = (FIX / "mrms_listing.xml").read_bytes()
EMPTY = (b'<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
         b"<KeyCount>0</KeyCount><IsTruncated>false</IsTruncated></ListBucketResult>")
GRIB = FIX / "MRMS_MergedReflectivityQCComposite_00.50_20261013-002636.grib2.gz"
NEWEST = datetime(2026, 10, 13, 0, 26, 36, tzinfo=timezone.utc)


def test_the_newest_frame_is_found_by_name():
    key, valid = radar.newest(LISTING)
    assert key == ("CONUS/MergedReflectivityQCComposite_00.50/20261013/"
                   "MRMS_MergedReflectivityQCComposite_00.50_20261013-002636.grib2.gz")
    assert valid == NEWEST
    assert radar.newest(EMPTY) is None


@pytest.mark.parametrize("body", [
    b"<html>Slow Down</html>",
    LISTING.replace(b"<IsTruncated>false", b"<IsTruncated>true"),
], ids=["error page", "cut listing"])
def test_an_error_page_or_a_cut_listing_is_refused(body):
    with pytest.raises(awc.BadSource):
        radar.newest(body)


def test_just_after_midnight_the_day_before_is_read():
    now = datetime(2026, 10, 14, 0, 1, tzinfo=timezone.utc)
    asked = []

    def fetch(url):
        asked.append(url)
        return EMPTY if "/20261014/" in url else LISTING

    assert radar.latest(fetch, now)[1] == NEWEST
    assert asked == [radar.listing_url(now), radar.listing_url(now - timedelta(days=1))]
    assert asked[0].endswith("?list-type=2&prefix=CONUS/MergedReflectivityQCComposite_00.50/20261014/")


@pytest.mark.skipif(shutil.which("tippecanoe") is None or shutil.which("pmtiles") is None,
                    reason="needs GDAL, tippecanoe and pmtiles")
def test_one_real_frame_becomes_dbz_bands_from_zoom_3_to_5(tmp_path):
    out = tmp_path / "frame.pmtiles"
    radar.build_frame(GRIB, out)
    assert pack.zoom_range(out) == (3, 5)
    # Blurred echo edges hold far fewer vertices: the raw grid gave about 3 MB here.
    assert 50_000 < out.stat().st_size < 1_500_000
    # This tile covers the Minnesota and Wisconsin storms in the saved frame.
    storms = {f["properties"]["dbz"] for f in navtiles.decode(out, 5, 7, 11)}
    assert {5, 20, 40} <= storms and storms <= {radar.NO_COVERAGE, *radar.LEVELS}
    # Beyond radar range the frame is shaded, so no coverage never looks like no echo.
    assert radar.NO_COVERAGE in {f["properties"]["dbz"] for f in navtiles.decode(out, 5, 4, 14)}
    assert not (tmp_path / "frame.build").exists()


def test_chaikin_cuts_corners_and_keeps_the_ring_closed():
    square = [(0, 0), (4, 0), (4, 4), (0, 4), (0, 0)]
    once = radar.chaikin(square, 1).tolist()
    assert once[:2] == [[1, 0], [3, 0]]
    assert once[0] == once[-1] and len(once) == 9
    assert [0, 0] not in radar.chaikin(square).tolist()
