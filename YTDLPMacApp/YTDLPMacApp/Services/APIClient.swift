import Foundation

class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private var baseURL: URL {
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: "serverHost")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = defaults.string(forKey: "serverPort")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = host?.isEmpty == false ? host! : "127.0.0.1"
        let resolvedPort = port?.isEmpty == false ? port! : "18765"

        var components = URLComponents()
        components.scheme = "http"
        components.host = resolvedHost
        components.port = validPort(from: resolvedPort)
        return components.url ?? URL(string: "http://127.0.0.1:18765")!
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    private func validPort(from value: String) -> Int {
        guard let port = Int(value), (1...65535).contains(port) else {
            return 18765
        }
        return port
    }

    // MARK: - Server

    func getServerStatus() async throws -> ServerStatus {
        try await get(path: "/")
    }

    func getHealthStatus() async throws -> HealthStatus {
        try await get(path: "/api/health")
    }

    func getSettings() async throws -> ServerSettings {
        try await get(path: "/api/settings")
    }

    // MARK: - Video Info

    func getVideoInfo(url: String) async throws -> VideoInfo {
        let params = ["url": url]
        return try await get(path: "/api/video/info", queryItems: params)
    }

    // MARK: - Downloads

    func startDownload(
        url: String,
        formatId: String = "",
        subtitle: Bool = false,
        duplicatePolicy: String = "skip"
    ) async throws -> DownloadStartResponse {
        let body: [String: Any] = [
            "url": url,
            "format_id": formatId,
            "subtitle": subtitle,
            "duplicate_policy": duplicatePolicy,
        ]
        return try await post(path: "/api/download", body: body)
    }

    func getTaskStatus(taskId: String) async throws -> DownloadTaskResponse {
        try await get(path: "/api/download/status/\(taskId)")
    }

    func getAllTasks() async throws -> [DownloadTaskResponse] {
        let response: TasksResponse = try await get(path: "/api/download/tasks")
        return response.tasks
    }

    func cancelDownload(taskId: String) async throws {
        struct CancelResponse: Codable { let message: String }
        let _: CancelResponse = try await post(path: "/api/download/cancel/\(taskId)", body: [:])
    }

    func clearCompleted() async throws {
        struct ClearResponse: Codable { let message: String }
        let _: ClearResponse = try await post(path: "/api/download/clear", body: [:])
    }

    // MARK: - Files

    func getDownloadedFiles() async throws -> [DownloadedFile] {
        let response: FilesResponse = try await get(path: "/api/downloads")
        return response.files
    }

    func openDownloadFolder() async throws {
        struct OpenFolderResponse: Codable { let message: String }
        let _: OpenFolderResponse = try await post(path: "/api/downloads/open", body: [:])
    }

    func openFile(path: String) async throws {
        struct OpenResponse: Codable { let message: String }
        let _: OpenResponse = try await post(path: "/api/downloads/open-file", body: ["filepath": path])
    }

    func revealFile(path: String) async throws {
        struct RevealResponse: Codable { let message: String }
        let _: RevealResponse = try await post(path: "/api/downloads/reveal-file", body: ["filepath": path])
    }

    func deleteFile(path: String) async throws {
        struct DeleteResponse: Codable { let message: String }
        let _: DeleteResponse = try await post(path: "/api/downloads/delete", body: ["filepath": path])
    }

    // MARK: - Generic HTTP Methods

    private func get<T: Decodable>(path: String, queryItems: [String: String]? = nil) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if let items = queryItems {
            components.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable>(path: String, body: [String: Any]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = jsonData

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200...299:
            return
        case 400:
            throw APIError.badRequest(message: errorDetail(from: data))
        case 404:
            throw APIError.notFound(message: errorDetail(from: data))
        case 500:
            throw APIError.serverError(message: errorDetail(from: data))
        default:
            throw APIError.unknown(httpResponse.statusCode, message: errorDetail(from: data))
        }
    }

    private func errorDetail(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let response = try? decoder.decode(APIErrorResponse.self, from: data) {
            return response.detail
        }

        return String(data: data, encoding: .utf8)
    }

    func isConnected() async -> Bool {
        do {
            let status: ServerStatus = try await get(path: "/")
            return status.status == "running"
        } catch {
            return false
        }
    }
}

// MARK: - Helper Response Types

struct TasksResponse: Codable {
    let tasks: [DownloadTaskResponse]
    let total: Int
}

struct FilesResponse: Codable {
    let files: [DownloadedFile]
    let total: Int
}

struct APIErrorResponse: Codable {
    let detail: String
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidResponse
    case badRequest(message: String?)
    case notFound(message: String?)
    case serverError(message: String?)
    case networkError(Error)
    case decodingError(Error)
    case unknown(Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "無効なレスポンスです"
        case .badRequest(let message):
            return message ?? "リクエストが正しくありません"
        case .notFound(let message):
            return message ?? "リソースが見つかりません"
        case .serverError(let message):
            return message ?? "サーバーエラーが発生しました"
        case .networkError(let error):
            return "ネットワークエラー: \(error.localizedDescription)"
        case .decodingError(let error):
            return "データの解析に失敗しました: \(error.localizedDescription)"
        case .unknown(let code, let message):
            return message ?? "不明なエラー (ステータスコード: \(code))"
        }
    }
}
