import shutil

import pytest

np = pytest.importorskip("numpy")

from chartpipe import joins
from test_joincheck import TINT, flat, write_sheet  # noqa: F401


def pair(height=120, width=200, depth=40, tint=TINT):
    """A sheet, and a mosaic beneath it that covers its top `depth` rows."""
    sheet, under = flat(height, width), flat(height, width, tint)
    under[:, depth:] = 0
    return sheet, under


def ink(pixels, rows, cols):
    """Print a black block on a sheet and return its cells."""
    label = np.zeros(pixels.shape[1:], bool)
    label[rows[0]:rows[1], cols[0]:cols[1]] = True
    pixels[:3, label] = 0
    return label


def test_sheets_that_agree_everywhere_keep_the_fixed_outline():
    drop, notes = joins.find_drop(*pair())
    assert not drop.any()
    assert [n for n in notes if "FIXED" in n] == []


def test_a_label_of_the_sheet_beneath_that_crosses_the_edge_is_shown_whole():
    sheet, under = pair()
    label = ink(under, (0, 13), (20, 60))
    drop, _ = joins.find_drop(sheet, under)
    assert drop[label].all()


def test_a_label_inside_the_overlap_is_never_split():
    sheet, under = pair()
    beneath = ink(under, (0, 11), (60, 100))
    own = ink(sheet, (14, 25), (80, 120))
    drop, _ = joins.find_drop(sheet, under)
    assert drop[beneath].all()
    assert drop[own].all() or not drop[own].any()


def test_nothing_is_cleared_where_no_sheet_lies_beneath():
    sheet, under = pair()
    ink(under, (0, 39), (20, 60))
    drop, _ = joins.find_drop(sheet, under)
    assert not (drop & (under[3] < 255)).any()
    assert not drop[39:].any()


def test_a_label_across_the_whole_overlap_is_crossed_without_an_error():
    sheet, under = pair()
    ink(under, (0, 40), (90, 110))
    drop, notes = joins.find_drop(sheet, under)
    assert notes


def test_sheets_that_disagree_everywhere_still_get_the_path_of_least_difference():
    sheet, under = pair(tint=(160, 180, 200))
    under[:3, 20:23] = sheet[:3, 20:23]          # the one strip where the two tints match
    label = ink(under, (0, 13), (20, 60))
    drop, notes = joins.find_drop(sheet, under)
    assert drop[:21].all() and not drop[21:].any()
    assert drop[label].all()
    assert any("north" in n and "moved" in n for n in notes)


def test_an_even_tint_step_keeps_the_fixed_outline_and_is_not_an_error():
    drop, notes = joins.find_drop(*pair(tint=(160, 180, 200)))
    assert not drop.any()
    assert [n for n in notes if "FIXED" in n] == []


def test_sheets_that_do_not_show_the_same_ground_fall_back():
    sheet, under = pair(tint=(40, 60, 50))
    under[:3, :6] = 0                            # worse still at the edge, so the best path is not the edge
    drop, notes = joins.find_drop(sheet, under)
    assert not drop.any()
    assert any("north" in n and "FIXED" in n for n in notes)


def test_a_thin_overlap_falls_back_and_says_so():
    sheet, under = pair(depth=6)
    ink(under, (0, 3), (20, 60))
    drop, notes = joins.find_drop(sheet, under)
    assert not drop.any()
    assert any("north" in n and "FIXED" in n and "thin" in n for n in notes)


def test_a_corner_where_the_mosaic_wraps_two_sides():
    sheet, under = flat(120, 200), flat(120, 200)
    under[:, 40:, 40:] = 0
    top = ink(under, (0, 13), (100, 140))
    left = ink(under, (60, 90), (0, 13))
    drop, _ = joins.find_drop(sheet, under)
    assert drop[top].all() and drop[left].all()
    assert not drop[40:, 40:].any()


