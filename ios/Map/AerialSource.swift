import MapLibre

/// Public USGS aerial imagery, fetched online. The service has tiles down to zoom 16 only.
enum AerialSource {
    static let identifier = "aerial"
    // The service puts the row before the column.
    static let template =
        "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}"
    static let credit = "USGS The National Map: Orthoimagery"
    static let maximumZoom = 16

    @MainActor static func make() -> MLNRasterTileSource {
        MLNRasterTileSource(identifier: identifier, tileURLTemplates: [template], options: [
            .minimumZoomLevel: 0,
            .maximumZoomLevel: maximumZoom,
            .tileSize: 256,
            .attributionHTMLString: credit,
        ])
    }

    /// True when one imagery tile can be fetched. A network with no internet behind it fails this.
    static func isReachable(_ address: String? = nil) async -> Bool {
        let tile = address ?? template.replacingOccurrences(of: "{z}", with: "0")
            .replacingOccurrences(of: "{y}", with: "0").replacingOccurrences(of: "{x}", with: "0")
        guard let url = URL(string: tile) else { return false }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        let answer = try? await URLSession.shared.data(for: request)
        return (answer?.1 as? HTTPURLResponse)?.statusCode == 200
    }
}
