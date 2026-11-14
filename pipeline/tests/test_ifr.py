import pytest

from chartpipe import charts, ifr


def sheet(width, height, horizontal, vertical):
    """Dark-pixel counts per row and per column for a sheet with the given lines (first, last, share)."""
    rows, cols = [0] * height, [0] * width
    for first, last, share in horizontal:
        rows[first:last + 1] = [int(share * width)] * (last - first + 1)
    for first, last, share in vertical:
        cols[first:last + 1] = [int(share * height)] * (last - first + 1)
    return rows, cols, width, height


def solid(rect):
    """Edge shares of a frame with no gaps."""
    return 1.0, 1.0, 1.0, 1.0


def unread(rect):
    pytest.fail("the edge lines were read for a sheet that has no rectangle to test")


L17 = sheet(24000, 8000, [(256, 264, 0.9), (7736, 7744, 0.9)], [(4196, 4204, 0.94), (21796, 21804, 0.94)])
L19 = sheet(24000, 8000, [(256, 264, 0.9), (7736, 7744, 0.9)], [(2196, 2204, 0.94), (21796, 21804, 0.94)])
L12 = sheet(24000, 8000, [(257, 262, 0.75), (7735, 7742, 0.73)], [(4197, 4202, 0.94), (21796, 21802, 0.94)])
L23 = sheet(24000, 8000, [(256, 264, 0.83), (7736, 7744, 0.83)],
            [(2196, 2204, 0.95), (4974, 4984, 0.94), (5176, 5184, 0.94), (21796, 21804, 0.94)])
DFW = sheet(6000, 7998, [(197, 203, 0.97), (814, 828, 0.29), (7797, 7803, 0.96)],
            [(116, 123, 0.95), (5876, 5883, 0.95)])
# The long line on the right belongs to a second panel printed inside the frame, in its upper right corner.
L34 = sheet(24000, 8000, [(251, 259, 0.89), (7732, 7740, 0.98)], [(196, 204, 0.94), (23798, 23806, 0.52)])
L34_MAP = ((196, 251), (21605, 251), (21748, 3118), (22351, 4247), (23805, 4634), (23805, 7741), (196, 7741))


def test_thick_runs_joins_near_neighbours_and_drops_thin_lines():
    values = [0] * 100
    for i in (10, 11, 12, 13, 15, 16, 17, 40, 41, 42, 43, 44, 45):
        values[i] = 60
    assert ifr.thick_runs(values, 100, 0.25, 7) == [(10, 17)]
    assert ifr.thick_runs(values, 100, 0.25, 5) == [(10, 17), (40, 45)]
    assert ifr.thick_runs(values, 100, 0.75, 5) == []


def test_detect_returns_the_outer_edge_of_the_frame():
    assert ifr.detect(*L17) == (4196, 256, 21805, 7745)
    assert ifr.detect(*L19) == (2196, 256, 21805, 7745)


def test_detect_refuses_a_sheet_without_exactly_two_lines_each_way():
    assert ifr.detect(*L23) is None
    assert ifr.detect(*L12) is None
    assert ifr.detect(*DFW) is None


def test_corners_and_bounds_take_a_rectangle_or_a_list_of_points():
    assert ifr.corners([10, 20, 30, 40]) == [(10, 20), (30, 20), (30, 40), (10, 40)]
    assert ifr.corners([[10, 20], [30, 20], [20, 40]]) == [(10, 20), (30, 20), (20, 40)]
    assert ifr.bounds([10, 20, 30, 40]) == (10, 20, 30, 40)
    assert ifr.bounds([[10, 20], [30, 25], [20, 40]]) == (10, 20, 30, 40)


def test_choose_uses_a_hand_entered_rectangle_that_sits_on_the_frame():
    assert ifr.choose("ENR_L23.tif", *L23, solid) == ((5176, 256, 21805, 7745), "override")
    assert ifr.choose("ENR_L12.tif", *L12, solid) == ((4197, 257, 21803, 7743), "override")
    assert ifr.choose("ENR_A02_DFW.tif", *DFW, solid) == ((116, 197, 5884, 7804), "override")


def test_choose_drops_a_hand_entered_rectangle_that_no_longer_fits_the_sheet():
    moved = sheet(24000, 8000, [(256, 264, 0.83), (7736, 7744, 0.83)],
                  [(2196, 2204, 0.95), (5014, 5024, 0.94), (5216, 5224, 0.94), (21796, 21804, 0.94)])
    assert ifr.choose("ENR_L23.tif", *moved, unread) == (None, "the hand-entered rectangle is off the frame line")


def test_choose_detects_when_there_is_no_hand_entered_rectangle():
    assert ifr.choose("ENR_L17.tif", *L17, solid) == ((4196, 256, 21805, 7745), "detected")
    assert ifr.choose("ENR_L99.tif", *L23, unread) == (None, "found 2 horizontal and 4 vertical frame lines")


