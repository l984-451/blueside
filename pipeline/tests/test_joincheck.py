import shutil

import pytest

np = pytest.importorskip("numpy")

from chartpipe import joincheck, joins

needs_gdal = pytest.mark.skipif(shutil.which("gdalbuildvrt") is None, reason="needs the GDAL tools")
TINT = (200, 220, 200)


@pytest.fixture
def write_sheet():
    """Writes a (4, h, w) array as a small warped sheet; x and y place its top-left pixel on a 10 metre grid."""
    gdal = pytest.importorskip("osgeo.gdal")
    from osgeo import osr
    gdal.UseExceptions()

    def write(path, x, y, pixels):
        height, width = pixels.shape[1:]
        data = gdal.GetDriverByName("GTiff").Create(
            str(path), width, height, 4, gdal.GDT_Byte,
            ["TILED=YES", "COMPRESS=ZSTD", "PREDICTOR=2", "BLOCKXSIZE=512", "BLOCKYSIZE=512"])
        data.SetGeoTransform((x * 10.0, 10.0, 0, -y * 10.0, 0, -10.0))
        srs = osr.SpatialReference()
        srs.ImportFromEPSG(3857)
        data.SetSpatialRef(srs)
        data.WriteArray(pixels)
        data.GetRasterBand(4).SetColorInterpretation(gdal.GCI_AlphaBand)
        data.Close()
        return path

    return write


def flat(height, width, tint=TINT):
    pixels = np.empty((4, height, width), np.uint8)
    for band, value in enumerate((*tint, 255)):
        pixels[band] = value
    return pixels


def test_difference_is_the_largest_channel_gap():
    a, b = flat(2, 2)[:3], flat(2, 2, (190, 250, 200))[:3]
    assert joins.difference(a, b).tolist() == [[30, 30], [30, 30]]


def test_a_join_through_identical_pixels_measures_zero():
    shown = np.zeros((10, 10), np.int16)
    shown[5:] = 1
    got = joincheck.join_share(shown, 0, 1, flat(10, 10), flat(10, 10))
    assert got == {"pixels": 20, "differ": 0.0, "mean": 0.0}


def test_a_join_through_a_label_measures_the_cut_share():
    shown = np.zeros((10, 10), np.int16)
    shown[5:] = 1
    lower = flat(10, 10)
    lower[:3, 3:7, 0:5] = 0          # ink on one sheet only, across the join, over half its length
    got = joincheck.join_share(shown, 0, 1, flat(10, 10), lower)
    assert got["pixels"] == 20
    assert got["differ"] == pytest.approx(0.5)


def test_pixels_one_sheet_does_not_have_are_left_out():
    shown = np.zeros((10, 10), np.int16)
    shown[5:] = 1
    upper = flat(10, 10)
    upper[:, 5:] = 0                 # the upper sheet ends at the join, as with a fixed outline
    got = joincheck.join_share(shown, 0, 1, upper, flat(10, 10))
    assert got["pixels"] == 10


@needs_gdal
def test_measure_reads_the_join_between_two_sheets(tmp_path, write_sheet):
    upper = flat(60, 80)
    upper[:3, 30:50, 20:40] = 0      # a label on the lower sheet of the stack, cut by the edge of the one above
    a = write_sheet(tmp_path / "v_a.tif", 0, 0, upper)
    b = write_sheet(tmp_path / "v_b.tif", 0, 40, flat(60, 80))
    got = joincheck.measure([a, b], 0, 1)
    assert got["pixels"] == 80
    assert got["differ"] == pytest.approx(0.25)


@needs_gdal
def test_window_pads_with_zero_outside_the_raster(tmp_path, write_sheet):
    from osgeo import gdal
    data = gdal.Open(str(write_sheet(tmp_path / "v_a.tif", 0, 0, flat(8, 8))))
    got = joins.window(data, -2, 6, 4, 4, [4])
    assert got.shape == (1, 4, 4)
    assert got[0].tolist() == [[0, 0, 255, 255], [0, 0, 255, 255], [0, 0, 0, 0], [0, 0, 0, 0]]
    assert joins.origin(data) == (0, 0)


@needs_gdal
def test_shots_write_a_plain_crop_and_one_with_the_join_drawn(tmp_path, write_sheet, monkeypatch):
    from osgeo import gdal
    monkeypatch.setattr(joincheck, "SHOT", (40, 30))
    a = write_sheet(tmp_path / "v_a.tif", -40, -30, flat(60, 80))
    b = write_sheet(tmp_path / "v_b.tif", -40, 0, flat(60, 80, (180, 200, 220)))
    joincheck.main(["shots", str(tmp_path), "v", str(tmp_path / "out"), "before", "mid=0,0"])
    plain = gdal.Open(str(tmp_path / "out" / "mid-before.png")).ReadAsArray()
    lined = gdal.Open(str(tmp_path / "out" / "mid-before-line.png")).ReadAsArray()
    assert plain.shape == (3, 30, 40)
    assert plain[:, 0, 0].tolist() == [200, 220, 200] and plain[:, 29, 0].tolist() == [180, 200, 220]
    assert lined[:, 15, 5].tolist() == [255, 0, 255]
    assert (lined[:, 0, 0] == plain[:, 0, 0]).all()
