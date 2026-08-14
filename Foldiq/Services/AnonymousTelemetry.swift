import Foundation

enum AnonymousTelemetry {
    static let preferenceKey = "shareAnonymousUsageData"
    private static let installIDKey = "anonymousTelemetryInstallID"
    private static let endpoint = URL(string: "https://foldiq.app/api/telemetry")!

    enum Event: String {
        case scanCompleted = "scan_completed"
        case applyCompleted = "apply_completed"
        case undoCompleted = "undo_completed"
    }

    static func send(_ event: Event, success: Bool, elapsed: TimeInterval, itemCount: Int) {
        guard UserDefaults.standard.bool(forKey: preferenceKey) else { return }
        let payload: [String: Any] = [
            "eventId": UUID().uuidString.lowercased(),
            "installId": installID,
            "eventName": event.rawValue,
            "platform": "macos",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            "success": success,
            "durationBucket": durationBucket(elapsed),
            "itemCountBucket": itemCountBucket(itemCount),
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request).resume()
    }

    private static var installID: String {
        if let existing = UserDefaults.standard.string(forKey: installIDKey),
           UUID(uuidString: existing) != nil { return existing.lowercased() }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: installIDKey)
        return value
    }

    private static func durationBucket(_ seconds: TimeInterval) -> String {
        if seconds < 30 { return "under_30s" }
        if seconds < 120 { return "30s_2m" }
        if seconds < 300 { return "2m_5m" }
        if seconds < 900 { return "5m_15m" }
        return "over_15m"
    }

    private static func itemCountBucket(_ count: Int) -> String {
        if count <= 0 { return "0" }
        if count < 50 { return "1_49" }
        if count < 200 { return "50_199" }
        if count < 1_000 { return "200_999" }
        if count < 5_000 { return "1000_4999" }
        return "5000_plus"
    }
}
