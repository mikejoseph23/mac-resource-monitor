import Foundation

/// The single reader for `~/.omlx/settings.json`.
///
/// Two consumers want different slices of that file — `OMLXCollector` needs
/// host / port / `auth.api_key` to poll the server, `AIStorageCollector` needs
/// `cache.ssd_cache_max_size` and `logging.retention_days` to label the disk
/// panel — and neither should be parsing it independently. The file is re-read
/// only when its modification date moves, so the steady-state cost of a poll is
/// one `stat`.
///
/// The API key is deliberately reachable only through `endpoint()`. The storage
/// side calls `storage()`, which returns a struct that has no field for it, so
/// the secret can't leak into a view, a log line or a pasteboard by accident.
actor OMLXSettings {
    static let shared = OMLXSettings()

    /// Everything the poller needs. `apiKey` never leaves this process except
    /// in an Authorization header sent to that same loopback server.
    struct Endpoint {
        let base: URL
        let apiKey: String?
    }

    /// Everything the storage panel needs — no credentials.
    struct Storage {
        /// `cache.ssd_cache_max_size` parsed to bytes, if it was present and
        /// well formed.
        let cacheMaxSizeBytes: UInt64?
        /// The same value verbatim (e.g. `"150GB"`) for display.
        let cacheMaxSizeText: String?
        /// `logging.retention_days`.
        let logRetentionDays: Int?
        /// The port the server is configured on, for the "is it running?" probe.
        let port: Int
        let host: String
    }

    private let url: URL
    private var cached: Parsed?
    private var cachedDate: Date?

    private struct Parsed {
        let endpoint: Endpoint
        let storage: Storage
    }

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omlx/settings.json")
    }

    func endpoint() -> Endpoint { current().endpoint }

    func storage() -> Storage { current().storage }

    // MARK: - Reading

    private func current() -> Parsed {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date

        if let cached, cachedDate == modified {
            return cached
        }

        let parsed = read() ?? Self.defaults
        cached = parsed
        cachedDate = modified
        return parsed
    }

    /// oMLX's own defaults, used when the file is missing or unreadable, so a
    /// fresh install with no settings written yet is still detected.
    private static let defaults = Parsed(
        endpoint: Endpoint(base: URL(string: "http://127.0.0.1:8000")!, apiKey: nil),
        storage: Storage(cacheMaxSizeBytes: nil, cacheMaxSizeText: nil,
                         logRetentionDays: nil, port: 8000, host: "127.0.0.1")
    )

    private func read() -> Parsed? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SettingsFile.self, from: data) else { return nil }

        // A server bound to 0.0.0.0 (or an unset host) is still reachable on
        // loopback, and loopback is the only address we should be polling.
        var host = file.server?.host ?? "127.0.0.1"
        if host.isEmpty || host == "0.0.0.0" || host == "::" { host = "127.0.0.1" }
        let port = file.server?.port ?? 8000

        guard let base = URL(string: "http://\(host):\(port)") else { return nil }
        let key = file.auth?.api_key

        let capText = file.cache?.ssd_cache_max_size
        return Parsed(
            endpoint: Endpoint(base: base, apiKey: (key?.isEmpty ?? true) ? nil : key),
            storage: Storage(
                cacheMaxSizeBytes: capText.flatMap(Self.parseSize),
                cacheMaxSizeText: capText,
                logRetentionDays: file.logging?.retention_days,
                port: port,
                host: host
            )
        )
    }

    /// Parses oMLX's size strings (`"150GB"`, `"512MB"`, `"32 GiB"`) to bytes.
    /// Units are read as binary multiples, which is what the observed cache
    /// footprint agrees with.
    static func parseSize(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits), value >= 0 else { return nil }
        let unit = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)

        let multiplier: Double
        switch unit {
        case "", "B":            multiplier = 1
        case "KB", "KIB", "K":   multiplier = 1024
        case "MB", "MIB", "M":   multiplier = 1024 * 1024
        case "GB", "GIB", "G":   multiplier = 1024 * 1024 * 1024
        case "TB", "TIB", "T":   multiplier = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        let bytes = value * multiplier
        guard bytes.isFinite, bytes >= 0, bytes < Double(UInt64.max) else { return nil }
        return UInt64(bytes)
    }
}

// MARK: - JSON types

private struct SettingsFile: Decodable {
    struct Server: Decodable {
        let host: String?
        let port: Int?
    }
    struct Auth: Decodable {
        let api_key: String?
    }
    struct Cache: Decodable {
        let ssd_cache_max_size: String?
    }
    struct Logging: Decodable {
        let retention_days: Int?
    }
    let server: Server?
    let auth: Auth?
    let cache: Cache?
    let logging: Logging?
}