def test_where_another_sheet_ends_mid_side_the_closing_cut_avoids_labels():
    sheet, under = flat(120, 200), flat(120, 200, (160, 180, 200))
    under[:, 40:] = 0
    under[:, :, :100] = 0                        # the mosaic beneath covers only the right part of the top side
    under[:3, 20:23, 100:] = sheet[:3, 20:23, 100:]
    own = ink(sheet, (5, 16), (95, 109))         # a label of the sheet across the end of the overlap
    drop, _ = joins.find_drop(sheet, under)
    assert not drop[own].any()
    assert drop[:21, 140:].all()


def test_the_same_input_gives_the_same_answer():
    rng = np.random.default_rng(7)
    sheet, under = pair()
    sheet[:3] = 100 + rng.integers(0, 40, sheet[:3].shape, dtype=np.uint8)
    under[:3, :40] = 100 + rng.integers(0, 40, under[:3, :40].shape, dtype=np.uint8)
    first, said = joins.find_drop(sheet.copy(), under.copy())
    second, said_again = joins.find_drop(sheet.copy(), under.copy())
    assert first.any()
    assert np.array_equal(first, second) and said == said_again


def slanted(height=400, width=600, rise=12):
    """A sheet whose top edge lies `rise` cells lower at its west end, as real outlines do."""
    sheet = flat(height, width)
    top = np.round(np.linspace(rise, 0, width)).astype(int)
    sheet[:, np.arange(height)[:, None] < top[None, :]] = 0
    return sheet


