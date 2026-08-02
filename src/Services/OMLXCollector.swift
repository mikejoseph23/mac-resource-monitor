import Foundation

/// Polls a local oMLX (`app.omlx`) inference server.
///
/// Two endpoints, because oMLX splits its surface by auth:
/// - `GET /health` — unauthenticated. Reachability, default model, pool
///   counts, model memory. Answers 503 with `status: "loading"` while pinned
///   models preload, which we surface as `.loading` rather than offline.
/// - `GET /api/status` — the endpoint oMLX documents for "external tool
///   polling"; adds loaded model ids, tok/s, queue depth and cache hit rate,
///   but is behind `verify_api_key`.
///
/// Rather than making the user paste a key into Settings, we read host, port
/// and `auth.api_key` straight out of oMLX's own `~/.omlx/settings.json`. The
/// key never leaves this process except in the Authorization header of a
/// request to that same loopback server. The file is re-read only when its
/// modification date changes, so the steady-state cost per tick is one `stat`.
///
/// An `actor` for the same reason `LMStudioCollector` is one: `latest` and the
/// cached endpoint are mutable state touched from an async context.
actor OMLXCollector {
    private(set) var latest: OMLXMetrics = .offline

    private let session: URLSession
    private let settingsURL: URL

    private var cachedEndpoint: Endpoint?
    private var cachedSettingsDate: Date?

    private struct Endpoint {
        let base: URL
        let apiKey: String?
    }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omlx/settings.json")
    }

    @discardableResult
    func collect() async -> OMLXMetrics {
        let result = await fetch()
        latest = result
        return result
    }

    private func fetch() async -> OMLXMetrics {
        let endpoint = resolveEndpoint()

        guard let health = await fetchHealth(endpoint) else { return .offline }

        let status: OMLXMetrics.Status = health.status == "loading" ? .loading : .connected
        let pool = health.engine_pool

        // The detailed call is worth making only once the server is actually
        // up and we have a key to get past verify_api_key.
        let detail = endpoint.apiKey == nil ? nil : await fetchStatus(endpoint)

        if let detail {
            return OMLXMetrics(
                status: status,
                detailed: true,
                version: detail.version,
                defaultModel: detail.default_model ?? health.default_model,
                discoveredCount: detail.models_discovered ?? 0,
                loadedCount: detail.models_loaded ?? 0,
                loadingCount: detail.models_loading ?? 0,
                loadedModels: detail.loaded_models ?? [],
                modelMemoryUsedBytes: UInt64(max(0, detail.model_memory_used ?? 0)),
                modelMemoryMaxBytes: detail.model_memory_max.map { UInt64(max(0, $0)) },
                activeRequests: detail.active_requests ?? 0,
                waitingRequests: detail.waiting_requests ?? 0,
                generationTPS: detail.avg_generation_tps,
                prefillTPS: detail.avg_prefill_tps,
                cacheEfficiency: detail.cache_efficiency
            )
        }

        return OMLXMetrics(
            status: status,
            detailed: false,
            version: nil,
            defaultModel: health.default_model,
            discoveredCount: pool?.model_count ?? 0,
            loadedCount: pool?.loaded_count ?? 0,
            loadingCount: 0,
            loadedModels: [],
            modelMemoryUsedBytes: UInt64(max(0, pool?.current_model_memory ?? 0)),
            modelMemoryMaxBytes: pool?.final_ceiling.flatMap { $0 > 0 ? UInt64($0) : nil },
            activeRequests: 0,
            waitingRequests: 0,
            generationTPS: nil,
            prefillTPS: nil,
            cacheEfficiency: nil
        )
    }

    // MARK: - Requests

    private func fetchHealth(_ endpoint: Endpoint) async -> HealthResponse? {
        // 503 is expected while pinned models preload — the body is still valid.
        guard let (data, code) = await get("health", endpoint),
              code == 200 || code == 503 else { return nil }
        return try? JSONDecoder().decode(HealthResponse.self, from: data)
    }

    private func fetchStatus(_ endpoint: Endpoint) async -> StatusResponse? {
        guard let (data, code) = await get("api/status", endpoint), code == 200 else { return nil }
        return try? JSONDecoder().decode(StatusResponse.self, from: data)
    }

    private func get(_ path: String, _ endpoint: Endpoint) async -> (Data, Int)? {
        var request = URLRequest(url: endpoint.base.appendingPathComponent(path))
        if let key = endpoint.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            return (data, http.statusCode)
        } catch {
            return nil
        }
    }

    // MARK: - Endpoint discovery

    /// Re-reads `~/.omlx/settings.json` only when its mtime moves; otherwise
    /// hands back the cached endpoint. Falls back to oMLX's own defaults
    /// (127.0.0.1:8000, no key) when the file is missing or unreadable, so a
    /// fresh install with no settings file yet is still detected.
    private func resolveEndpoint() -> Endpoint {
        let attributes = try? FileManager.default.attributesOfItem(atPath: settingsURL.path)
        let modified = attributes?[.modificationDate] as? Date

        if let cachedEndpoint, cachedSettingsDate == modified {
            return cachedEndpoint
        }

        let endpoint = readSettings() ?? Endpoint(base: URL(string: "http://127.0.0.1:8000")!, apiKey: nil)
        cachedEndpoint = endpoint
        cachedSettingsDate = modified
        return endpoint
    }

    private func readSettings() -> Endpoint? {
        guard let data = try? Data(contentsOf: settingsURL),
              let file = try? JSONDecoder().decode(SettingsFile.self, from: data) else { return nil }

        // A server bound to 0.0.0.0 (or an unset host) is still reachable on
        // loopback, and loopback is the only address we should be polling.
        var host = file.server?.host ?? "127.0.0.1"
        if host.isEmpty || host == "0.0.0.0" || host == "::" { host = "127.0.0.1" }
        let port = file.server?.port ?? 8000

        guard let base = URL(string: "http://\(host):\(port)") else { return nil }
        let key = file.auth?.api_key
        return Endpoint(base: base, apiKey: (key?.isEmpty ?? true) ? nil : key)
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
    let server: Server?
    let auth: Auth?
}

private struct HealthResponse: Decodable {
    struct EnginePool: Decodable {
        let model_count: Int?
        let loaded_count: Int?
        let final_ceiling: Int64?
        let current_model_memory: Int64?
    }
    let status: String?
    let default_model: String?
    let engine_pool: EnginePool?
}

private struct StatusResponse: Decodable {
    let version: String?
    let models_discovered: Int?
    let models_loaded: Int?
    let models_loading: Int?
    let default_model: String?
    let loaded_models: [String]?
    let active_requests: Int?
    let waiting_requests: Int?
    let cache_efficiency: Double?
    let avg_prefill_tps: Double?
    let avg_generation_tps: Double?
    let model_memory_used: Int64?
    let model_memory_max: Int64?
}
