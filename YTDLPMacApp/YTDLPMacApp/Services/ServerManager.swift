import Foundation

@MainActor
final class ServerManager: ObservableObject {
    @Published private(set) var isStarting = false
    @Published private(set) var lastError: String?
    @Published private(set) var isServerReachable = false

    private var serverProcess: Process?
    private var logFileHandle: FileHandle?

    func startIfNeeded() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        if await refreshReachability() {
            return
        }

        do {
            try launchServerProcess()
            try await waitUntilHealthy()
            lastError = nil
        } catch {
            lastError = await refreshReachability() ? nil : error.localizedDescription
        }
    }

    func stop() async {
        stopOwnedServerProcess()
        stopProjectServerProcesses()
        try? await Task.sleep(nanoseconds: 250_000_000)
        _ = await refreshReachability()
    }

    func restart() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        stopOwnedServerProcess()
        stopProjectServerProcesses()
        try? await Task.sleep(nanoseconds: 250_000_000)

        do {
            try launchServerProcess()
            try await waitUntilHealthy()
            lastError = nil
        } catch {
            lastError = await refreshReachability() ? nil : error.localizedDescription
        }
    }

    func clearError() {
        lastError = nil
    }

    @discardableResult
    func refreshReachability() async -> Bool {
        isServerReachable = await probeLocalServer()
        if isServerReachable {
            lastError = nil
        }
        return isServerReachable
    }

    private func launchServerProcess() throws {
        if serverProcess?.isRunning == true {
            return
        }

        guard let serverDirectory = resolveServerDirectory() else {
            throw ServerManagerError.serverDirectoryNotFound
        }

        guard let pythonURL = resolvePythonExecutable() else {
            throw ServerManagerError.pythonNotFound
        }

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [serverDirectory.appendingPathComponent("main.py").path]
        process.currentDirectoryURL = serverDirectory
        process.environment = processEnvironment(serverDirectory: serverDirectory)

        let logURL = try prepareLogFile()
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        process.standardOutput = handle
        process.standardError = handle

        try process.run()
        serverProcess = process
        logFileHandle = handle
    }

    private func stopOwnedServerProcess() {
        if serverProcess?.isRunning == true {
            serverProcess?.terminate()
            serverProcess?.waitUntilExit()
        }

        serverProcess = nil
        try? logFileHandle?.close()
        logFileHandle = nil
    }

    private func stopProjectServerProcesses() {
        guard let serverDirectory = resolveServerDirectory() else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", serverDirectory.appendingPathComponent("main.py").path]

        do {
            try process.run()
            process.waitUntilExit()
        } catch { }
    }

    private func waitUntilHealthy() async throws {
        for _ in 0..<100 {
            if await refreshReachability() {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw ServerManagerError.serverDidNotBecomeReady
    }

    private func probeLocalServer() async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: healthURL())
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private func resolveServerDirectory() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            ProcessInfo.processInfo.environment["YTDLP_MAC_APP_SERVER_DIR"].map(URL.init(fileURLWithPath:)),
            Bundle.main.resourceURL?.appendingPathComponent("server"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("server"),
            developmentServerDirectory(),
        ].compactMap { $0 }

        return candidates.first { url in
            fileManager.fileExists(atPath: url.appendingPathComponent("main.py").path)
        }
    }

    private func developmentServerDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("server")
    }

    private func resolvePythonExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["YTDLP_MAC_APP_PYTHON"],
            UserDefaults.standard.string(forKey: SetupDefaults.pythonPath),
            "/opt/homebrew/bin/python3.10",
            "/opt/homebrew/opt/python@3.10/bin/python3.10",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3.10",
            "/usr/local/bin/python3",
            "\(home)/.pyenv/versions/3.10.0/bin/python3",
            "\(home)/.pyenv/shims/python3",
            "/usr/bin/python3",
        ].compactMap { $0 }

        return candidates
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func processEnvironment(serverDirectory: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
        environment["PYTHONPATH"] = serverDirectory.path
        environment["YTDLP_MAC_APP_HOST"] = configuredHost()
        environment["YTDLP_MAC_APP_PORT"] = String(configuredPort())
        environment["YTDLP_COOKIES_FROM_BROWSER"] = configuredCookiesFromBrowser()
        if let ffmpegPath = UserDefaults.standard.string(forKey: SetupDefaults.ffmpegPath), !ffmpegPath.isEmpty {
            environment["FFMPEG_PATH"] = ffmpegPath
        }
        return environment
    }

    private func healthURL() -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = configuredHost()
        components.port = configuredPort()
        components.path = "/api/health"
        return components.url ?? URL(string: "http://127.0.0.1:18765/api/health")!
    }

    private func configuredHost() -> String {
        let host = UserDefaults.standard.string(forKey: "serverHost")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return host?.isEmpty == false ? host! : "127.0.0.1"
    }

    private func configuredPort() -> Int {
        let value = UserDefaults.standard.string(forKey: "serverPort")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, let port = Int(value), (1...65535).contains(port) else {
            return 18765
        }
        return port
    }

    private func configuredCookiesFromBrowser() -> String {
        let value = UserDefaults.standard.string(forKey: "cookiesFromBrowser")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value?.isEmpty == false ? value! : "auto"
    }

    private func prepareLogFile() throws -> URL {
        let projectRoot = developmentServerDirectory().deletingLastPathComponent()
        let logsDirectory = projectRoot.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let logURL = logsDirectory.appendingPathComponent("server-app.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        return logURL
    }

    deinit {
        if serverProcess?.isRunning == true {
            serverProcess?.terminate()
            serverProcess?.waitUntilExit()
        }

        try? logFileHandle?.close()
    }
}

enum ServerManagerError: LocalizedError {
    case serverDirectoryNotFound
    case pythonNotFound
    case serverDidNotBecomeReady

    var errorDescription: String? {
        switch self {
        case .serverDirectoryNotFound:
            return "Pythonサーバーのフォルダーが見つかりません"
        case .pythonNotFound:
            return "Python 3が見つかりません"
        case .serverDidNotBecomeReady:
            return "Pythonサーバーの起動確認に失敗しました"
        }
    }
}
