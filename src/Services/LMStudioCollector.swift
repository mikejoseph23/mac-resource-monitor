import Foundation

// An actor so `latest` is never written and read from different threads at
// once: MetricsManager currently reads the return value of `collect()`
// rather than `latest` directly, but a future off-main-actor caller (see M3)
// could race a direct read against this write without actor isolation.
actor LMStudioCollector {
    private let baseURL = URL(string: "http://127.0.0.1:1234")!
    private let session: URLSession

    /// Most recent result, updated by `collect()`. Actor-isolated — callers
    /// read it via `await collector.latest` from any thread.
    private(set) var latest: LMStudioMetrics = .offline

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// Call from an async context. Updates `latest` and returns the result.
    @discardableResult
    func collect() async -> LMStudioMetrics {
        let result = await fetchModels()
        latest = result
        return result
    }

    private func fetchModels() async -> LMStudioMetrics {
        let url = baseURL.appendingPathComponent("api/v0/models")
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .offline
            }
            let decoded = try JSONDecoder().decode(LMStudioModelsResponse.self, from: data)
            let models = decoded.data.map { item in
                LMStudioModel(
                    modelId: item.id,
                    type: item.type ?? "unknown",
                    publisher: item.publisher ?? "unknown",
                    arch: item.arch ?? "unknown",
                    quantization: item.quantization ?? "unknown",
                    state: item.state ?? "not-loaded",
                    maxContextLength: item.max_context_length ?? 0,
                    loadedContextLength: item.loaded_context_length,
                    compatibilityType: item.compatibility_type ?? "unknown"
                )
            }
            return LMStudioMetrics(status: .connected, models: models)
        } catch {
            return .offline
        }
    }
}

// MARK: - JSON Response Types

private struct LMStudioModelsResponse: Decodable {
    let data: [LMStudioModelItem]
}

private struct LMStudioModelItem: Decodable {
    let id: String
    let type: String?
    let publisher: String?
    let arch: String?
    let compatibility_type: String?
    let quantization: String?
    let state: String?
    let max_context_length: Int?
    let loaded_context_length: Int?
}
