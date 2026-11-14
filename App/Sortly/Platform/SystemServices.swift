import CoreLocation
import Foundation
import Network
import UIKit
import SortlyCore

/// Network reachability for the iCloud rule and to tell "offline" from "throttled".
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let state = LockedBox<(online: Bool, wifi: Bool)>((true, false))

    private init() {
        monitor.pathUpdateHandler = { [state] path in
            let wifi = (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)) && !path.isExpensive
            state.value = (path.status == .satisfied, wifi)
        }
        monitor.start(queue: DispatchQueue(label: "app.albumist.network"))
    }

    var isOnline: Bool { state.value.online }
    var isOnWiFi: Bool { state.value.wifi }
}

/// Reverse geocoding with Apple's geocoder. Results are cached per raster cell by the
/// core, so this is called once per area, not once per photo.
///
/// Note: `CLGeocoder` is deprecated in iOS 26 in favour of `MKReverseGeocodingRequest`.
/// It still works and returns the structured address fields Albumist needs; the migration
/// is tracked in docs/STATUS.md.
struct SystemGeocoder: ReverseGeocoding {
    var locale: Locale

    func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> PlaceComponents? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location, preferredLocale: locale)
            guard let p = placemarks.first else { return nil }
            return PlaceComponents(
                isoCountryCode: p.isoCountryCode,
                country: p.country,
                administrativeArea: p.administrativeArea,
                subAdministrativeArea: p.subAdministrativeArea,
                locality: p.locality,
                subLocality: p.subLocality,
                thoroughfare: p.thoroughfare,
                areaOfInterest: p.areasOfInterest?.first,
                inlandWater: p.inlandWater,
                ocean: p.ocean,
                timeZoneIdentifier: p.timeZone?.identifier
            )
        } catch let error as CLError {
            switch error.code {
            case .geocodeFoundNoResult, .geocodeFoundPartialResult: return nil
            case .network: throw NetworkStatus.shared.isOnline ? GeocodingError.rateLimited(retryAfter: nil) : GeocodingError.offline
            default: throw GeocodingError.failed
            }
        } catch {
            throw NetworkStatus.shared.isOnline ? GeocodingError.failed : GeocodingError.offline
        }
    }
}

/// Thermal state, Low Power Mode and battery decide whether analysis may continue.
final class DeviceConditions: AnalysisConditions, @unchecked Sendable {
    /// In the background Albumist only works while charging (speed-up 7).
    let isBackgroundRun: Bool

    init(isBackgroundRun: Bool = false) {
        self.isBackgroundRun = isBackgroundRun
    }

    func pauseReason() async -> PauseReason? {
        let info = ProcessInfo.processInfo
        if info.thermalState == .critical || info.thermalState == .serious { return .thermal }
        let (state, level) = await MainActor.run { () -> (UIDevice.BatteryState, Float) in
            UIDevice.current.isBatteryMonitoringEnabled = true
            return (UIDevice.current.batteryState, UIDevice.current.batteryLevel)
        }
        let charging = state == .charging || state == .full
        if info.isLowPowerModeEnabled && !charging { return .lowPower }
        if !charging && level >= 0 && level < 0.2 { return .batteryLow }
        return nil
    }

    func isOnWiFi() async -> Bool { NetworkStatus.shared.isOnWiFi }
}
