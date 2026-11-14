import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from chartpipe import pack
from wxpipe import awc, goes

FIX = Path(__file__).parent / "fixtures" / "wx"
READ = awc.offline(FIX)
NOW = datetime(2026, 10, 13, 0, 35, tzinfo=timezone.utc)


def test_scan_start_comes_from_the_file_name():
    assert goes.started("OR_GLM-L2-LCFA_G19_s20262860034200_e2026_c2026.nc") == datetime(2026, 10, 13, 0, 34, 20, tzinfo=timezone.utc)


def test_the_newest_band_13_picture_of_each_satellite_is_found():
    pictures, valid = goes.latest_ir(READ, NOW)
    assert [s for s, _ in pictures] == ["goes19", "goes18"]
    assert all("M6C13_" in k and "s2026286003117" in k for _, k in pictures)
    assert valid == datetime(2026, 10, 13, 0, 31, 17, tzinfo=timezone.utc)


def test_a_cut_listing_is_refused():
    with pytest.raises(awc.BadSource):
        goes.keys(lambda url: b"<ListBucketResult><IsTruncated>true</IsTruncated>", "goes19", goes.GLM, NOW)


def test_infrared_pictures_become_raster_tiles(tmp_path):
    pictures, _ = goes.latest_ir(READ, NOW)
    out = tmp_path / "satellite.pmtiles"
    goes.build_ir([FIX / k.rsplit("/", 1)[1] for _, k in pictures], out)
    assert pack.zoom_range(out) == goes.ZOOMS
    assert not (tmp_path / "satellite.build").exists()


def test_lightning_keeps_good_conus_flashes_of_the_last_half_hour(tmp_path):
    flashes = json.loads(goes.lightning_json(READ, tmp_path, NOW))
    assert flashes == [{"t": "2026-10-13T00:20:00Z", "p": [[40.5, -80.25]]},
                       {"t": "2026-10-13T00:34:20Z", "p": [[35.12, -97.46]]}]


def test_lightning_reads_each_file_once(tmp_path, monkeypatch):
    monkeypatch.setattr(goes, "FLASH_GAP", timedelta(minutes=20))
    goes.lightning_json(READ, tmp_path, NOW)
    fetched = []

    def fetch(url):
        fetched.append(url)
        return READ(url)

    later = json.loads(goes.lightning_json(fetch, tmp_path, NOW + timedelta(minutes=16)))
    assert all("list-type=2" in url for url in fetched)
    # The 00:20 file left the half hour.
    assert [group["t"] for group in later] == ["2026-10-13T00:34:20Z"]


def test_a_silent_lightning_feed_fails():
    with pytest.raises(awc.BadSource):
        goes.lightning_json(READ, Path("/nonexistent"), NOW + timedelta(minutes=12))
