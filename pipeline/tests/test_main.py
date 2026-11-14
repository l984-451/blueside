import subprocess
import sys
from pathlib import Path

import pytest

from chartpipe import __main__ as cli
from chartpipe import build, charts, faa, ifr, joins, manifest, pack, publish

ONE_LINK = '<a href="https://aeronav.faa.gov/visual/09-03-2026/sectional-files/Houston.zip">x</a>'


def run_main(monkeypatch, tmp_path, html, *flags, posted=lambda url: True):
    monkeypatch.setattr(faa, "fetch", lambda url: html.encode())
    monkeypatch.setattr(cli.nasr, "exists", posted)
    monkeypatch.setattr(sys, "argv", ["chartpipe", "--work", str(tmp_path), *flags])
    return cli.main()


def test_only_refuses_to_publish(tmp_path):
    result = subprocess.run([sys.executable, "-m", "chartpipe", "--work", str(tmp_path), "--only", "Houston"],
                            capture_output=True, text=True, cwd=Path(__file__).parent.parent)
    assert result.returncode == 2 and "--only needs" in result.stderr


def test_page_without_chart_links_is_an_error(monkeypatch, tmp_path):
    with pytest.raises(SystemExit) as stop:
        run_main(monkeypatch, tmp_path, "<html>maintenance</html>", "--no-publish")
    assert stop.value.code not in (0, None)


def test_cycle_that_is_not_on_the_page_is_an_error(monkeypatch, tmp_path):
    with pytest.raises(SystemExit) as stop:
        run_main(monkeypatch, tmp_path, ONE_LINK, "--no-publish", "--cycle", "2026-9-3")
    assert stop.value.code == 2


def test_full_run_stops_when_the_edition_is_short_of_images(monkeypatch, tmp_path, capsys):
    outline = tmp_path / "outlines" / "sectional" / "houston.shp"
    outline.parent.mkdir(parents=True)
    outline.write_bytes(b"")
    monkeypatch.setattr(cli, "OUTLINES", tmp_path / "outlines")
    monkeypatch.setattr(cli, "download", lambda urls, zips, folder: [folder / "Houston SEC.tif"])
    # One chart is fine when asked for by name, and far too few for a whole edition.
    assert run_main(monkeypatch, tmp_path, ONE_LINK, "--plan-only", "--only", "Houston") == 0
    assert "sectional: Houston SEC.tif" in capsys.readouterr().out
    with pytest.raises(charts.Incomplete):
        run_main(monkeypatch, tmp_path, ONE_LINK, "--plan-only")


ALL_LAYERS = ["vfr", "vfr-tac", "ifr-low", "ifr-area", "ifr-high"]
BASE = {"street": "1", "terrain": "1"}


def run_with_live(monkeypatch, tmp_path, live_cycle, layers, *flags, base=BASE, posted=lambda url: True):
    """Run main against a manifest listing these layers for one cycle and these base layers at these versions.
    Returns what it built and published, and the keys it was asked to clean up after."""
    built, published, cleaned = [], [], []
    packs = [{"layer": layer, "region": "TX", "bytes": 1, "sha256": "ab" * 32} for layer in layers]
    live = {"version": 1, "cycles": [manifest.cycle_entry(live_cycle, packs)],
            "base": [p for layer, version in base.items()
                     for p in manifest.base_entries([{"layer": layer, "region": "TX", "bytes": 1, "sha256": "ab" * 32}], version)]}

    class Store:
        def read_manifest(self):
            return live

        def delete_unlisted(self, listed, now):
            cleaned.append(listed)
            return []

    def fake_build(cycle_id, urls, work, out, full):
        built.append((cycle_id, {layer: len(found) for layer, found in urls.items()}))
        return manifest.cycle_entry(cycle_id, []), {}

    def fake_base(urls, work, out):
        built.append(("base", {layer: len(found) for layer, found in urls.items()}))
        return [], {}

    monkeypatch.setattr(publish, "r2_store_from_env", lambda: Store())
    monkeypatch.setattr(publish, "publish_cycle", lambda store, entry, files, now, replace=(), force_size=False: published.append((entry["id"], *sorted(replace)) if replace else entry["id"]))
    monkeypatch.setattr(publish, "publish_base", lambda store, packs, files, now: published.append("base"))
    monkeypatch.setattr(cli, "build_cycle", fake_build)
    monkeypatch.setattr(cli, "build_base", fake_base)
    monkeypatch.setattr(pack, "missing_states", lambda packs, layer="vfr": [])
    code = run_main(monkeypatch, tmp_path, ONE_LINK, *flags, posted=posted)
    assert cleaned == [live]
    return code, built, published


