import zlib

from tppipe import geo

# A plate laid out like the FAA's: lon = -87 + x/1000, lat = 33 + y/1000 in page points.
LINES = [(5, 5, 395, 5), (5, 595, 395, 595),                       # page border, ignored
         (20, 40, 380, 40), (20, 480, 380, 480), (20, 500, 380, 500),  # full width rules
         (20, 170, 260, 170),                                       # profile top, stops at the sketch
         (260, 40, 260, 235)]                                       # sketch's left edge


def plate(lines=LINES, vp=True) -> bytes:
    content = b"q 1 0 0 1 0 0 cm\n" + b"".join(b"%g %g m %g %g l S\n" % l for l in lines) + b"Q\n"
    gpts = b" ".join(b"%g %g" % (33 + y / 1000, -87 + x / 1000) for x, y in ((40, 60), (360, 60), (360, 540), (40, 540)))
    view = (b"/VP[<</BBox[0 0 400 600]/Measure<</GPTS[" + gpts + b"]/LPTS[0.1 0.1 0.9 0.1 0.9 0.9 0.1 0.9]"
            b"/Subtype/GEO/Type/Measure>>/Type/Viewport>>]") if vp else b""
    stream = zlib.compress(content)
    return (b"%PDF-1.4\n3 0 obj\n<</Contents[4 0 R]/MediaBox[0 0 400 600]/Rotate 0/Type/Page" + view + b">>\nendobj\n"
            b"4 0 obj\n<</Filter/FlateDecode/Length %d>>stream\n" % len(stream) + stream + b"\nendstream\nendobj\n")


def test_plan_view_corners_come_from_the_geospatial_viewport():
    assert geo.georef(plate()) == {
        "corners": [[-86.98, 33.48], [-86.62, 33.48], [-86.62, 33.17], [-86.98, 33.17]],
        "plan": [0.05, 0.2, 0.95, 0.7167],
        "sketch": [0.65, 0.6083, 0.95, 0.7167]}


def test_a_broken_briefing_rule_still_tops_the_plan_view_and_boxed_insets_are_masked():
    # The rule under the briefing strip broken by a boxed frequency; an inset hung off the top right corner.
    lines = [line for line in LINES if line[1] != 480] + [(20, 480, 150, 480), (240, 480, 380, 480),
                                                          (300, 480, 300, 420), (300, 420, 380, 420)]
    found = geo.georef(plate(lines))
    assert found["plan"] == [0.05, 0.2, 0.95, 0.7167]
    assert found["insets"] == [[0.75, 0.2, 0.95, 0.3]]


def test_a_plate_without_a_viewport_or_plan_view_has_no_georef():
    assert geo.georef(plate(vp=False)) is None
    assert geo.georef(plate(lines=LINES[:2])) is None
