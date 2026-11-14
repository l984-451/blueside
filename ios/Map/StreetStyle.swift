import FlightCore
import Foundation

/// Builds the street map style: the bundled style with fonts, icons and tiles pointed at local files.
enum StreetStyle {
    /// The style text for the packs. Nothing in it is fetched from the network.
    /// `nav` is the nav overlay style file, merged in so the street map carries it.
    static func json(packs: [URL], dark: Bool, assets: URL, nav: URL? = nil) throws -> String {
        let name = dark ? "street-dark.json" : "street-light.json"
        let template = try String(contentsOf: assets.appendingPathComponent(name), encoding: .utf8)
        let overlay = try nav.map { try String(contentsOf: $0, encoding: .utf8) }
        return try MapStyleSpec.streetStyle(template: template, assets: "file://" + assets.path, packs: packs,
                                            overlay: overlay, night: dark)
    }

    /// Writes the style to a temporary file and returns it. Nil when a bundled file is missing.
    static func styleURL(packs: [URL], dark: Bool, nav: URL? = nil) -> URL? {
        guard let assets = Bundle.main.resourceURL?.appendingPathComponent("MapAssets"),
              let text = try? json(packs: packs, dark: dark, assets: assets, nav: nav) else { return nil }
        // The pack and nav names are part of the file name, so different files give a different style file.
        let key = (packs + [nav].compactMap { $0 }).map(\.path).joined(separator: "|")
        let name = "street-\(dark ? "dark" : "light")-\(Checksum.sha256(key)).json"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }
}
