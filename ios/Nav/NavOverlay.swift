import FlightCore
import Foundation
import MapLibre
import UIKit

/// Builds the navigation overlay style: the bundled style with fonts and tiles pointed at local files.
enum NavOverlay {
    static let groupID = AeronauticalLayers.groupID
    static let obstaclesID = AeronauticalLayers.obstaclesID
    static let groups = AeronauticalLayers.groups
    static var layerGroup: LayerGroup { AeronauticalLayers.layerGroup }

    /// Shows or hides each group's layers in a loaded style. Returns the groups now visible there.
    @MainActor static func apply(_ catalog: LayerCatalog, to style: MLNStyle) -> [String] {
        groups.compactMap { group in
            let isOn = catalog.overlay(group.id)?.isOn ?? false
            let found = group.layers.compactMap { style.layer(withIdentifier: $0) }
            for layer in found { layer.isVisible = isOn }
            return isOn && !found.isEmpty ? group.id : nil
        }
    }

    /// The style text for one tile file. Nothing in it is fetched from the network.
    static func json(tiles: URL, assets: URL) throws -> String {
        try String(contentsOf: assets.appendingPathComponent("nav-style.json"), encoding: .utf8)
            .replacingOccurrences(of: "__ASSETS__", with: "file://" + assets.path)
            .replacingOccurrences(of: "__NAV__", with: "pmtiles://file://" + tiles.path)
    }

    /// Writes the style to a temporary file and returns it. Nil when a bundled file is missing.
    @MainActor static func styleURL(tiles: URL) -> URL? {
        guard let assets = Bundle.main.resourceURL?.appendingPathComponent("MapAssets"),
              let text = try? json(tiles: tiles, assets: assets) else { return nil }
        // The tile file is part of the name, so a different file gives a different style file, the same on every launch.
        let name = "nav-\(Checksum.sha256(tiles.path)).json"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }
}

extension NavOverlay {
    /// A paint value with every day ink swapped for its night one.
    static func ink(_ value: Any, night: Bool) -> Any {
        guard night else { return value }
        if let text = value as? String { return NightInk.swap(text) }
        if let list = value as? [Any] { return list.map { ink($0, night: true) } }
        return value
    }

    /// Every color paint in a style's text, as layer id, property name and day value.
    static func colorPaints(_ text: Data) -> [(layer: String, property: String, value: Any)] {
        let style = (try? JSONSerialization.jsonObject(with: text)) as? [String: Any]
        let layers = style?["layers"] as? [[String: Any]] ?? []
        // The background is recolored with the chart, so it is left out.
        return layers.filter { $0["id"] as? String != "background" }.flatMap { layer in
            let paint = layer["paint"] as? [String: Any] ?? [:]
            return paint.keys.filter { $0.hasSuffix("-color") }.sorted().map { key in
                (layer["id"] as? String ?? "", property(key), paint[key] as Any)
            }
        }
    }

    /// "text-halo-color" to "textHaloColor", the name MapLibre's layer classes use.
    static func property(_ key: String) -> String {
        let words = key.split(separator: "-")
        return words.prefix(1).joined() + words.dropFirst().map(\.capitalized).joined()
    }

    @MainActor private static let dayPaints: [(layer: String, property: String, value: Any)] = {
        guard let file = Bundle.main.url(forResource: "nav-style", withExtension: "json", subdirectory: "MapAssets"),
              let text = try? Data(contentsOf: file) else { return [] }
        return colorPaints(text)
    }()

    /// Repaints the loaded overlay in day or night inks. A style without the overlay is left alone.
    @MainActor static func paint(night: Bool, style: MLNStyle) { paint(dayPaints, night: night, style: style) }

    @MainActor static func paint(_ paints: [(layer: String, property: String, value: Any)], night: Bool, style: MLNStyle) {
        for paint in paints {
            guard let layer = style.layer(withIdentifier: paint.layer) else { continue }
            layer.setValue(expression(ink(paint.value, night: night)), forKey: paint.property)
        }
    }

    /// A paint value as MapLibre takes it: a lone color must be a UIColor, not text.
    static func expression(_ value: Any) -> NSExpression {
        guard let hex = value as? String, hex.hasPrefix("#"), let rgb = Int(hex.dropFirst(), radix: 16) else {
            return NSExpression(mglJSONObject: value)
        }
        let part = { (shift: Int) in CGFloat(rgb >> shift & 255) / 255 }
        return NSExpression(forConstantValue: UIColor(red: part(16), green: part(8), blue: part(0), alpha: 1)) // design-lint: allow
    }
}