def test_choose_stops_on_a_rectangle_whose_frame_line_has_gaps():
    asked = []

    def gaps(rect):
        asked.append(rect)
        return 1.0, 0.56, 0.91, 0.74

    with pytest.raises(charts.MissingOutline) as error:
        ifr.choose("ENR_L98.tif", *L34, gaps)
    assert asked == [(196, 251, 23807, 7741)]
    assert "ENR_L98.tif" in str(error.value) and "right, top, bottom" in str(error.value)
    with pytest.raises(charts.MissingOutline):
        ifr.choose("ENR_L23.tif", *L23, gaps)
    assert ifr.choose("ENR_L98.tif", *L34, lambda rect: (1.0, 0.95, 0.99, 1.0))[1] == "detected"


def test_choose_moves_a_hand_entered_rectangle_onto_a_frame_line_a_pixel_away():
    rows, cols, width, height = sheet(24000, 8000, [(256, 264, 0.9), (7736, 7743, 0.9)],
                                      [(2195, 2203, 0.94), (17549, 17557, 0.5), (21794, 21803, 0.94)])

    def pixels(rect):
        x0, y0, x1, y1 = rect
        return tuple(float(line > 0) for line in (cols[x0], cols[x1 - 1], rows[y0], rows[y1 - 1]))

    assert pixels((2196, 256, 21805, 7745)) == (1.0, 0.0, 1.0, 0.0)
    assert ifr.choose("ENR_L09.tif", rows, cols, width, height, pixels) == ((2195, 256, 21804, 7744), "override")


def test_choose_uses_a_hand_entered_outline_with_more_than_four_corners():
    asked = []

    def legs(shape):
        asked.append(shape)
        return [1.0] * len(shape)

    assert ifr.choose("ENR_L34.tif", *L34, legs) == (L34_MAP, "override")
    assert asked == [L34_MAP]


def test_choose_stops_when_a_leg_of_a_many_cornered_outline_is_not_on_a_dark_line():
    with pytest.raises(charts.MissingOutline) as error:
        ifr.choose("ENR_L34.tif", *L34, lambda shape: (1.0, 1.0, 0.4, 1.0, 1.0, 1.0, 1.0))
    assert "ENR_L34.tif" in str(error.value) and "leg 3" in str(error.value)


def test_leg_points_lie_inside_the_outline_whichever_way_it_is_drawn():
    square = [(0, 0), (100, 0), (100, 100), (0, 100)]
    top, right, bottom, left = ifr.leg_points(square)
    assert {y for _, y in top} == {3} and {x for x, _ in right} == {97}
    assert {y for _, y in bottom} == {97} and {x for x, _ in left} == {3}
    assert len(top) > 40 and min(x for x, _ in top) >= 5 and max(x for x, _ in top) <= 95
    left, bottom, right, top = ifr.leg_points(square[:1] + square[:0:-1])
    assert {x for x, _ in left} == {3} and {y for _, y in top} == {3}
    slanted = ifr.leg_points([(0, 0), (100, 0), (200, 100), (0, 100)])[1]
    assert all(x - 100 < y for x, y in slanted)


def test_choose_stops_when_a_many_cornered_outline_no_longer_fits_the_sheet():
    moved = sheet(24000, 8000, [(251, 259, 0.89), (7732, 7740, 0.98)], [(236, 244, 0.94), (23798, 23806, 0.52)])
    with pytest.raises(charts.MissingOutline) as error:
        ifr.choose("ENR_L34.tif", *moved, unread)
    assert "ENR_L34.tif" in str(error.value)


def test_every_hand_entered_outline_is_for_a_sheet_that_gets_built():
    assert set(ifr.OVERRIDES) == {"ENR_L01.tif", "ENR_L09.tif", "ENR_L12.tif", "ENR_L23.tif", "ENR_L34.tif",
                                  "ENR_A01_JAX.tif", "ENR_A02_DFW.tif",
                                  "ENR_H03.tif", "ENR_H04.tif", "ENR_H08.tif", "ENR_H12.tif",
                                  "Cincinnati FLY.tif", "Detroit FLY.tif", "Las Vegas FLY.tif", "Miami FLY.tif",
                                  "San Diego FLY.tif", "San Francisco FLY.tif", "Seattle FLY.tif", "St Louis FLY.tif"}
    for name, shape in ifr.OVERRIDES.items():
        x0, y0, x1, y1 = ifr.bounds(shape)
        assert charts.classify(name)[0] in charts.PIXEL_FRAME
        assert name not in charts.SKIP
        assert 0 <= x0 < x1 and 0 <= y0 < y1
        assert len(ifr.corners(shape)) >= 4


