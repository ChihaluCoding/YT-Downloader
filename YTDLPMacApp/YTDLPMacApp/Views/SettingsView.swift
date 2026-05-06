import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var viewModel: DownloadViewModel
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var setupManager: SetupManager
    @AppStorage("serverHost") private var serverHost = "127.0.0.1"
    @AppStorage("serverPort") private var serverPort = "18765"
    @AppStorage("defaultDownloadPath") private var defaultDownloadPath = "~/Downloads/yt-dlp"
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @AppStorage("libraryDisplayStyle") private var libraryDisplayStyle = LibraryDisplayStyle.list.rawValue
    @AppStorage("cookiesFromBrowser") private var cookiesFromBrowser = "auto"
    @AppStorage("showLowResolutionFormats") private var showLowResolutionFormats = false
    @AppStorage("duplicateFilePolicy") private var duplicateFilePolicy = "skip"
    @AppStorage("showPostDownloadActions") private var showPostDownloadActions = true

    @State private var healthStatus: HealthStatus?
    @State private var isLoadingHealth = false
    @State private var selectedBuild: YTDLPBuild = .stable

    var body: some View {
        Form {
            // 環境情報
            Section("環境情報") {
                if needsInitialSetup {
                    Button("初期設定をする") {
                        Task {
                            await setupManager.runAutomaticSetup()
                            await refreshConnectionAndHealth()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(setupManager.isRunning)
                }

                setupStatusRow(title: "Python", status: setupManager.pythonStatus)
                setupStatusRow(title: "Pythonライブラリ", status: setupManager.librariesStatus)
                setupStatusRow(title: "ffmpeg", status: setupManager.ffmpegStatus)
                setupStatusRow(title: "yt-dlp", status: setupManager.ytdlpStatus)

                Picker("yt-dlp ビルド", selection: $selectedBuild) {
                    ForEach(YTDLPBuild.allCases) { build in
                        Text(build.displayName).tag(build)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(setupManager.isRunning || serverManager.isStarting)
                .onChange(of: selectedBuild) { _, build in
                    guard setupManager.selectedBuild != build else { return }
                    Task {
                        await Task.yield()
                        await switchYTDLPBuild(to: build)
                    }
                }

                if let error = setupManager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            // サーバー接続設定
            Section("サーバー接続") {
                HStack {
                    Text("ホスト")
                    TextField("", text: $serverHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit {
                            applyServerConnectionSettings()
                        }
                }

                HStack {
                    Text("ポート")
                    TextField("", text: $serverPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit {
                            applyServerConnectionSettings()
                        }
                }

                HStack {
                    Circle()
                        .fill(viewModel.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(viewModel.isConnected ? "接続済み" : "未接続")
                        .foregroundColor(viewModel.isConnected ? .green : .red)

                    Spacer()

                    Button("接続テスト") {
                        applyServerConnectionSettings()
                    }
                    .disabled(isLoadingHealth)
                }
            }

            // ダウンロード設定
            Section("ダウンロード設定") {
                HStack {
                    Text("保存先フォルダー")
                    Spacer()
                    Button(defaultDownloadPath) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            defaultDownloadPath = url.path
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Picker("Cookie", selection: $cookiesFromBrowser) {
                    Text("自動").tag("auto")
                    Text("使用しない").tag("none")
                    Text("Safari").tag("safari")
                    Text("Chrome").tag("chrome")
                    Text("Brave").tag("brave")
                    Text("Edge").tag("edge")
                    Text("Firefox").tag("firefox")
                }
                .onChange(of: cookiesFromBrowser) { _, _ in
                    applyServerConnectionSettings()
                }

                Picker("同名ファイル", selection: $duplicateFilePolicy) {
                    Text("スキップ").tag("skip")
                    Text("上書き").tag("overwrite")
                    Text("自動リネーム").tag("rename")
                }

                Toggle("480p以下の形式を表示", isOn: $showLowResolutionFormats)
            }

            // アプリ設定
            Section("アプリ設定") {
                Toggle("起動時に自動的にサーバーに接続", isOn: $autoCheckUpdates)

                Picker("リスト表示形式", selection: $libraryDisplayStyle) {
                    Text("リスト").tag(LibraryDisplayStyle.list.rawValue)
                    Text("グリッド").tag(LibraryDisplayStyle.grid.rawValue)
                }

                Toggle("完了後の操作を確認", isOn: $showPostDownloadActions)
            }
            // このアプリについて
            Section("このアプリについて") {
                HStack {
                    Text("アプリバージョン")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("GitHub")
                    Spacer()
                    Link("ChihaluCoding/YT-Downloader", destination: URL(string: "https://github.com/ChihaluCoding/YT-Downloader")!)
                }

                HStack {
                    Text("X")
                    Spacer()
                    Link("@ChihaluCoding", destination: URL(string: "https://x.com/ChihaluCoding")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 550, minHeight: 500)
        .onAppear {
            selectedBuild = setupManager.selectedBuild
        }
        .task {
            await refreshConnectionAndHealth()
        }
        .onChange(of: setupManager.selectedBuild) { _, build in
            if selectedBuild != build {
                selectedBuild = build
            }
        }
        .onChange(of: viewModel.isConnected) { _, isConnected in
            guard isConnected else { return }
            Task {
                await loadHealthStatus()
            }
        }
    }

    private var needsInitialSetup: Bool {
        setupManager.pythonStatus.needsAction ||
        setupManager.librariesStatus.needsAction ||
        setupManager.ffmpegStatus.needsAction ||
        setupManager.ytdlpStatus.needsAction
    }

    private func refreshConnectionAndHealth() async {
        isLoadingHealth = true
        await viewModel.refreshServerConnection()
        await loadHealthStatus(keepLoadingState: true)
        isLoadingHealth = false
    }

    private func applyServerConnectionSettings() {
        serverHost = sanitizedHost(serverHost)
        serverPort = sanitizedPort(serverPort)
        Task {
            await serverManager.restart()
            await refreshConnectionAndHealth()
        }
    }

    private func sanitizedHost(_ value: String) -> String {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? "127.0.0.1" : host
    }

    private func sanitizedPort(_ value: String) -> String {
        let portText = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(portText), (1...65535).contains(port) else {
            return "18765"
        }
        return String(port)
    }

    private func switchYTDLPBuild(to build: YTDLPBuild) async {
        if setupManager.selectedBuild != build {
            setupManager.selectedBuild = build
        }

        healthStatus = nil
        isLoadingHealth = true

        await serverManager.stop()
        await setupManager.applySelectedYTDLPBuild()

        if setupManager.errorMessage == nil {
            await serverManager.startIfNeeded()
            await viewModel.refreshServerConnection()
            await loadHealthStatus(keepLoadingState: true)
        }

        isLoadingHealth = false
    }

    private func loadHealthStatus(keepLoadingState: Bool = false) async {
        if !keepLoadingState {
            isLoadingHealth = true
        }

        do {
            healthStatus = try await APIClient.shared.getHealthStatus()
        } catch {
            healthStatus = nil
        }

        if !keepLoadingState {
            isLoadingHealth = false
        }
    }

    private func setupStatusRow(title: String, status: SetupStepStatus) -> some View {
        HStack {
            setupStatusIcon(status)
                .frame(width: 16)
            Text(title)
            Spacer()
            Text(status.title)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func setupStatusIcon(_ status: SetupStepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundColor(.secondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .actionRequired:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        }
    }
}
