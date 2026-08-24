import CoreLocation

class WatchLocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = WatchLocationManager()

    private let manager = CLLocationManager()
    private var pendingContinuations: [CheckedContinuation<CLLocation?, Never>] = []
    private var lastLocation: CLLocation?
    private var tracking = false

    override init() {
        super.init()
        manager.delegate = self
        // Ask for the best fix the hardware can give. Continuous tracking absorbs
        // the extra time this costs, so it does not slow down saving a memo.
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Keep the GPS engaged while the app is on screen. Continuous updates let the
    /// fix converge, so a memo saved later reuses an already-good location instead
    /// of paying for a cold start at save time.
    func startTracking() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        guard !tracking else { return }
        tracking = true
        manager.startUpdatingLocation()
    }

    /// Stop once the app leaves the screen. watchOS suspends us shortly after
    /// anyway, but releasing the GPS explicitly keeps the intent clear.
    func stopTracking() {
        guard tracking else { return }
        tracking = false
        manager.stopUpdatingLocation()
    }

    /// Location to stamp on a memo. Normally returns instantly from the tracked
    /// fix; it only waits when the app just launched and nothing has arrived yet.
    func getLocation(timeout: TimeInterval = 3.0, maxAge: TimeInterval = 60) async -> CLLocation? {
        if let loc = freshLocation(maxAge: maxAge) { return loc }

        startTracking()

        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        if let loc = self.freshLocation(maxAge: maxAge) {
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

            // Timed out: release anyone still waiting with whatever we have
            Task { @MainActor in
                for cont in self.pendingContinuations {
                    cont.resume(returning: self.lastLocation)
                }
                self.pendingContinuations.removeAll()
            }

            return result
        }
    }

    private func freshLocation(maxAge: TimeInterval) -> CLLocation? {
        guard let loc = lastLocation, abs(loc.timestamp.timeIntervalSinceNow) < maxAge else { return nil }
        return loc
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // A negative horizontalAccuracy marks an invalid fix
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        Task { @MainActor in
            lastLocation = location
            for cont in pendingContinuations {
                cont.resume(returning: location)
            }
            pendingContinuations.removeAll()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            for cont in pendingContinuations {
                cont.resume(returning: lastLocation)
            }
            pendingContinuations.removeAll()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            Task { @MainActor in startTracking() }
        }
    }
}