def test_cutline_writes_the_rectangle_it_chose(monkeypatch, tmp_path, capsys):
    written = []
    monkeypatch.setattr(ifr, "dark_counts", lambda tif: L17)
    monkeypatch.setattr(ifr, "edge_shares", lambda tif, rect: solid(rect))
    monkeypatch.setattr(ifr, "write_cutline", lambda tif, rect, out: written.append((tif.name, rect, out)))
    out = tmp_path / "cut.gpkg"
    assert ifr.cutline(tmp_path / "ENR_L17.tif", None, out) == out
    assert written == [("ENR_L17.tif", (4196, 256, 21805, 7745), out)]
    assert "outline ENR_L17.tif: detected (4196, 256, 21805, 7745)" in capsys.readouterr().out


def test_cutline_writes_a_many_cornered_outline(monkeypatch, tmp_path):
    written = []
    monkeypatch.setattr(ifr, "dark_counts", lambda tif: L34)
    monkeypatch.setattr(ifr, "edge_shares", lambda tif, shape: [1.0] * len(shape))
    monkeypatch.setattr(ifr, "write_cutline", lambda tif, shape, out: written.append(shape))
    ifr.cutline(tmp_path / "ENR_L34.tif", tmp_path / "enr_l34.shp", tmp_path / "cut.gpkg")
    assert written == [L34_MAP]


def test_cutline_does_not_swap_a_frame_with_gaps_for_the_shape_file(monkeypatch, tmp_path):
    monkeypatch.setattr(ifr, "dark_counts", lambda tif: L34)
    monkeypatch.setattr(ifr, "edge_shares", lambda tif, rect: (1.0, 0.56, 0.91, 0.74))
    monkeypatch.setattr(ifr, "write_cutline", lambda *args: pytest.fail("an unsafe rectangle was written"))
    monkeypatch.setattr(ifr, "FALLBACKS", [])
    with pytest.raises(charts.MissingOutline):
        ifr.cutline(tmp_path / "ENR_L98.tif", tmp_path / "enr_l98.shp", tmp_path / "cut.gpkg")
    assert ifr.FALLBACKS == []


def test_cutline_falls_back_to_the_shape_file_and_says_so(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(ifr, "dark_counts", lambda tif: L23)
    monkeypatch.setattr(ifr, "write_cutline", lambda *args: pytest.fail("there is no rectangle to write"))
    monkeypatch.setattr(ifr, "FALLBACKS", [])
    shape = tmp_path / "enr_l99.shp"
    assert ifr.cutline(tmp_path / "ENR_L99.tif", shape, tmp_path / "cut.gpkg") == shape
    assert "outline ENR_L99.tif: FALLBACK" in capsys.readouterr().out
    assert ifr.FALLBACKS == ["ENR_L99.tif"]


def test_cutline_stops_when_there_is_no_rectangle_and_no_shape_file(monkeypatch, tmp_path):
    monkeypatch.setattr(ifr, "dark_counts", lambda tif: DFW)
    with pytest.raises(charts.MissingOutline) as error:
        ifr.cutline(tmp_path / "ENR_A02_XXX.tif", None, tmp_path / "cut.gpkg")
    assert "ENR_A02_XXX.tif" in str(error.value)


def test_flyway_sheets_have_a_hairline_frame():
    rows, cols = [0] * 6000, [0] * 16000
    rows[119] = rows[5906] = 10000
    cols[1606] = cols[11815] = 5800
    assert ifr.choose("Los Angeles FLY.tif", rows, cols, 16000, 6000, solid) == ((1606, 119, 11816, 5907), "detected")
    assert ifr.choose("ENR_L17.tif", rows, cols, 16000, 6000, solid)[0] is None


def hairline_sheet(np, slant=0, gap=None):
    """2000x1500 mask with a 1-pixel frame from (100, 100) to (1900, 1400) whose top edge drops `slant` pixels."""
    dark = np.zeros((1500, 2000), bool)
    xs = np.arange(100, 1900)
    dark[100 + (xs - 100) * slant // 1800, xs] = True
    dark[1399, 100:1900] = True
    dark[100:1400, 100] = dark[100:1400, 1899] = True
    if gap:
        dark[1399, gap[0]:gap[1]] = False
    return dark


def test_flyway_frame_follows_a_slanted_hairline():
    np = pytest.importorskip("numpy")
    outline, how = ifr.choose_flyway("Atlanta FLY.tif", hairline_sheet(np, slant=2))
    assert how == "detected"
    xs, ys = zip(*outline)
    assert (min(xs), max(xs), max(ys)) == (100, 1900, 1400)
    assert outline[0][0] == 100 and abs(outline[0][1] - 100) <= 1 and abs(outline[len(outline) // 4][1] - 102) <= 1


def test_flyway_frame_with_a_broken_leg_stops_the_sheet():
    np = pytest.importorskip("numpy")
    with pytest.raises(charts.MissingOutline) as error:
        ifr.choose_flyway("Atlanta FLY.tif", hairline_sheet(np, gap=(400, 1600)))
    assert "Atlanta FLY.tif" in str(error.value)