def test_a_live_cycle_gets_only_the_layers_it_lacks(monkeypatch, tmp_path):
    code, built, published = run_with_live(monkeypatch, tmp_path, "2026-09-03", ["vfr", "vfr-tac"])
    assert code == 0
    assert built == [("2026-09-03", {"ifr-low": 36, "ifr-area": 2, "ifr-high": 12})]
    assert published == ["2026-09-03"]


def test_enroute_zips_not_posted_yet_leave_the_visual_layers_to_go_ahead(monkeypatch, tmp_path, capsys):
    late = lambda url: "/enroute/" not in url or "enr_h" in url
    code, built, published = run_with_live(monkeypatch, tmp_path, "2026-07-09", [], posted=late)
    assert code == 0
    assert built == [("2026-09-03", {"vfr": 1, "ifr-high": 12})]
    assert published == ["2026-09-03"]
    out = capsys.readouterr().out
    assert "2026-09-03: ifr-low not posted yet" in out and "2026-09-03: ifr-area not posted yet" in out


def test_a_cycle_with_every_layer_live_is_left_alone_and_cleaned_up_after(monkeypatch, tmp_path, capsys):
    code, built, published = run_with_live(monkeypatch, tmp_path, "2026-09-03", ALL_LAYERS)
    assert (code, built, published) == (0, [], [])
    assert "nothing new to build" in capsys.readouterr().out


def test_rebuild_builds_a_live_layer_again_and_has_it_replaced(monkeypatch, tmp_path):
    code, built, published = run_with_live(monkeypatch, tmp_path, "2026-09-03", ALL_LAYERS, "--rebuild", "vfr")
    assert code == 0
    assert built == [("2026-09-03", {"vfr": 1})]
    assert published == [("2026-09-03", "vfr")]


def test_base_layers_are_built_once_when_missing_or_at_an_old_version(monkeypatch, tmp_path):
    # Street is missing and terrain is listed at an old version: both are built once, outside any cycle.
    code, built, published = run_with_live(monkeypatch, tmp_path, "2026-09-03", ALL_LAYERS, base={"terrain": "0"})
    assert built == [("base", {"street": 1, "terrain": 52})]
    assert published == ["base"]


def test_rebuild_of_a_base_layer_builds_only_it(monkeypatch, tmp_path):
    code, built, published = run_with_live(monkeypatch, tmp_path, "2026-09-03", ALL_LAYERS, "--rebuild", "street")
    assert built == [("base", {"street": 1})]
    assert published == ["base"]


def test_rebuild_of_an_unknown_layer_is_an_error(monkeypatch, tmp_path):
    with pytest.raises(SystemExit):
        run_with_live(monkeypatch, tmp_path, "2026-09-03", ALL_LAYERS, "--rebuild", "sectional")


def test_a_cycle_that_is_not_live_gets_every_layer_with_zips(monkeypatch, tmp_path):
    code, built, published = run_with_live(monkeypatch, tmp_path, "2026-07-09", ALL_LAYERS)
    # The page in this test links one sectional zip and no terminal zip.
    assert built == [("2026-09-03", {"vfr": 1, "ifr-low": 36, "ifr-area": 2, "ifr-high": 12})]


def fake_layer_build(monkeypatch):
    """Replace every image step, and record the outline each sheet was trimmed with and the stacking order."""
    calls = {"cut": []}
    monkeypatch.setattr(ifr, "cutline", lambda src, fallback, out: out)
    monkeypatch.setattr(build, "warp", lambda src, outline, out, res, threads=0: calls["cut"].append(outline.name))
    monkeypatch.setattr(build, "mosaic", lambda tifs, vrt: calls.update(order=[t.name for t in tifs]))
    monkeypatch.setattr(build, "tile", lambda *args: None)
    for name in ("tiles_to_mbtiles", "to_pmtiles", "check_zooms"):
        monkeypatch.setattr(pack, name, lambda *args: None)
    monkeypatch.setattr(joins, "trim_layer", lambda order, work: calls.update(joined=[t.name for t in order]))
    return calls


