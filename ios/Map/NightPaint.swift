import FlightCore
import MapLibre

extension NightPaint {
    @MainActor static func apply(night: Bool, to layer: MLNRasterStyleLayer) {
        apply(values(night: night), to: layer)
    }

    @MainActor static func apply(_ paint: Values, to layer: MLNRasterStyleLayer) {
        layer.minimumRasterBrightness = NSExpression(forConstantValue: paint.minimumBrightness)
        layer.maximumRasterBrightness = NSExpression(forConstantValue: paint.maximumBrightness)
        layer.rasterHueRotation = NSExpression(forConstantValue: paint.hueRotation)
    }
}
