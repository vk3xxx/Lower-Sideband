import CoreLocation
import Foundation
import Observation
import SidebandCore
#if os(iOS)
import UIKit
#endif

@MainActor @Observable
final class TelemetryCapture: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<SidebandTelemetry?, Never>?
    private(set) var isRequesting = false
    private(set) var lastError: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestTelemetry() async -> SidebandTelemetry? {
        guard continuation == nil else { return nil }
        lastError = nil
        isRequesting = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .denied, .restricted:
                finish(nil, error: "Location access is disabled for Lower Sideband.")
            @unknown default:
                finish(nil, error: "Location access is unavailable.")
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(nil, error: "Location access was not granted.")
        case .notDetermined:
            break
        @unknown default:
            finish(nil, error: "Location access is unavailable.")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.max(by: { $0.timestamp < $1.timestamp }) else {
            finish(nil, error: "No location fix was available.")
            return
        }
        let telemetryLocation = SidebandTelemetry.Location(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            speed: max(0, location.speed) * 3.6,
            bearing: max(0, location.course),
            accuracy: max(0, location.horizontalAccuracy),
            updatedAt: location.timestamp
        )
        finish(SidebandTelemetry(capturedAt: .now, location: telemetryLocation, battery: batteryReading()), error: nil)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil, error: "Could not determine location: \(error.localizedDescription)")
    }

    private func finish(_ telemetry: SidebandTelemetry?, error: String?) {
        lastError = error
        isRequesting = false
        let pending = continuation
        continuation = nil
        pending?.resume(returning: telemetry)
    }

    private func batteryReading() -> SidebandTelemetry.Battery? {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        guard UIDevice.current.batteryLevel >= 0 else { return nil }
        return .init(
            chargePercent: Double(UIDevice.current.batteryLevel * 100),
            isCharging: UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        )
        #else
        return nil
        #endif
    }
}