def test_enroute_sheets_are_trimmed_to_their_frame_and_stacked_coarsest_first(monkeypatch, tmp_path):
    sizes = {"ENR_L17.tif": 46.3, "ENR_L21.tif": 106.49, "ENR_L04.tif": 32.41}
    calls = fake_layer_build(monkeypatch)
    monkeypatch.setattr(build, "info", lambda path: {"geoTransform": [0, sizes[path.name], 0, 0, 0, -sizes[path.name]]})
    cli.build_layer("ifr-low", [(tmp_path / name, None) for name in sizes], build.Z12, (4, 12), tmp_path)
    assert sorted(calls["cut"]) == ["ifr-low_ENR_L04.gpkg", "ifr-low_ENR_L17.gpkg", "ifr-low_ENR_L21.gpkg"]
    assert calls["order"] == ["ifr-low_ENR_L21.tif", "ifr-low_ENR_L17.tif", "ifr-low_ENR_L04.tif"]


def test_visual_charts_still_stack_by_name(monkeypatch, tmp_path):
    calls = fake_layer_build(monkeypatch)
    tifs = [(tmp_path / "Houston SEC.tif", tmp_path / "houston.shp"),
            (tmp_path / "Dallas-Ft Worth SEC.tif", tmp_path / "dallas_ft_worth.shp")]
    cli.build_layer("vfr", tifs, build.Z12, (4, 12), tmp_path)
    assert calls["order"] == ["vfr_dallas_ft_worth.tif", "vfr_houston.tif"]


def test_sectional_joins_are_moved_before_the_mosaic_in_stacking_order(monkeypatch, tmp_path):
    calls = fake_layer_build(monkeypatch)
    monkeypatch.setattr(build, "mosaic", lambda tifs, vrt: calls.update(order=[t.name for t in tifs],
                                                                        joined_first="joined" in calls))
    tifs = [(tmp_path / "Houston SEC.tif", tmp_path / "houston.shp"),
            (tmp_path / "Dallas-Ft Worth SEC.tif", tmp_path / "dallas_ft_worth.shp")]
    cli.build_layer("vfr", tifs, build.Z12, (4, 12), tmp_path)
    assert calls["joined"] == ["vfr_dallas_ft_worth.tif", "vfr_houston.tif"]
    assert calls["joined_first"]


def test_other_layers_keep_their_straight_edges(monkeypatch, tmp_path):
    calls = fake_layer_build(monkeypatch)
    cli.build_layer("vfr-tac", [(tmp_path / "Houston TAC.tif", tmp_path / "houston.shp")], build.Z13, (13, 13), tmp_path)
    monkeypatch.setattr(build, "info", lambda path: {"geoTransform": [0, 46.3, 0, 0, 0, -46.3]})
    cli.build_layer("ifr-low", [(tmp_path / "ENR_L17.tif", None)], build.Z12, (4, 12), tmp_path)
    assert "joined" not in calls
    assert cli.JOINED_LAYERS == ("vfr",)


def test_main_publishes_then_reports_the_sheets_whose_joins_failed(monkeypatch, tmp_path, capsys):
    def fake_build(cycle_id, urls, work, out, full):
        joins.FAILED.append("vfr_houston")
        return manifest.cycle_entry(cycle_id, []), {}

    monkeypatch.setattr(joins, "FAILED", [])
    monkeypatch.setattr(cli, "build_cycle", fake_build)
    # The packs are whole and published; the non-zero exit only raises the alert.
    assert run_main(monkeypatch, tmp_path, ONE_LINK, "--no-publish", "--only", "Houston") == 3
    assert capsys.readouterr().out.splitlines()[-1] == "joins left on the fixed outline for 2026-09-03 vfr_houston"
    assert joins.FAILED == []


