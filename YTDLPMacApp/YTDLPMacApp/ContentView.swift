import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: DownloadViewModel
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var setupManager: SetupManager
    @State private var selectedTab: AppTab = .download

    enum AppTab: String, CaseIterable {
        case download = "ダウンロード"
        case library = "ライブラリ"
        case settings = "設定"

        var icon: String {
            switch self {
            case .download: return "arrow.down.circle.fill"
            case .library: return "folder.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        Group {
            if setupManager.isSetupComplete {
                mainContent
            } else {
                SetupView()
                    .environmentObject(setupManager)
            }
        }
        .task {
            await setupManager.runStartupEnvironmentCheck()
            if setupManager.isSetupComplete {
                startServer()
            }
        }
        .onChange(of: setupManager.isSetupComplete) { _, isComplete in
            if isComplete {
                startServer()
            }
        }
        .alert(item: $setupManager.updateNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK")) {
                    setupManager.clearUpdateNotice()
                }
            )
        }
    }

    private var isServerAvailable: Bool {
        viewModel.isConnected || serverManager.isServerReachable
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // サーバー接続状態インジケーター
            HStack {
                Circle()
                    .fill(isServerAvailable ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(isServerAvailable ? "サーバー接続中" : "サーバー未接続")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if serverManager.isStarting {
                    ProgressView()
                        .controlSize(.mini)
                    Text("サーバー起動中")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if let error = serverManager.lastError, !isServerAvailable {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
                Spacer()
                if let version = viewModel.serverVersion {
                    Text("v\(version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            // メインコンテンツ
            Group {
                switch selectedTab {
                case .download:
                    DownloadView()
                        .environmentObject(viewModel)
                case .library:
                    LibraryView()
                        .environmentObject(viewModel)
                case .settings:
                    SettingsView()
                        .environmentObject(viewModel)
                        .environmentObject(serverManager)
                        .environmentObject(setupManager)
                }
            }

            Divider()

            // タブバー
            HStack(spacing: 0) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Button(action: {
                        selectedTab = tab
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 18))
                            Text(tab.rawValue)
                                .font(.system(size: 11))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                }
            }
            .padding(.bottom, 4)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onChange(of: viewModel.isConnected) { _, isConnected in
            if isConnected {
                serverManager.clearError()
            }
        }
        .onChange(of: serverManager.isServerReachable) { _, isReachable in
            if isReachable {
                serverManager.clearError()
            }
        }
    }

    private func startServer() {
        Task {
            await serverManager.startIfNeeded()
            await viewModel.refreshServerConnection()
            await serverManager.refreshReachability()
        }
    }
}
