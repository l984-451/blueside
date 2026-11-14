import io
import math
import shutil
import zipfile
import zlib

import pytest

from tppipe import diagram, dtpp

pytestmark = pytest.mark.skipif(not shutil.which("pdftotext") or not shutil.which("pdftoppm"), reason="needs poppler")

# Laid out like an FAA diagram: one minute of latitude every 200 points, longitude squeezed by cos(latitude).
LAT0, LON0, LAT_STEP, LON_STEP = 33 + 34 / 60, -(86 + 46 / 60), 200.0, 166.6


def lat(y):
    return LAT0 + (y - 150) / LAT_STEP / 60


def lon(x):
    return LON0 + (x - 100) / LON_STEP / 60


RUNWAY, CROSSING = ((150, 250), (250, 420)), ((90, 470), (330, 470))


def diagram_pdf(path, runway=RUNWAY, others=(), labeled=True, graticule=True, grid=((150, 350), (100, 100 + LON_STEP)),
                pieces=1):
    """A one page PDF: frame, graticule lines at grid's y and x with labels, one runway drawn thick (cut in pieces
    with gaps between) and any others as filled outlines."""
    lines = [(20, 40, 380, 40), (20, 560, 380, 560), (20, 40, 20, 560), (380, 40, 380, 560)]
    if graticule:
        lines += [(20, y, 380, y) for y in grid[0]] + [(x, 40, x, 560) for x in grid[1]]
    draw = b"".join(b"%g %g m %g %g l S\n" % line for line in lines)
    (x0, y0), (x1, y1) = runway
    for i in range(pieces):
        f0, f1 = (i + 0.04 * (i > 0)) / pieces, (i + 1 - 0.04 * (i < pieces - 1)) / pieces
        draw += b"6 w %g %g m %g %g l S 1 w\n" % (x0 + (x1 - x0) * f0, y0 + (y1 - y0) * f0,
                                                  x0 + (x1 - x0) * f1, y0 + (y1 - y0) * f1)
    for (x0, y0), (x1, y1) in others:
        size = math.dist((x0, y0), (x1, y1))
        dx, dy = (y0 - y1) / size * 3, (x1 - x0) / size * 3
        draw += b"%g %g m %g %g l %g %g l %g %g l f\n" % (x0 + dx, y0 + dy, x1 + dx, y1 + dy, x1 - dx, y1 - dy, x0 - dx, y0 - dy)
    for text, x, y in ((b"33\26034'N", 30, 147), (b"33\26035'N", 30, 347),
                       (b"86\26046'W", 100 - 15, 30), (b"86\26045'W", 100 + LON_STEP - 15, 30)) if labeled else ():
        draw += b"BT /F1 8 Tf %g %g Td (%s) Tj ET\n" % (x, y, text)
    objects = [b"<</Type/Catalog/Pages 2 0 R>>", b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
               b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 400 600]/Contents 4 0 R"
               b"/Resources<</Font<</F1 5 0 R>>>>>>",
               b"<</Filter/FlateDecode/Length %d>>stream\n" % len(packed := zlib.compress(draw))
               + packed + b"\nendstream",
               b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>"]
    out, offsets = io.BytesIO(), []
    out.write(b"%PDF-1.4\n")
    for number, body in enumerate(objects, 1):
        offsets.append(out.tell())
        out.write(b"%d 0 obj\n" % number + body + b"\nendobj\n")
    xref = out.tell()
    out.write(b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1))
    out.write(b"".join(b"%010d 00000 n \n" % o for o in offsets))
    out.write(b"trailer\n<</Size %d/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref))
    path.write_bytes(out.getvalue())
    return path


def ends(shift=0.0, runways=(RUNWAY,)):
    return [((lat(y0) + shift, lon(x0)), (lat(y1) + shift, lon(x1))) for (x0, y0), (x1, y1) in runways]


def assert_frame_placed(geo):
    expected = [[lon(20), lat(560)], [lon(380), lat(560)], [lon(380), lat(40)], [lon(20), lat(40)]]
    for got, want in zip(geo["corners"], expected):
        assert got == pytest.approx(want, abs=5e-6)


def test_the_printed_graticule_places_the_diagram_and_its_runway_checks_it(tmp_path):
    geo, outcome, miss = diagram.georef(diagram_pdf(tmp_path / "AD.PDF"), ends())
    assert outcome == "ok" and miss < 10
    assert geo["plan"] == [0.05, 0.0667, 0.95, 0.9333]
    expected = [[lon(20), lat(560)], [lon(380), lat(560)], [lon(380), lat(40)], [lon(20), lat(40)]]
    for got, want in zip(geo["corners"], expected):
        assert got == pytest.approx(want, abs=2e-6)


def test_a_diagram_whose_runway_is_not_where_the_survey_puts_it_is_refused(tmp_path):
    # 0.001 degrees of latitude is 111 m.
    geo, outcome, miss = diagram.georef(diagram_pdf(tmp_path / "AD.PDF"), ends(shift=0.001))
    assert geo is None and outcome == "runways" and miss > diagram.LIMIT_M


def test_a_runway_crossing_another_at_its_middle_still_checks(tmp_path):
    # Drawn across the runway's middle, off center so the look across there sees a lopsided dark run.
    path = diagram_pdf(tmp_path / "AD.PDF", others=[((150, 380), (230, 300))])
    geo, outcome, miss = diagram.georef(path, ends())
    assert outcome == "ok" and miss < 10


def test_unlabeled_graticule_lines_are_named_from_the_drawn_runway_that_matches_the_survey(tmp_path):
    # A taxiway-like mark nearby must not be taken for the runway.
    path = diagram_pdf(tmp_path / "AD.PDF", labeled=False, others=[((300, 100), (330, 300))])
    geo, outcome, miss = diagram.georef(path, ends())
    assert outcome == "ok" and miss < 10
    assert_frame_placed(geo)


def test_a_stray_line_beside_a_graticule_line_does_not_stop_the_runway_naming_it(tmp_path):
    path = diagram_pdf(tmp_path / "AD.PDF", labeled=False, grid=((150, 160, 350), (100, 100 + LON_STEP)))
    geo, outcome, miss = diagram.georef(path, ends())
    assert outcome == "ok" and miss < 10
    assert_frame_placed(geo)


def test_a_big_field_drawn_small_and_its_runway_in_pieces_is_placed(tmp_path):
    # Three minutes between graticule lines: 28 m a point, the scale of a field like Denver's.
    big = tuple((LAT0 + (lat(y) - LAT0) * 3, LON0 + (lon(x) - LON0) * 3) for x, y in RUNWAY)
    geo, outcome, miss = diagram.georef(diagram_pdf(tmp_path / "AD.PDF", labeled=False, pieces=3), [big])
    assert outcome == "ok" and miss < 30
    assert geo["corners"][0] == pytest.approx([LON0 + (lon(20) - LON0) * 3, LAT0 + (lat(560) - LAT0) * 3], abs=5e-6)


@pytest.mark.parametrize("drawn", [RUNWAY, RUNWAY[::-1]])
def test_one_runway_on_a_quarter_turned_diagram_is_placed_the_right_way_round(tmp_path, drawn):
    # Turned so north is to the right: latitude climbs with x, longitude with y going down.
    def turned(x, y):
        return LAT0 + (x - 100) / LAT_STEP / 60, LON0 - (y - 150) / LON_STEP / 60

    path = diagram_pdf(tmp_path / "AD.PDF", runway=drawn, labeled=False, grid=((150, 150 + LON_STEP), (100, 300)))
    geo, outcome, miss = diagram.georef(path, [tuple(turned(*e) for e in RUNWAY)])
    assert outcome == "ok" and miss < 10
    assert geo["corners"][0] == pytest.approx(turned(20, 560)[::-1], abs=5e-6)


def test_runways_alone_place_an_unlabeled_diagram_when_they_agree(tmp_path):
    path = diagram_pdf(tmp_path / "AD.PDF", labeled=False, graticule=False, others=[CROSSING])
    geo, outcome, miss = diagram.georef(path, ends(runways=(RUNWAY, CROSSING)))
    assert outcome == "ok" and miss < 10
    assert_frame_placed(geo)


def test_runways_that_disagree_with_the_survey_leave_an_unlabeled_diagram_off_the_map(tmp_path):
    path = diagram_pdf(tmp_path / "AD.PDF", labeled=False, graticule=False, others=[CROSSING])
    moved = ends(runways=(RUNWAY, CROSSING))
    # 0.0006 degrees of latitude is 67 m: one end of the crossing runway surveyed off its drawing.
    moved[1] = (moved[1][0], (moved[1][1][0] + 0.0006, moved[1][1][1]))
    assert diagram.georef(path, moved)[:2] == (None, "runways disagree")


def test_one_runway_without_graticule_lines_is_not_enough_to_place_a_diagram(tmp_path):
    path = diagram_pdf(tmp_path / "AD.PDF", labeled=False, graticule=False)
    assert diagram.georef(path, ends())[:2] == (None, "one runway")


def test_a_diagram_with_no_runways_to_check_against_is_left_off_the_map(tmp_path):
    assert diagram.georef(diagram_pdf(tmp_path / "AD.PDF"), [])[:2] == (None, "no runways")


def test_runway_end_pairs_come_from_the_nasr_csv(tmp_path):
    csv = ("ARPT_ID,RWY_ID,RWY_END_ID,LAT_DECIMAL,LONG_DECIMAL\n"
           "BHM,06/24,06,33.55,-86.77\nBHM,06/24,24,33.57,-86.73\nBHM,H1,H1,33.56,-86.75\n")
    with zipfile.ZipFile(tmp_path / "nasr.zip", "w") as archive:
        archive.writestr("APT_RWY_END.csv", csv)
    assert dtpp.runways(tmp_path / "nasr.zip") == {"BHM": [((33.55, -86.77), (33.57, -86.73))]}
