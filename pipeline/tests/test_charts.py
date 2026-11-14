import pytest

from chartpipe import charts


def test_classifies_by_suffix():
    assert charts.classify("Dallas-Ft Worth SEC.tif") == ("sectional", "dallas_ft_worth")
    assert charts.classify("Dallas-Ft Worth TAC.tif") == ("terminal", "dallas_ft_worth")
    assert charts.classify("St Louis TAC.tif") == ("terminal", "st_louis")
    assert charts.classify("Dallas-Ft Worth FLY.tif") == ("flyway", "dallas_ft_worth")
    assert charts.classify("readme.htm") is None


def make_outlines(tmp_path, names):
    for kind, slug in names:
        (tmp_path / kind).mkdir(exist_ok=True)
        (tmp_path / kind / f"{slug}.shp").write_bytes(b"")
    return tmp_path


def test_plan_pairs_images_with_outlines(tmp_path):
    outlines = make_outlines(tmp_path, [("sectional", "houston"), ("terminal", "houston")])
    result = charts.plan(["Houston SEC.tif", "Houston TAC.tif", "Houston FLY.tif"], outlines)
    assert result == [
        ("Houston FLY.tif", "flyway", None),
        ("Houston SEC.tif", "sectional", outlines / "sectional" / "houston.shp"),
        ("Houston TAC.tif", "terminal", outlines / "terminal" / "houston.shp"),
    ]


def test_plan_stops_and_names_every_image_without_an_outline(tmp_path):
    outlines = make_outlines(tmp_path, [("sectional", "houston")])
    with pytest.raises(charts.MissingOutline) as error:
        charts.plan(["Houston SEC.tif", "Nowhere SEC.tif", "Elsewhere TAC.tif"], outlines)
    assert "Nowhere SEC.tif" in str(error.value)
    assert "Elsewhere TAC.tif" in str(error.value)


def test_skip_list_is_honoured(tmp_path, monkeypatch):
    outlines = make_outlines(tmp_path, [("sectional", "houston")])
    monkeypatch.setitem(charts.SKIP, "Nowhere SEC.tif", "test reason")
    assert len(charts.plan(["Houston SEC.tif", "Nowhere SEC.tif"], outlines)) == 1


def test_an_edition_short_of_images_is_refused():
    names = [f"Chart {i} {suffix}.tif" for suffix, kind in (("SEC", "sectional"), ("TAC", "terminal"))
             for i in range(charts.EXPECTED[kind])]
    charts.check_complete(names + ["Houston FLY.tif"])
    # Wrong case and a changed separator both leave the count one short.
    with pytest.raises(charts.Incomplete) as error:
        charts.check_complete(names[1:] + ["Chart 0 SEC.TIFF", "Chart_0_SEC.tif"])
    assert "sectional" in str(error.value) and "terminal" not in str(error.value)


def test_classifies_enroute_sheets_by_name():
    assert charts.classify("ENR_L17.tif") == ("enroute_low", "enr_l17")
    assert charts.classify("ENR_L06N.tif") == ("enroute_low", "enr_l06n")
    assert charts.classify("ENR_L23_WILM_INSET.tif") == ("enroute_low", "enr_l23_wilm_inset")
    assert charts.classify("ENR_A02_DFW.tif") == ("enroute_area", "enr_a02_dfw")
    assert charts.classify("ENR_H05.tif") == ("enroute_high", "enr_h05")
    assert charts.classify("ENR_AKL01.tif") is None
    assert charts.classify("ENR_AKH01.tif") is None
    assert charts.classify("ENR_L17.tfwx") is None


def test_enroute_sheets_need_no_outline_file(tmp_path):
    outlines = make_outlines(tmp_path, [("enroute_low", "enr_l17")])
    result = charts.plan(["ENR_L17.tif", "ENR_L19.tif", "ENR_A02_DFW.tif"], outlines)
    assert result == [
        ("ENR_A02_DFW.tif", "enroute_area", None),
        ("ENR_L17.tif", "enroute_low", outlines / "enroute_low" / "enr_l17.shp"),
        ("ENR_L19.tif", "enroute_low", None),
    ]


def test_inset_sheets_are_skipped(tmp_path):
    assert charts.plan(["ENR_L23_WILM_INSET.tif", "ENR_L34_BOST_INSET.tif"], tmp_path) == []
    assert "ENR_L23_WILM_INSET.tif" in charts.SKIP and "ENR_L34_BOST_INSET.tif" in charts.SKIP


def test_enroute_counts_are_checked_only_when_asked():
    low = [f"ENR_L{n:02d}.tif" for n in range(1, 40)]
    area = [f"ENR_A01_AB{chr(65 + n)}.tif" for n in range(14)]
    charts.check_complete(low + area, ("enroute_low", "enroute_area"))
    with pytest.raises(charts.Incomplete) as error:
        charts.check_complete(low[1:] + area, ("enroute_low", "enroute_area"))
    assert "38 enroute_low" in str(error.value)
    # Asked for nothing in particular, the check is still the one for visual charts.
    with pytest.raises(charts.Incomplete):
        charts.check_complete(low + area)
