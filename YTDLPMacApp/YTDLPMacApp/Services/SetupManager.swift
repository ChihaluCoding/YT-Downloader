import Foundation

@MainActor
final class SetupManager: ObservableObject {
    @Published private(set) var isSetupComplete: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var message = "環境を確認しています"
    @Published private(set) var errorMessage: String?
    @Published private(set) var pythonStatus: SetupStepStatus = .pending
    @Published private(set) var librariesStatus: SetupStepStatus = .pending
    @Published private(set) var ffmpegStatus: SetupStepStatus = .pending
    @Published private(set) var ytdlpStatus: SetupStepStatus = .pending
    @Published var updateNotice: SetupUpdateNotice?
    @Published var selectedBuild: YTDLPBuild {
        didSet {
            defaults.set(selectedBuild.rawValue, forKey: SetupDefaults.ytdlpBuild)
        }
    }

    private let defaults: UserDefaults
    private var hasRunStartupEnvironmentCheck = false
    private var pendingUpdateNotices: [SetupUpdateNotice] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isSetupComplete = defaults.bool(forKey: SetupDefaults.initialSetupCompleted)
        let savedBuild = defaults.string(forKey: SetupDefaults.ytdlpBuild)
        self.selectedBuild = YTDLPBuild(rawValue: savedBuild ?? "") ?? .stable
    }

    var pythonPath: String? {
        defaults.string(forKey: SetupDefaults.pythonPath)
    }

    var ffmpegPath: String? {
        defaults.string(forKey: SetupDefaults.ffmpegPath)
    }

    private var pythonLibraryPackages: [PythonLibraryPackage] {
        [
            PythonLibraryPackage(requirementName: "fastapi", distributionName: "fastapi", displayName: "fastapi"),
            PythonLibraryPackage(requirementName: "uvicorn", distributionName: "uvicorn", displayName: "uvicorn"),
            PythonLibraryPackage(requirementName: "python-multipart", distributionName: "python-multipart", displayName: "python-multipart"),
        ]
    }

    func runStartupEnvironmentCheck() async {
        guard !hasRunStartupEnvironmentCheck else { return }
        hasRunStartupEnvironmentCheck = true
        await inspectEnvironment()
        await updatePythonLibrariesIfNeeded()
        await updateYTDLPIfNeeded()
    }

    func inspectEnvironment() async {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }

        message = "Pythonを探しています"
        var pythonExecutable: URL?
        if let python = await findPythonExecutable() {
            pythonExecutable = python
            defaults.set(python.path, forKey: SetupDefaults.pythonPath)
            pythonStatus = .complete(python.path)
            librariesStatus = await verifyPythonLibraries(python: python) ? .complete("インストール済み") : .actionRequired("必要なライブラリをインストールしてください")
        } else {
            pythonStatus = .actionRequired("Python 3が見つかりません")
            librariesStatus = .pending
        }

        message = "ffmpegを探しています"
        if let ffmpeg = await findExecutable(named: "ffmpeg", savedPath: ffmpegPath, extraCandidates: ffmpegCandidates()) {
            defaults.set(ffmpeg.path, forKey: SetupDefaults.ffmpegPath)
            ffmpegStatus = .complete(ffmpeg.path)
        } else {
            ffmpegStatus = .actionRequired("ffmpegが見つかりません")
        }

        if librariesStatus.isComplete, let python = pythonExecutable {
            if let version = await installedYTDLPVersion(python: python, build: selectedBuild) {
                ytdlpStatus = .complete(version)
            } else {
                ytdlpStatus = .actionRequired("yt-dlpの確認に失敗しました")
            }
        } else {
            ytdlpStatus = .pending
        }
        message = "確認が完了しました"
    }

    func runAutomaticSetup() async {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }

        do {
            let python = try await ensurePython()
            try await installPythonLibraries(python: python)
            try await installSelectedYTDLPBuild(python: python)
            _ = try await ensureFFmpeg()

            defaults.set(true, forKey: SetupDefaults.initialSetupCompleted)
            isSetupComplete = true
            message = "環境情報を更新しました"
        } catch {
            errorMessage = error.localizedDescription
            message = "環境情報を更新できませんでした"
        }
    }

    func applySelectedYTDLPBuild() async {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }

        do {
            let python = try await ensurePython()
            try await installPythonLibraries(python: python)
            try await installSelectedYTDLPBuild(python: python)

            defaults.set(true, forKey: SetupDefaults.initialSetupCompleted)
            isSetupComplete = true
            message = "yt-dlpを\(selectedBuild.displayName)に切り替えました"
        } catch {
            errorMessage = error.localizedDescription
            message = "yt-dlpの切り替えに失敗しました"
        }
    }

    func clearUpdateNotice() {
        updateNotice = pendingUpdateNotices.isEmpty ? nil : pendingUpdateNotices.removeFirst()
    }

    private func enqueueUpdateNotice(title: String, message: String) {
        let notice = SetupUpdateNotice(title: title, message: message)
        if updateNotice == nil {
            updateNotice = notice
        } else {
            pendingUpdateNotices.append(notice)
        }
    }

    func selectPython(_ url: URL) async {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            pythonStatus = .actionRequired("選択したファイルを実行できません")
            return
        }

        defaults.set(url.path, forKey: SetupDefaults.pythonPath)
        pythonStatus = .complete(url.path)
        librariesStatus = await verifyPythonLibraries(python: url) ? .complete("インストール済み") : .actionRequired("必要なライブラリをインストールしてください")
    }

    func selectFFmpeg(_ url: URL) {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            ffmpegStatus = .actionRequired("選択したファイルを実行できません")
            return
        }

        defaults.set(url.path, forKey: SetupDefaults.ffmpegPath)
        ffmpegStatus = .complete(url.path)
    }

    func completeManuallyIfReady() {
        guard pythonStatus.isComplete, librariesStatus.isComplete, ffmpegStatus.isComplete else {
            errorMessage = "未完了の項目があります"
            return
        }

        defaults.set(true, forKey: SetupDefaults.initialSetupCompleted)
        isSetupComplete = true
        errorMessage = nil
    }

    private func ensurePython() async throws -> URL {
        message = "Pythonを確認しています"
        if let python = await findPythonExecutable() {
            defaults.set(python.path, forKey: SetupDefaults.pythonPath)
            pythonStatus = .complete(python.path)
            return python
        }

        let brew = try await ensureHomebrew()

        message = "HomebrewでPythonをインストールしています"
        pythonStatus = .running("インストール中")
        try await ProcessRunner.run(brew, arguments: ["install", "python@3.10"], environment: setupEnvironment())

        guard let python = await findPythonExecutable() else {
            pythonStatus = .actionRequired("Pythonを選択してください")
            throw SetupError.pythonInstallFailed
        }

        defaults.set(python.path, forKey: SetupDefaults.pythonPath)
        pythonStatus = .complete(python.path)
        return python
    }

    private func installPythonLibraries(python: URL) async throws {
        message = "必要なライブラリをインストールしています"
        librariesStatus = .running("pip install 実行中")

        if await verifyPythonLibraries(python: python) {
            librariesStatus = .complete("インストール済み")
            return
        }

        let requirements = try requirementsFile()
        _ = try? await ProcessRunner.run(python, arguments: ["-m", "ensurepip", "--upgrade"], environment: setupEnvironment())
        try await ProcessRunner.run(python, arguments: ["-m", "pip", "install", "--user", "-r", requirements.path], environment: setupEnvironment())

        guard await verifyPythonLibraries(python: python) else {
            librariesStatus = .actionRequired("ライブラリの確認に失敗しました")
            throw SetupError.pythonLibrariesMissing
        }

        librariesStatus = .complete("インストール済み")
    }

    private func installSelectedYTDLPBuild(python: URL) async throws {
        message = "yt-dlp \(selectedBuild.displayName)をインストールしています"
        ytdlpStatus = .running("インストール中")

        await removeInstalledYTDLPBuilds(python: python)
        try await ProcessRunner.run(python, arguments: selectedBuild.installArguments, environment: setupEnvironment())

        guard let version = await installedYTDLPVersion(python: python, build: selectedBuild) else {
            ytdlpStatus = .actionRequired("yt-dlpの確認に失敗しました")
            throw SetupError.ytdlpInstallFailed
        }

        ytdlpStatus = .complete(version)
    }

    private func updatePythonLibrariesIfNeeded() async {
        guard isSetupComplete, !isRunning else { return }
        guard let python = await findPythonExecutable() else { return }
        guard await verifyPythonLibraries(python: python) else { return }

        isRunning = true
        errorMessage = nil
        defer { isRunning = false }

        do {
            let beforeVersions = await installedPythonLibraryVersions(python: python)
            let requirements = try pythonLibraryRequirementsFile()
            defer { try? FileManager.default.removeItem(at: requirements) }

            message = "Pythonライブラリの更新を確認しています"
            librariesStatus = .running("更新確認中")

            try await ProcessRunner.run(python, arguments: ["-m", "pip", "install", "--user", "-U", "-r", requirements.path], environment: setupEnvironment())

            guard await verifyPythonLibraries(python: python) else {
                librariesStatus = .actionRequired("ライブラリの確認に失敗しました")
                throw SetupError.pythonLibrariesMissing
            }

            let afterVersions = await installedPythonLibraryVersions(python: python)
            librariesStatus = .complete("インストール済み")
            message = "確認が完了しました"

            let changedLibraries = pythonLibraryPackages.compactMap { package -> String? in
                guard let afterVersion = afterVersions[package.displayName],
                      beforeVersions[package.displayName] != Optional(afterVersion) else {
                    return nil
                }
                return "\(package.displayName) \(afterVersion)"
            }

            if !changedLibraries.isEmpty {
                enqueueUpdateNotice(
                    title: "Pythonライブラリを更新しました",
                    message: "\(changedLibraries.joined(separator: ", "))に更新しました。"
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            message = "Pythonライブラリの更新確認に失敗しました"
        }
    }

    private func updateYTDLPIfNeeded() async {
        guard isSetupComplete, !isRunning else { return }
        guard let python = await findPythonExecutable() else { return }
        guard await verifyPythonLibraries(python: python) else { return }

        isRunning = true
        errorMessage = nil
        defer { isRunning = false }

        do {
            let beforeVersion = await installedYTDLPVersion(python: python, build: selectedBuild)
            message = "yt-dlpの更新を確認しています"
            ytdlpStatus = .running("更新確認中")

            try await ProcessRunner.run(python, arguments: selectedBuild.installArguments, environment: setupEnvironment())

            guard let afterVersion = await installedYTDLPVersion(python: python, build: selectedBuild) else {
                ytdlpStatus = .actionRequired("yt-dlpの確認に失敗しました")
                throw SetupError.ytdlpInstallFailed
            }

            ytdlpStatus = .complete(afterVersion)
            message = "確認が完了しました"

            if beforeVersion != Optional(afterVersion) {
                enqueueUpdateNotice(
                    title: "yt-dlpを更新しました",
                    message: "Ver.\(afterVersion)に更新しました。"
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            message = "yt-dlpの更新確認に失敗しました"
        }
    }

    private func removeInstalledYTDLPBuilds(python: URL) async {
        message = "既存のyt-dlpビルドを削除しています"
        _ = try? await ProcessRunner.run(
            python,
            arguments: ["-m", "pip", "uninstall", "-y", "yt-dlp", "yt-dlp-nightly"],
            environment: setupEnvironment()
        )
    }

    private func ensureHomebrew() async throws -> URL {
        if let brew = await findExecutable(named: "brew", savedPath: nil, extraCandidates: brewCandidates()) {
            return brew
        }

        message = "Homebrewをインストールしています"
        pythonStatus = .running("Homebrewをインストール中")

        var environment = setupEnvironment()
        environment["NONINTERACTIVE"] = "1"

        try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "-c",
                "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
            ],
            environment: environment
        )

        guard let brew = await findExecutable(named: "brew", savedPath: nil, extraCandidates: brewCandidates()) else {
            throw SetupError.homebrewInstallFailed
        }

        return brew
    }

    private func ensureFFmpeg() async throws -> URL {
        message = "ffmpegを確認しています"
        if let ffmpeg = await findExecutable(named: "ffmpeg", savedPath: ffmpegPath, extraCandidates: ffmpegCandidates()) {
            defaults.set(ffmpeg.path, forKey: SetupDefaults.ffmpegPath)
            ffmpegStatus = .complete(ffmpeg.path)
            return ffmpeg
        }

        let brew = try await ensureHomebrew()

        message = "Homebrewでffmpegをインストールしています"
        ffmpegStatus = .running("インストール中")
        try await ProcessRunner.run(brew, arguments: ["install", "ffmpeg"], environment: setupEnvironment())

        guard let ffmpeg = await findExecutable(named: "ffmpeg", savedPath: ffmpegPath, extraCandidates: ffmpegCandidates()) else {
            ffmpegStatus = .actionRequired("ffmpegを選択してください")
            throw SetupError.ffmpegInstallFailed
        }

        defaults.set(ffmpeg.path, forKey: SetupDefaults.ffmpegPath)
        ffmpegStatus = .complete(ffmpeg.path)
        return ffmpeg
    }

    private func verifyPythonLibraries(python: URL) async -> Bool {
        do {
            try await ProcessRunner.run(python, arguments: ["-c", "import fastapi, uvicorn, yt_dlp"], environment: setupEnvironment())
            return true
        } catch {
            return false
        }
    }

    private func installedPythonLibraryVersions(python: URL) async -> [String: String] {
        let distributions = pythonLibraryPackages.map(\.distributionName)
        let distributionList = distributions.map { "'\($0)'" }.joined(separator: ", ")
        let script = """
        from importlib.metadata import PackageNotFoundError, version
        for name in [\(distributionList)]:
            try:
                print(f"{name}=={version(name)}")
            except PackageNotFoundError:
                pass
        """

        do {
            let result = try await ProcessRunner.run(python, arguments: ["-c", script], environment: setupEnvironment())
            return result.output
                .split(separator: "\n")
                .reduce(into: [String: String]()) { versions, line in
                    let parts = line.split(separator: "=", maxSplits: 2, omittingEmptySubsequences: false)
                    guard parts.count == 3, parts[1].isEmpty else { return }
                    versions[String(parts[0])] = String(parts[2])
                }
        } catch {
            return [:]
        }
    }

    private func installedYTDLPVersion(python: URL, build: YTDLPBuild) async -> String? {
        do {
            let script = """
            import yt_dlp
            version = yt_dlp.version.__version__
            git_head = getattr(yt_dlp.version, "RELEASE_GIT_HEAD", "")
            if "\(build.rawValue)" == "master" and git_head:
                print(f"{version} (master {git_head[:7]})")
            else:
                print(version)
            """
            let result = try await ProcessRunner.run(python, arguments: ["-c", script], environment: setupEnvironment())
            let version = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return version.isEmpty ? nil : version
        } catch {
            return nil
        }
    }

    private func findPythonExecutable() async -> URL? {
        await findExecutable(named: "python3", savedPath: pythonPath, extraCandidates: pythonCandidates())
    }

    private func findExecutable(named name: String, savedPath: String?, extraCandidates: [String]) async -> URL? {
        let candidates = ([savedPath] + extraCandidates).compactMap { $0 }
        for path in candidates {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        do {
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: ["which", name], environment: setupEnvironment())
            let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        } catch { }

        return nil
    }

    private func pythonCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            ProcessInfo.processInfo.environment["YTDLP_MAC_APP_PYTHON"],
            "/opt/homebrew/bin/python3.10",
            "/opt/homebrew/opt/python@3.10/bin/python3.10",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3.10",
            "/usr/local/bin/python3",
            "\(home)/.pyenv/versions/3.10.0/bin/python3",
            "\(home)/.pyenv/shims/python3",
            "/usr/bin/python3",
        ].compactMap { $0 }
    }

    private func ffmpegCandidates() -> [String] {
        [
            ProcessInfo.processInfo.environment["FFMPEG_PATH"],
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ].compactMap { $0 }
    }

    private func brewCandidates() -> [String] {
        [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
        ]
    }

    private func requirementsFile() throws -> URL {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("requirements.txt"),
            serverDirectory()?.deletingLastPathComponent().appendingPathComponent("requirements.txt"),
            developmentProjectRoot().appendingPathComponent("requirements.txt"),
        ].compactMap { $0 }

        guard let url = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw SetupError.requirementsNotFound
        }

        return url
    }

    private func pythonLibraryRequirementsFile() throws -> URL {
        let source = try requirementsFile()
        let contents = try String(contentsOf: source, encoding: .utf8)
        let excludedNames = Set(["yt-dlp"])
        let filteredLines = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                guard let name = requirementName(from: line) else { return true }
                return !excludedNames.contains(name)
            }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytdlp-python-libraries-\(UUID().uuidString).txt")
        try filteredLines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func requirementName(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        var name = ""
        for character in trimmed {
            if character.isLetter || character.isNumber || character == "-" || character == "_" || character == "." {
                name.append(character)
            } else {
                break
            }
        }

        return name.isEmpty ? nil : name.lowercased()
    }

    private func serverDirectory() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            ProcessInfo.processInfo.environment["YTDLP_MAC_APP_SERVER_DIR"].map(URL.init(fileURLWithPath:)),
            Bundle.main.resourceURL?.appendingPathComponent("server"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("server"),
            developmentProjectRoot().appendingPathComponent("server"),
        ].compactMap { $0 }

        return candidates.first { fileManager.fileExists(atPath: $0.appendingPathComponent("main.py").path) }
    }

    private func developmentProjectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func setupEnvironment() -> [String: String] {
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
        return environment
    }
}

