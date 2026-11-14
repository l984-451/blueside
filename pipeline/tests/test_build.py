from pathlib import Path

import pytest

from chartpipe import build


def test_resolutions_match_web_mercator_zoom_levels():
    # 2 * pi * 6378137 / 256 / 2**zoom
    assert build.Z12 == pytest.approx(40075016.685578488 / 256 / 4096)
    assert build.Z13 == pytest.approx(build.Z12 / 2)


def test_run_raises_on_failure():
    with pytest.raises(Exception):
        build.run(["false"])


RGB = {"bands": [{"colorInterpretation": "Red"}, {}, {}], "geoTransform": [0, 46.3, 0, 0, 0, -46.3]}
PALETTED = {"bands": [{"colorInterpretation": "Palette", "colorTable": {"count": 256}}]}
WARPED = {"bands": [{}, {}, {}, {}]}


def fake_gdal(monkeypatch, source_info, warped_info=WARPED):
    """Record commands and answer image questions without GDAL. The warped file is always out.tif."""
    commands = []
    monkeypatch.setattr(build, "run", lambda cmd: commands.append([str(part) for part in cmd]))
    monkeypatch.setattr(build, "info", lambda path: warped_info if str(path).endswith("out.tif") else source_info)
    return commands


def test_palette_expansion_is_skipped_when_band_1_has_no_colour_table(monkeypatch, tmp_path):
    commands = fake_gdal(monkeypatch, RGB)
    build.warp(tmp_path / "ENR_L17.tif", tmp_path / "cut.gpkg", tmp_path / "out.tif", build.Z12)
    assert [c[0] for c in commands] == ["gdalwarp"]
    assert commands[0][-2:] == [str(tmp_path / "ENR_L17.tif"), str(tmp_path / "out.tif")]


def test_paletted_charts_are_still_expanded(monkeypatch, tmp_path):
    commands = fake_gdal(monkeypatch, PALETTED)
    build.warp(tmp_path / "Houston SEC.tif", tmp_path / "houston.shp", tmp_path / "out.tif", build.Z12)
    assert [c[0] for c in commands] == ["gdal_translate", "gdalwarp"]
    assert commands[1][-2] == str(tmp_path / "out.rgb.vrt")


def test_a_warp_without_colour_and_alpha_is_refused(monkeypatch, tmp_path):
    fake_gdal(monkeypatch, RGB, warped_info={"bands": [{}, {}]})
    with pytest.raises(ValueError):
        build.warp(tmp_path / "x.tif", tmp_path / "cut.gpkg", tmp_path / "out.tif", build.Z12)


def test_pixel_size_allows_for_rotated_sheets():
    assert build.pixel_size(RGB) == pytest.approx(46.3)
    rotated = {"geoTransform": [0, 32.4, -0.877, 0, -0.866, -32.381]}
    assert build.pixel_size(rotated) == pytest.approx(32.41, abs=0.01)


def test_coarsest_sheets_are_stacked_first():
    sizes = {Path("l04.tif"): 32.41, Path("l19.tif"): 46.30, Path("l21.tif"): 106.49, Path("l17.tif"): 46.2983,
             Path("l13.tif"): 74.08, Path("l09.tif"): 64.82, Path("l10.tif"): 55.56, Path("l01.tif"): 37.04}
    assert [p.stem for p in build.coarsest_first(sizes)] == ["l21", "l13", "l09", "l10", "l17", "l19", "l01", "l04"]


def test_mosaic_keeps_the_order_it_is_given(monkeypatch, tmp_path):
    commands = []
    monkeypatch.setattr(build, "run", lambda cmd: commands.append([str(part) for part in cmd]))
    build.mosaic([Path("b.tif"), Path("a.tif")], tmp_path / "m.vrt")
    assert commands[0][-2:] == ["b.tif", "a.tif"]
