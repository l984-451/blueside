// usage: node make_street_style.cjs <path to the basemaps package> <light|dark> > street-<flavor>.json
// Writes the street style with placeholders for the local asset folder and the pack file.
const basemaps = require(process.argv[2]);
const flavor = process.argv[3] || "light";
const style = JSON.stringify({
  version: 8,
  glyphs: "__ASSETS__/fonts/{fontstack}/{range}.pbf",
  sprite: "__ASSETS__/sprites/" + flavor,
  sources: { protomaps: { type: "vector", url: "__PMTILES__", attribution: "© OpenStreetMap" } },
  layers: basemaps.layers("protomaps", basemaps.namedFlavor(flavor), { lang: "en" }),
});
// Only three fonts are bundled, so the one extra font named for Devanagari text falls back to Regular.
console.log(style.replaceAll("Noto Sans Devanagari Regular v1", "Noto Sans Regular"));