enum SetupDefaults {
    static let initialSetupCompleted = "initialSetupCompleted"
    static let pythonPath = "setupPythonPath"
    static let ffmpegPath = "setupFFmpegPath"
    static let ytdlpBuild = "setupYTDLPBuild"
}

struct SetupUpdateNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct PythonLibraryPackage {
    let requirementName: String
    let distributionName: String
    let displayName: String
}

enum YTDLPBuild: String, CaseIterable, Identifiable {
    case stable
    case nightly
    case master

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable:
            return "stable"
        case .nightly:
            return "nightly"
        case .master:
            return "master"
        }
    }

    var installArguments: [String] {
        switch self {
        case .stable:
            return ["-m", "pip", "install", "--user", "-U", "yt-dlp"]
        case .nightly:
            return ["-m", "pip", "install", "--user", "-U", "--pre", "yt-dlp[default]"]
        case .master:
            return [
                "-m", "pip", "install", "--user", "-U", "--no-cache-dir",
                "https://github.com/yt-dlp/yt-dlp-master-builds/releases/latest/download/yt-dlp.tar.gz",
            ]
        }
    }
}

enum SetupStepStatus: Equatable {
    case pending
    case running(String)
    case complete(String)
    case actionRequired(String)

    var title: String {
        switch self {
        case .pending:
            return "未確認"
        case .running(let detail):
            return detail
        case .complete(let detail):
            return detail
        case .actionRequired(let detail):
            return detail
        }
    }

