import SwiftUI

@main
struct YTDLPMacApp: App {
    @StateObject private var downloadViewModel = DownloadViewModel()
    @StateObject private var serverManager = ServerManager()
    @StateObject private var setupManager = SetupManager()

    var body: some Scene {
        WindowGroup("YT-Downloader") {
            ContentView()
                .environmentObject(downloadViewModel)
                .environmentObject(serverManager)
                .environmentObject(setupManager)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("ダウンロードフォルダを開く") {
                    downloadViewModel.openDownloadFolder()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(downloadViewModel)
                .environmentObject(serverManager)
                .environmentObject(setupManager)
        }
    }
}
