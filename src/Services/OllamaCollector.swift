import Foundation

/// Polls a local Ollama server (default `127.0.0.1:11434`, overridable with the
/// `OLLAMA_HOST` environment variable, which Ollama itself honours).
///
/// Three unauthenticated endpoints:
/// - `GET /api/version` — reachability plus the server version.
/// - `GET /api/ps`      — models resident right now, with resident size and how
///                        much of it is in VRAM (unified memory on Apple
///                        Silicon), plus the keep-alive expiry.
/// - `GET /api/tags`    — everything pulled to disk; we only take the count.
///
/// `/api/tags` is the expensive one on a large model library, so it is refreshed
/// on a slower cadence than the 2-second collection tick — the installed-model
/// count doesn't change between ticks unless you're mid-`ollama pull`.
actor OllamaCollector {
    private(set) var latest: OllamaMetrics = .offline

    private let session: URLSession
    private let baseURL: URL

    private var cachedInstalledCount: Int = 0
    private var installedCountAge: Int = .max      // ticks since last /api/tags
    private static let tagsRefreshTicks = 15       // ~30s at a 2s tick

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        baseURL = Self.resolveBaseURL()
    }

    @discardableResult
    func collect() async -> OllamaMetrics {
        let result = await fetch()
        latest = result
        return result
    }

    private func fetch() async -> OllamaMetrics {
        guard let version: VersionResponse = await get("api/version") else {
            // Server went away — don't keep reporting a stale model library.
            cachedInstalledCount = 0
            installedCountAge = .max
            return .offline
        }

        let running: PsResponse? = await get("api/ps")

        if installedCountAge >= Self.tagsRefreshTicks {
            if let tags: TagsResponse = await get("api/tags") {
                cachedInstalledCount = tags.models?.count ?? 0
                installedCountAge = 0
            }
        } else {
            installedCountAge += 1
        }

        let models = (running?.models ?? []).map { item in
            OllamaModel(
                name: item.name ?? item.model ?? "unknown",
                sizeBytes: UInt64(max(0, item.size ?? 0)),
                vramBytes: UInt64(max(0, item.size_vram ?? 0)),
                parameterSize: item.details?.parameter_size,
                quantization: item.details?.quantization_level,
                family: item.details?.family,
                expiresAt: item.expires_at.flatMap(Self.parseTimestamp)
            )
        }

        return OllamaMetrics(
            status: .connected,
            version: version.version,
            installedCount: max(cachedInstalledCount, models.count),
            loadedModels: models
        )
    }

    private func get<T: Decodable>(_ path: String) async -> T? {
        do {
            let (data, response) = try await session.data(from: baseURL.appendingPathComponent(path))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    /// `OLLAMA_HOST` may be a bare host, `host:port`, or a full URL.
    private static func resolveBaseURL() -> URL {
        let fallback = URL(string: "http://127.0.0.1:11434")!
        guard var value = ProcessInfo.processInfo.environment["OLLAMA_HOST"]?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return fallback }

        if !value.contains("://") { value = "http://" + value }
        guard var components = URLComponents(string: value), components.host != nil else { return fallback }
        if components.port == nil { components.port = 11434 }
        components.path = ""
        return components.url ?? fallback
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

// MARK: - JSON types

private struct VersionResponse: Decodable {
    let version: String?
}

private struct ModelDetails: Decodable {
    let family: String?
    let parameter_size: String?
    let quantization_level: String?
}

private struct PsResponse: Decodable {
    struct Item: Decodable {
        let name: String?
        let model: String?
        let size: Int64?
        let size_vram: Int64?
        let expires_at: String?
        let details: ModelDetails?
    }
    let models: [Item]?
}

private struct TagsResponse: Decodable {
    struct Item: Decodable {
        let name: String?
    }
    let models: [Item]?
}
