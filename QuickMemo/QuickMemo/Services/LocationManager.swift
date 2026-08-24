import CoreLocation

class LocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    private let manager = CLLocationManager()
    private var pendingContinuations: [CheckedContinuation<CLLocation?, Never>] = []
    private var lastLocation: CLLocation?
    private var fetching = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// Start location fetch early (call when recording starts)
    func startFetching() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        guard !fetching else { return }
        fetching = true
        manager.requestLocation()
    }

    /// Get location, waiting up to `timeout` seconds if still fetching
    func getLocation(timeout: TimeInterval = 10.0) async -> CLLocation? {
        // If we already have a fresh location (< 60s old), return immediately
        if let loc = lastLocation, abs(loc.timestamp.timeIntervalSinceNow) < 60 {
            return loc
        }

        // Start fetching if not already
        startFetching()

        // Wait for result with timeout
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        // If location arrived while we were setting up
                        if let loc = self.lastLocation, abs(loc.timestamp.timeIntervalSinceNow) < 60 {
                            continuation.resume(returning: loc)
                        } else {
                            self.pendingContinuations.append(continuation)
                        }
                    }
                }
            }

            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()

            // Resume any remaining continuations with nil
            Task { @MainActor in
                for cont in self.pendingContinuations {
                    cont.resume(returning: self.lastLocation)
                }
                self.pendingContinuations.removeAll()
            }

            return result
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in
            lastLocation = location
            fetching = false
            for cont in pendingContinuations {
                cont.resume(returning: location)
            }
            pendingContinuations.removeAll()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            fetching = false
            for cont in pendingContinuations {
                cont.resume(returning: nil)
            }
            pendingContinuations.removeAll()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        }
    }
}