def leaning(height=200, width=300, rise=10):
    """A sheet whose top edge rises steeply to the east, over a mosaic that covers its top and left strips."""
    sheet, under = flat(height, width), flat(height, width)
    under[:, 40:, 40:] = 0
    for col in range(width):
        sheet[:, :(width - 1 - col) // rise, col] = 0
    return sheet, under


def test_a_side_pass_leaves_an_overlap_on_another_side_alone():
    sheet, under = slanted(), flat(400, 600, (160, 180, 200))
    under[:, 60:] = 0
    under[:, :, 240:] = 0                        # the mosaic beneath covers the west part of the top side only
    under[:3, 30:33, :240] = sheet[:3, 30:33, :240]
    drop, notes = joins.find_drop(sheet, under)
    assert drop[:31, 20:200].sum() > 0 and not drop[32:].any()
    assert [n for n in notes if n.startswith(("west", "east")) and ("moved" in n or "FIXED" in n)] == []


def test_a_slanted_top_edge_does_not_stop_the_west_side():
    sheet, under = slanted(), flat(400, 600)
    under[:, 60:, 60:] = 0                       # the mosaic beneath wraps the north and west sides
    label = ink(under, (200, 230), (0, 14))
    drop, notes = joins.find_drop(sheet, under)
    assert drop[label].all()
    assert [n for n in notes if "FIXED" in n] == []


def test_a_side_pass_does_not_take_over_the_overlap_of_another_side():
    sheet, under = flat(120, 200), flat(120, 200)
    under[:, 40:] = 0
    under[:, :, 60:] = 0                         # the mosaic beneath covers only the left end of the top side
    for col in range(60):                        # the top edge rises to the east
        sheet[:, :(59 - col) // 4, col] = 0
    own = ink(sheet, (34, 44), (10, 30))         # a label of the sheet across the far edge of the overlap
    drop, _ = joins.find_drop(sheet, under)
    assert not drop[own].any()


def test_a_side_next_to_a_leaning_corner_still_gets_its_seam():
    sheet, under = leaning()
    left = ink(under, (100, 130), (0, 13))       # a label of the mosaic beneath across the sheet's west edge
    drop, _ = joins.find_drop(sheet, under)
    assert drop[left].all()


def test_no_strip_of_the_sheet_is_left_standing_beside_a_leaning_edge():
    sheet, under = pair()
    sheet[:, :100, 0] = 0                        # the west edge leans by one cell
    label = ink(under, (0, 13), (0, 30))
    drop, _ = joins.find_drop(sheet, under)
    assert drop[label & (sheet[3] > 0)].all()


def test_a_label_across_the_sheets_own_side_edge_is_shown_whole():
    sheet, under = pair()
    sheet[:, :, :2] = 0                          # the mosaic beneath carries on west of the sheet
    label = ink(under, (15, 28), (0, 12))
    drop, _ = joins.find_drop(sheet, under)
    assert drop[label & (sheet[3] > 0)].all()


def test_a_label_just_inside_the_sheets_edge_at_a_corner_is_not_split():
    sheet, under = flat(900, 400), flat(900, 400)
    sheet[:, :12] = 0
    sheet[:, :, 388:] = 0                        # the mosaic beneath carries on north and east of the sheet
    under[:, :, :248] = 0                        # and covers a strip along its east side
    own = ink(sheet, (13, 19), (228, 268))       # a label of the sheet one cell below its edge, across the strip's end
    drop, _ = joins.find_drop(sheet, under)
    assert not drop[own].any()


def test_a_label_just_inside_the_edge_of_a_shallow_side_strip_is_not_split():
    sheet, under = flat(300, 400), flat(300, 400)
    sheet[:, :12] = 0
    sheet[:, :, 388:] = 0
    under[:, :, :372] = 0                        # a strip sixteen cells deep along the east side
    own = ink(sheet, (13, 20), (372, 382))
    drop, _ = joins.find_drop(sheet, under)
    assert not drop[own].any()


def test_a_deep_narrow_overlap_in_the_middle_of_a_side_says_it_fell_back():
    sheet, under = flat(240, 400), flat(240, 400)
    under[:, 70:] = 0
    under[:, :, :180] = 0
    under[:, :, 220:] = 0                        # a box forty cells wide and seventy deep, away from both corners
    ink(under, (0, 13), (190, 210))
    drop, notes = joins.find_drop(sheet, under)
    assert not drop.any()
    assert [n for n in notes if "FIXED" in n] == ["north 181-219: FIXED, overlap deeper than it is long"]


def test_the_end_of_a_side_strip_seen_from_the_next_side_is_not_a_fallback():
    sheet, under = flat(240, 400), flat(240, 400)
    under[:, :, :360] = 0                        # a strip along the east side, which the east pass moves
    ink(under, (100, 140), (386, 400))
    drop, notes = joins.find_drop(sheet, under)
    assert drop.any()
    assert [n for n in notes if "FIXED" in n] == []
    assert sum("the end of a neighbouring side's overlap" in n for n in notes) == 2


def test_a_step_in_the_sheets_edge_gives_each_part_its_own_seam():
    sheet, under = flat(120, 200), flat(120, 200)
    sheet[:, :50, :100] = 0                      # the west half of the sheet starts fifty cells lower
    under[:, 95:] = 0
    low = ink(under, (45, 62), (20, 60))
    high = ink(under, (0, 13), (130, 170))
    drop, notes = joins.find_drop(sheet, under)
    assert drop[low & (sheet[3] > 0)].all() and drop[high].all()
    assert [n for n in notes if n.startswith("north") and "FIXED" in n] == []


def test_a_leaning_corner_never_gives_the_whole_strip_away():
    sheet, under = leaning()
    own = ink(sheet, (34, 44), (150, 170))       # a label of the sheet across the far edge of the top overlap
    drop, _ = joins.find_drop(sheet, under)
    assert not drop[own].any()


def test_each_path_says_how_much_of_it_lies_on_differing_cells():
    sheet, under = pair()
    ink(under, (0, 40), (90, 110))               # twenty of two hundred columns cannot be passed cleanly
    _, notes = joins.find_drop(sheet, under)
    assert any(n.startswith("north") and n.endswith(", 10% of it on differing cells") for n in notes)
    sheet, under = pair(tint=(160, 180, 200))
    under[:3, 20:23] = sheet[:3, 20:23]
    _, notes = joins.find_drop(sheet, under)
    assert any(n.startswith("north") and "moved" in n and n.endswith(", 0% of it on differing cells") for n in notes)


def test_a_hole_in_the_mosaic_beneath_is_never_uncovered():
    sheet, under = pair()
    ink(under, (0, 25), (60, 140))               # pushes the join down to the rows of the hole
    under[:, 10:30, 100] = 0
    drop, _ = joins.find_drop(sheet, under)
    assert drop.any()
    assert not (drop & (under[3] < 255)).any()


def test_a_sheet_with_nothing_beneath_it_is_left_alone():
    sheet, under = flat(120, 200), np.zeros((4, 120, 200), np.uint8)
    drop, notes = joins.find_drop(sheet, under)
    assert not drop.any() and notes == []


def test_a_sheet_wholly_inside_the_mosaic_beneath_keeps_its_outline_on_an_even_tint_step():
    drop, notes = joins.find_drop(flat(120, 200), flat(120, 200, (180, 200, 220)))
    assert not drop.any()
    assert [n for n in notes if "FIXED" in n] == []


def test_soft_alpha_beneath_counts_as_nothing_beneath():
    sheet, under = pair()
    ink(under, (0, 13), (20, 60))
    under[3, 5:15, 100:110] = 254
    drop, _ = joins.find_drop(sheet, under)
    assert drop.any()
    assert not (drop & (under[3] < 255)).any()


def test_spread_takes_the_largest_of_the_nine_cells_around_each_cell():
    cells = np.zeros((5, 6), np.uint8)
    cells[2, 3], cells[0, 0] = 9, 4
    want = np.zeros((5, 6), np.uint8)
    want[1:4, 2:5], want[:2, :2] = 9, 4
    assert np.array_equal(joins.spread(cells), want)
    assert joins.spread(cells).dtype == np.uint8


def test_the_seam_finder_holds_few_bytes_for_each_cell():
    import tracemalloc
    sheet, under = pair(height=600, width=900, depth=200)
    ink(under, (0, 50), (100, 300))
    tracemalloc.start()
    joins.find_drop(sheet, under)
    peak = tracemalloc.get_traced_memory()[1]
    tracemalloc.stop()
    assert peak / (600 * 900) < 40


needs_gdal = pytest.mark.skipif(shutil.which("gdalwarp") is None or shutil.which("gdalbuildvrt") is None,
                                reason="needs the GDAL tools")


@pytest.fixture(autouse=True)
def no_failures_left_over(monkeypatch):
    monkeypatch.setattr(joins, "FAILED", [], raising=False)


def read(path):
    from osgeo import gdal
    return gdal.Open(str(path)).ReadAsArray()


def shown(sheets):
    """Where any of the sheets shows a pixel, over a window wider than all of them."""
    from chartpipe import joincheck
    return joincheck.owners(sheets, -10, -10, 720, 620) >= 0


def two_sheets(folder, write_sheet):
    """A sheet stacked over the bottom of another. The upper one has a legend margin outside its outline."""
    folder.mkdir()
    lower = flat(320, 400)
    label = ink(lower, (212, 240), (150, 230))   # crosses the upper sheet's fixed edge at row 222
    upper = flat(400, 380)
    upper[0, :20] = 255                          # legend colours outside the outline
    upper[1:, :20] = 0
    a = write_sheet(folder / "v_a.tif", 0, 0, lower)
    b = write_sheet(folder / "v_b.tif", 6, 202, upper)
    return a, b, label


def three_sheets(folder, write_sheet):
    """The same two, and a third stacked over the east side of both with a label of the first across its edge."""
    folder.mkdir()
    lower = flat(320, 400)
    ink(lower, (212, 240), (150, 230))
    ink(lower, (120, 150), (285, 330))           # crosses the third sheet's fixed edge at column 300
    upper = flat(400, 380)
    upper[:, :20] = 0
    return (write_sheet(folder / "v_a.tif", 0, 0, lower), write_sheet(folder / "v_b.tif", 6, 202, upper),
            write_sheet(folder / "v_c.tif", 300, 40, flat(300, 300)))


@needs_gdal
def test_the_label_is_whole_after_trimming_and_was_cut_before(tmp_path, write_sheet):
    from chartpipe import joincheck
    a, b, label = two_sheets(tmp_path / "w", write_sheet)
    assert (joincheck.owners([a, b], 0, 0, 400, 320)[label] == 1).any()
    joins.trim_layer([a, b], tmp_path / "w")
    assert (joincheck.owners([a, b], 0, 0, 400, 320)[label] == 0).all()


@needs_gdal
def test_trimming_only_clears_alpha_and_never_touches_colour(tmp_path, write_sheet):
    a, b, _ = two_sheets(tmp_path / "w", write_sheet)
    before_a, before_b = read(a), read(b)
    joins.trim_layer([a, b], tmp_path / "w")
    after_a, after_b = read(a), read(b)
    assert np.array_equal(after_a, before_a)
    assert np.array_equal(after_b[:3], before_b[:3])
    assert (after_b[3] <= before_b[3]).all()
    assert not after_b[3, :20].any()
    assert (after_b[3] < before_b[3]).any()


@needs_gdal
def test_trimming_leaves_no_gap(tmp_path, write_sheet):
    a, b, _ = two_sheets(tmp_path / "w", write_sheet)
    before = shown([a, b])
    joins.trim_layer([a, b], tmp_path / "w")
    assert np.array_equal(shown([a, b]), before)
    sheets = three_sheets(tmp_path / "three", write_sheet)
    before = shown(sheets)
    joins.trim_layer(list(sheets), tmp_path / "three")
    assert np.array_equal(shown(sheets), before)


@needs_gdal
def test_a_label_shown_whole_over_the_join_of_two_sheets_beneath_stays_whole(tmp_path, write_sheet, capsys):
    from chartpipe import joincheck
    west, east = flat(400, 400), flat(400, 412)
    ink(west, (212, 232), (360, 400))            # cut at column 388, where the east sheet takes over
    west[:3, 196:204, 300:] -= 40                # a faint band on both sheets beneath, across the top sheet's edge
    east[:3, 196:204, :82] -= 40
    top = flat(400, 880)
    whole = ink(top, (12, 32), (400, 460))       # the cut label, printed whole
    sheets = [write_sheet(tmp_path / "v_a.tif", 0, 0, west), write_sheet(tmp_path / "v_b.tif", 388, 0, east),
              write_sheet(tmp_path / "v_c.tif", -40, 200, top)]
    joins.trim_layer(sheets, tmp_path)
    said = capsys.readouterr().out.splitlines()
    assert "join v_b west 0-100: FIXED, overlap too thin" in said
    assert [line for line in said if line.startswith("join v_c north") and "moved" in line]
    assert (joincheck.owners(sheets, -40, 200, 880, 400)[whole] == 2).all()


@needs_gdal
def test_a_sheet_with_a_slanted_edge_is_trimmed_like_any_other(tmp_path, write_sheet):
    from chartpipe import joincheck
    lower = flat(320, 400)
    label = ink(lower, (212, 240), (150, 230))   # crosses the slanted edge, which lies near row 214 here
    a = write_sheet(tmp_path / "v_a.tif", 0, 0, lower)
    b = write_sheet(tmp_path / "v_b.tif", 6, 202, slanted(400, 380, 24))
    before, alpha = shown([a, b]), read(b)[3]
    assert (joincheck.owners([a, b], 0, 0, 400, 320)[label] == 1).any()
    joins.trim_layer([a, b], tmp_path)
    assert (joincheck.owners([a, b], 0, 0, 400, 320)[label] == 0).all()
    assert np.array_equal(shown([a, b]), before)
    assert (read(b)[3] <= alpha).all()


@needs_gdal
def test_a_second_run_gives_the_same_alpha(tmp_path, write_sheet):
    alphas = []
    for folder in ("one", "two"):
        a, b, c = three_sheets(tmp_path / folder, write_sheet)
        joins.trim_layer([a, b, c], tmp_path / folder)
        alphas.append((read(b)[3], read(c)[3]))
    assert np.array_equal(alphas[0][0], alphas[1][0]) and np.array_equal(alphas[0][1], alphas[1][1])
    assert (alphas[0][1] == 0).any()


@needs_gdal
def test_nothing_is_cleared_where_no_chart_lies_beneath(tmp_path, write_sheet, monkeypatch, capsys):
    a, b, _ = two_sheets(tmp_path / "w", write_sheet)
    before = shown([a, b])
    monkeypatch.setattr(joins, "find_drop", lambda sheet, *rest: (np.ones(sheet.shape[1:], bool), []))
    joins.trim_layer([a, b], tmp_path / "w")
    assert np.array_equal(shown([a, b]), before)
    assert (read(b)[3, 20:118] == 0).all() and (read(b)[3, 118:] == 255).all()
    assert "join v_b kept 107160 pixels that have no chart beneath them" in capsys.readouterr().out


@needs_gdal
def test_a_hairline_with_nothing_beneath_does_not_stop_the_build(tmp_path, write_sheet):
    lower = flat(320, 400)
    ink(lower, (212, 240), (150, 230))
    lower[:, 224:230, 190] = 0                   # a one pixel hole in the sheet beneath, where the join will move
    upper = flat(400, 380)
    upper[:, :20] = 0
    a = write_sheet(tmp_path / "v_a.tif", 0, 0, lower)
    b = write_sheet(tmp_path / "v_b.tif", 6, 202, upper)
    before = shown([a, b])
    joins.trim_layer([a, b], tmp_path)
    assert np.array_equal(shown([a, b]), before)
    assert (read(b)[3] == 0).sum() > 20 * 380


@needs_gdal
def test_soft_alpha_beneath_is_never_uncovered(tmp_path, write_sheet):
    lower = flat(320, 400)
    ink(lower, (212, 240), (150, 230))
    lower[3, 226:236, 180:190] = 254             # under the label, where the join would move
    upper = flat(400, 380)
    upper[:, :20] = 0
    a = write_sheet(tmp_path / "v_a.tif", 0, 0, lower)
    b = write_sheet(tmp_path / "v_b.tif", 6, 202, upper)
    joins.trim_layer([a, b], tmp_path)
    assert (read(b)[3, 24:34, 174:184] == 255).all()
    assert (read(b)[3] == 0).sum() > 20 * 380


@needs_gdal
def test_a_sheet_far_from_every_other_is_left_alone(tmp_path, write_sheet, capsys):
    a = write_sheet(tmp_path / "v_a.tif", 0, 0, flat(100, 100))
    b = write_sheet(tmp_path / "v_b.tif", 5000, 5000, flat(100, 100))
    before = read(b)
    joins.trim_layer([a, b], tmp_path)
    assert np.array_equal(read(b), before)
    assert "joins: 0 moved, 0 left on the fixed outline, 0 sheets failed" in capsys.readouterr().out


@needs_gdal
def test_a_sheet_inside_another_keeps_its_outline_on_an_even_tint_step(tmp_path, write_sheet):
    a = write_sheet(tmp_path / "v_a.tif", 0, 0, flat(400, 400))
    b = write_sheet(tmp_path / "v_b.tif", 100, 100, flat(200, 200, (180, 200, 220)))
    before = read(b)
    joins.trim_layer([a, b], tmp_path)
    assert np.array_equal(read(b), before)


@needs_gdal
def test_the_log_names_each_stretch_and_gives_the_time_and_the_memory(tmp_path, write_sheet, capsys):
    a, b, _ = two_sheets(tmp_path / "w", write_sheet)
    joins.trim_layer([a, b], tmp_path / "w")
    said = capsys.readouterr().out
    assert "join v_b north" in said and "moved" in said
    last = said.splitlines()[-1]
    assert last.startswith("joins: 1 moved, 0 left on the fixed outline, 0 sheets failed, ")
    assert last.endswith(" MB at peak") and " s, " in last
    assert 20 < float(last.split()[-4]) < 4000


@needs_gdal
def test_a_sheet_whose_joins_fail_keeps_its_fixed_outline_and_the_rest_go_on(tmp_path, write_sheet, monkeypatch, capsys):
    a, b, c = three_sheets(tmp_path / "w", write_sheet)
    before_b, before_c, real, calls = read(b), read(c), joins.find_drop, []

    def fails_once(*args):
        calls.append(1)
        if len(calls) == 1:
            raise ValueError("odd overlap")
        return real(*args)

    monkeypatch.setattr(joins, "find_drop", fails_once)
    joins.trim_layer([a, b, c], tmp_path / "w")
    said = capsys.readouterr().out
    assert np.array_equal(read(b), before_b)
    assert (read(c)[3] < before_c[3]).any()
    assert "join v_b all sides: FIXED, ValueError: odd overlap" in said
    assert "1 sheets failed" in said
    assert joins.FAILED == ["v_b"]


@needs_gdal
def test_a_join_step_that_fails_on_every_sheet_names_them_all_and_raises_nothing(tmp_path, write_sheet, monkeypatch):
    def broken(*args):
        raise ImportError("no numpy")

    sheets = three_sheets(tmp_path / "w", write_sheet)
    before = [read(sheet) for sheet in sheets]
    monkeypatch.setattr(joins, "trim", broken)
    joins.trim_layer(list(sheets), tmp_path / "w")
    assert joins.FAILED == ["v_b", "v_c"]
    assert all(np.array_equal(read(sheet), was) for sheet, was in zip(sheets, before))


@needs_gdal
def test_a_failure_part_way_through_writing_puts_the_alpha_back(tmp_path, write_sheet, monkeypatch):
    a, b, _ = two_sheets(tmp_path / "w", write_sheet)
    before, real, calls = read(b), joins.window, []

    def fails_on_the_second_block(*args):
        calls.append(1)
        if len(calls) == 2:
            raise OSError("read failed")
        return real(*args)

    monkeypatch.setattr(joins, "BLOCK", 64)
    monkeypatch.setattr(joins, "window", fails_on_the_second_block)
    joins.trim_layer([a, b], tmp_path / "w")
    assert len(calls) == 2
    assert np.array_equal(read(b), before)
    assert joins.FAILED == ["v_b"]


@needs_gdal
def test_a_write_that_fails_leaves_the_sheet_as_it_was(tmp_path, write_sheet):
    import resource
    folder = tmp_path / "w"
    folder.mkdir()
    # Noise that agrees between the sheets but does not compress, so every rewritten block is appended.
    canvas = np.random.default_rng(3).integers(150, 250, (4, 2400, 1600), dtype=np.uint8)
    canvas[3] = 255
    lower, upper = canvas[:, :1400].copy(), canvas[:, 1000:].copy()
    lower[:3, 960:1100, 300:1300] = 0            # crosses the upper sheet's fixed edge at row 1000
    a = write_sheet(folder / "v_a.tif", 0, 0, lower)
    b = write_sheet(folder / "v_b.tif", 0, 1000, upper)
    before, (soft, hard) = read(b), resource.getrlimit(resource.RLIMIT_FSIZE)
    # A file that may not grow stands in for a full disk.
    resource.setrlimit(resource.RLIMIT_FSIZE, (b.stat().st_size + 700_000, hard))
    try:
        joins.trim_layer([a, b], folder)
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, (soft, hard))
    assert joins.FAILED == ["v_b"]
    assert np.array_equal(read(b), before)


@needs_gdal
def test_the_seam_step_leaves_no_files_behind(tmp_path, write_sheet):
    a, b, _ = two_sheets(tmp_path / "w", write_sheet)
    joins.trim_layer([a, b], tmp_path / "w")
    assert sorted(p.name for p in (tmp_path / "w").iterdir()) == ["v_a.tif", "v_b.tif"]


def test_cell_box_grows_outward_to_whole_cells():
    box, left, top = joins.cell_box((60.0, 10.0, 0, -2020.0, 0, -10.0), 380, 400)
    assert box == (40.0, -6040.0, 3880.0, -2000.0)
    assert (left, top) == (2, 2)


def test_block_mask_turns_cells_into_the_pixels_of_one_block():
    drop = np.zeros((3, 3), bool)
    drop[1, 2] = True
    got = joins.block_mask(drop, 2, 6, 5, 5)
    want = np.zeros((5, 5), bool)
    want[2:, 2:] = True
    assert np.array_equal(got, want)
