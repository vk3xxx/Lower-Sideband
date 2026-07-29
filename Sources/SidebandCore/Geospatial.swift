import ReticulumKit
import Foundation

public enum SidebandGeospatial {
    public struct Relationship: Codable, Hashable, Sendable {
        public let surfaceDistanceMeters: Double
        public let straightLineDistanceMeters: Double
        public let initialBearingDegrees: Double
        public let verticalSeparationMeters: Double
        public let elevationAngleDegrees: Double
        public let sharedRadioHorizonMeters: Double
        public let withinRadioHorizon: Bool
    }

    public static func relationship(from origin: SidebandTelemetry.Location, to target: SidebandTelemetry.Location) -> Relationship {
        let radius = 6_371_000.0
        let lat1 = origin.latitude.radians, lat2 = target.latitude.radians
        let deltaLat = (target.latitude - origin.latitude).radians
        let deltaLon = (target.longitude - origin.longitude).radians
        let a = sin(deltaLat / 2) * sin(deltaLat / 2) + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        let surface = radius * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        let vertical = target.altitude - origin.altitude
        let straight = hypot(surface, vertical)
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let bearing = (atan2(y, x).degrees + 360).truncatingRemainder(dividingBy: 360)
        // ITU effective-earth-radius approximation, equivalent to the
        // radio-horizon information presented by upstream Sideband.
        let horizon = 4_120 * (sqrt(max(0, origin.altitude)) + sqrt(max(0, target.altitude)))
        let elevation = atan2(vertical, max(surface, 0.001)).degrees
        return Relationship(surfaceDistanceMeters: surface, straightLineDistanceMeters: straight,
                            initialBearingDegrees: bearing, verticalSeparationMeters: vertical, elevationAngleDegrees: elevation,
                            sharedRadioHorizonMeters: horizon, withinRadioHorizon: surface <= horizon)
    }
}

private extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}