    var isComplete: Bool {
        if case .complete = self {
            return true
        }
        return false
    }

    var needsAction: Bool {
        if case .actionRequired = self {
            return true
        }
        return false
    }
}

struct ProcessResult {
    let status: Int32
    let output: String
}

enum ProcessRunner {
    static func run(_ executable: URL, arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ytdlp-setup-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)

            do {
                let outputHandle = try FileHandle(forWritingTo: outputURL)
                process.standardOutput = outputHandle
                process.standardError = outputHandle
                process.terminationHandler = { process in
                    try? outputHandle.close()
                    let data = (try? Data(contentsOf: outputURL)) ?? Data()
                    try? FileManager.default.removeItem(at: outputURL)
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: ProcessResult(status: process.terminationStatus, output: output))
                    } else {
                        continuation.resume(throwing: SetupError.commandFailed(output))
                    }
                }

                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                continuation.resume(throwing: error)
            }
        }
    }
}

enum SetupError: LocalizedError {
    case homebrewInstallFailed
    case pythonNotFound
    case pythonInstallFailed
    case pythonLibrariesMissing
    case ffmpegNotFound
    case ffmpegInstallFailed
    case ytdlpInstallFailed
    case requirementsNotFound
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .homebrewInstallFailed:
            return "Homebrewの自動インストール後にbrewコマンドを確認できませんでした。"
        case .pythonNotFound:
            return "Python 3が見つかりません。Pythonをインストールするか、Python実行ファイルを選択してください。"
        case .pythonInstallFailed:
            return "Pythonの自動インストール後に実行ファイルを確認できませんでした。"
        case .pythonLibrariesMissing:
            return "必要なPythonライブラリを確認できませんでした。"
        case .ffmpegNotFound:
            return "ffmpegが見つかりません。ffmpegをインストールするか、ffmpeg実行ファイルを選択してください。"
        case .ffmpegInstallFailed:
            return "ffmpegの自動インストール後に実行ファイルを確認できませんでした。"
        case .ytdlpInstallFailed:
            return "yt-dlpのインストール確認に失敗しました。"
        case .requirementsNotFound:
            return "requirements.txtが見つかりません。"
        case .commandFailed(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "コマンドの実行に失敗しました。" : trimmed
        }
    }
}