def test_enroute_layers_have_the_agreed_zooms():
    assert cli.LAYERS["ifr-low"] == ("enroute_low", build.Z12, (4, 12))
    assert cli.LAYERS["ifr-area"] == ("enroute_area", build.Z13, (13, 13))
    assert cli.LAYERS["ifr-high"] == ("enroute_high", build.Z11, (4, 11))
    assert cli.BASE_LAYERS == ("vfr", "ifr-low", "ifr-high")


def test_street_packs_are_cut_from_the_newest_version_4_planet(monkeypatch, tmp_path):
    builds = [{"key": "20261013.pmtiles", "version": "4.15.2"}, {"key": "20261014.pmtiles", "version": "4.15.2"},
              {"key": "20261015.pmtiles", "version": "5.0.0"}]
    monkeypatch.setattr(faa, "fetch", lambda url: __import__("json").dumps(builds).encode())
    monkeypatch.setattr(cli, "plan_cycle", lambda *args: ({}, []))
    cut = []
    monkeypatch.setattr(cli, "cut_packs", lambda layer, source, zooms, out, work: cut.append((layer, source, zooms)) or
                        [{"layer": layer, "region": "TX", "bytes": 1, "sha256": "ab" * 32}])
    packs, files = cli.build_base({"street": [cli.PROTOMAPS_BUILDS]}, tmp_path / "work", tmp_path / "out")
    assert cut == [("street", "https://build.protomaps.com/20261014.pmtiles", (0, 14))]
    assert files == {"charts/base/street/TX-abababababababab.pmtiles": tmp_path / "out" / "street" / "TX.pmtiles"}
    assert packs[0]["version"] == cli.STREET_VERSION


def test_the_street_source_is_never_downloaded_as_a_zip(monkeypatch, tmp_path):
    got = []
    monkeypatch.setattr(cli, "download", lambda urls, zips, folder: got.extend(urls) or [])
    monkeypatch.setattr(charts, "check_complete", lambda *args: None)
    cli.plan_cycle("2026-09-03", {"ifr-high": ["h.zip"], "street": [cli.PROTOMAPS_BUILDS]}, tmp_path / "w", True)
    assert got == ["h.zip"]


def test_the_low_layer_gets_an_overview_and_the_area_layer_none(monkeypatch, tmp_path):
    sheets = {name: tmp_path / name for name in ("ENR_L17.tif", "ENR_A02_DFW.tif")}
    planned = [("ENR_A02_DFW.tif", "enroute_area", None), ("ENR_L17.tif", "enroute_low", None)]
    monkeypatch.setattr(cli, "plan_cycle", lambda *args: (sheets, planned))
    monkeypatch.setattr(ifr, "check", lambda *args: None)
    monkeypatch.setattr(cli, "build_layer", lambda layer, *args: tmp_path / f"{layer}.pmtiles")
    monkeypatch.setattr(cli, "cut_packs", lambda layer, *args: [{"layer": layer, "region": "TX", "bytes": 1, "sha256": "ab" * 32}])
    monkeypatch.setattr(pack, "extract_overview", lambda *args: None)
    monkeypatch.setattr(pack, "check_zooms", lambda *args: None)
    monkeypatch.setattr(pack, "describe", lambda path: (2, "cd" * 32))
    entry, files = cli.build_cycle("2026-09-03", {"ifr-low": ["x"], "ifr-area": ["y"]}, tmp_path / "work", tmp_path / "out", False)
    assert [(p["layer"], p["region"]) for p in entry["packs"]] == [("ifr-low", "TX"), ("ifr-low", "overview"), ("ifr-area", "TX")]
    assert files["charts/2026-09-03/ifr-low/overview.pmtiles"] == tmp_path / "out" / "ifr-low" / "overview.pmtiles"


def test_a_sheet_without_frame_or_shape_stops_the_build_before_any_layer(monkeypatch, tmp_path):
    planned = [("ENR_A02_DFW.tif", "enroute_area", None)]
    monkeypatch.setattr(cli, "plan_cycle", lambda *args: ({"ENR_A02_DFW.tif": tmp_path / "ENR_A02_DFW.tif"}, planned))
    monkeypatch.setattr(ifr, "dark_counts", lambda tif: ([0] * 100, [0] * 100, 100, 100))
    monkeypatch.setattr(cli, "build_layer", lambda *args: pytest.fail("a layer was built"))
    with pytest.raises(charts.MissingOutline):
        cli.build_cycle("2026-09-03", {"vfr": ["v"], "ifr-area": ["y"]}, tmp_path / "work", tmp_path / "out", False)


def lined_sheet(horizontal, vertical):
    """Dark counts of a 24000 by 8000 sheet with full-length lines at these (first, last) rows and columns."""
    rows, cols = [0] * 8000, [0] * 24000
    for first, last in horizontal:
        rows[first:last + 1] = [21000] * (last - first + 1)
    for first, last in vertical:
        cols[first:last + 1] = [7000] * (last - first + 1)
    return rows, cols, 24000, 8000


def test_a_frame_with_gaps_stops_the_build_before_any_layer_even_with_a_shape(monkeypatch, tmp_path):
    planned = [("ENR_L17.tif", "enroute_low", tmp_path / "enr_l17.shp")]
    monkeypatch.setattr(cli, "plan_cycle", lambda *args: ({"ENR_L17.tif": tmp_path / "ENR_L17.tif"}, planned))
    monkeypatch.setattr(ifr, "dark_counts", lambda tif: lined_sheet([(251, 259), (7732, 7740)], [(196, 204), (23798, 23806)]))
    monkeypatch.setattr(ifr, "edge_shares", lambda tif, shape: (1.0, 0.56, 0.91, 0.74))
    monkeypatch.setattr(cli, "build_layer", lambda *args: pytest.fail("a layer was built"))
    with pytest.raises(charts.MissingOutline):
        cli.build_cycle("2026-09-03", {"vfr": ["v"], "ifr-low": ["x"]}, tmp_path / "work", tmp_path / "out", False)


def test_a_sheet_without_a_frame_passes_the_early_check_when_it_has_a_shape(monkeypatch, tmp_path):
    monkeypatch.setattr(ifr, "dark_counts", lambda tif: lined_sheet([], []))
    ifr.check(tmp_path / "ENR_L17.tif", tmp_path / "enr_l17.shp")
    with pytest.raises(charts.MissingOutline):
        ifr.check(tmp_path / "ENR_L17.tif", None)


def test_main_names_the_sheets_trimmed_with_a_fallback_outline(monkeypatch, tmp_path, capsys):
    def fake_build(cycle_id, urls, work, out, full):
        ifr.FALLBACKS.append("ENR_L23.tif")
        return manifest.cycle_entry(cycle_id, []), {}

    monkeypatch.setattr(ifr, "FALLBACKS", [])
    monkeypatch.setattr(cli, "build_cycle", fake_build)
    # The packs are kept, and the exit code is not zero so the run is noticed.
    assert run_main(monkeypatch, tmp_path, ONE_LINK, "--no-publish", "--only", "enr_l23") == 3
    assert capsys.readouterr().out.splitlines()[-1] == "fallback outlines used for 2026-09-03 ENR_L23.tif"
    assert ifr.FALLBACKS == []


def test_the_stage_summary_lists_each_stage_once(monkeypatch, tmp_path, capsys):
    fake_layer_build(monkeypatch)
    monkeypatch.setattr(build, "STAGES", {})
    tifs = [(tmp_path / "Houston SEC.tif", tmp_path / "houston.shp")]
    cli.build_layer("vfr", tifs, build.Z12, (4, 12), tmp_path)
    cli.build_layer("vfr", tifs, build.Z12, (4, 12), tmp_path)
    monkeypatch.setattr(pack, "STATE_CODES", ["TX"])
    monkeypatch.setattr(pack, "extract_state", lambda *args: False)
    cli.cut_packs("vfr", tmp_path / "vfr.pmtiles", (4, 12), tmp_path / "out", tmp_path)
    logged = [line for line in capsys.readouterr().out.splitlines() if line.startswith("stage vfr ")]
    assert "stage vfr warp" in " ".join(logged) and "stage vfr cut" in " ".join(logged)
    rows = build.stage_summary().splitlines()[1:]
    names = [row.split()[:2] for row in rows]
    assert len(names) == len({tuple(n) for n in names})
    assert ["vfr", "warp"] in names and ["vfr", "joins"] in names and ["vfr", "cut"] in names
