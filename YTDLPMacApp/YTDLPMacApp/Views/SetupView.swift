import AppKit
import SwiftUI

struct SetupView: View {
    @EnvironmentObject var setupManager: SetupManager
    @State private var selectedBuild: YTDLPBuild = .stable

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("環境情報")
                    .font(.system(size: 28, weight: .semibold))
                Text("Python、必要なライブラリ、ffmpeg、yt-dlpのビルドを確認します。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                SetupStepRow(title: "Python", status: setupManager.pythonStatus) {
                    choosePython()
                }
                SetupStepRow(title: "Pythonライブラリ", status: setupManager.librariesStatus, actionTitle: nil, action: nil)
                SetupStepRow(title: "ffmpeg", status: setupManager.ffmpegStatus) {
                    chooseFFmpeg()
                }
                SetupStepRow(title: "yt-dlp", status: setupManager.ytdlpStatus, actionTitle: nil, action: nil)
            }

            Picker("yt-dlpのバージョン", selection: $selectedBuild) {
                ForEach(YTDLPBuild.allCases) { build in
                    Text(build.displayName).tag(build)
                }
            }
            .pickerStyle(.segmented)
            .disabled(setupManager.isRunning)
            .onChange(of: selectedBuild) { _, build in
                guard setupManager.selectedBuild != build else { return }
                Task {
                    await Task.yield()
                    setupManager.selectedBuild = build
                    await setupManager.runAutomaticSetup()
                }
            }

            if setupManager.isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(setupManager.message)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(setupManager.message)
                    .foregroundStyle(.secondary)
            }

            if let error = setupManager.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            Spacer()

            HStack {
                Button("環境を再確認") {
                    Task {
                        await setupManager.inspectEnvironment()
                    }
                }
                .disabled(setupManager.isRunning)

                Spacer()

                Button("完了して開始") {
                    setupManager.completeManuallyIfReady()
                }
                .disabled(setupManager.isRunning)

                Button("自動セットアップ") {
                    Task {
                        await setupManager.runAutomaticSetup()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(setupManager.isRunning)
            }
        }
        .padding(28)
        .frame(minWidth: 680, minHeight: 520)
        .task {
            selectedBuild = setupManager.selectedBuild
            await setupManager.inspectEnvironment()
        }
        .onChange(of: setupManager.selectedBuild) { _, build in
            if selectedBuild != build {
                selectedBuild = build
            }
        }
    }

    private func choosePython() {
        guard let url = chooseExecutablePanel(title: "Python実行ファイルを選択", prompt: "Pythonを選択") else {
            return
        }

        Task {
            await setupManager.selectPython(url)
        }
    }

    private func chooseFFmpeg() {
        guard let url = chooseExecutablePanel(title: "ffmpeg実行ファイルを選択", prompt: "ffmpegを選択") else {
            return
        }

        setupManager.selectFFmpeg(url)
    }

    private func chooseExecutablePanel(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct SetupStepRow: View {
    let title: String
    let status: SetupStepStatus
    var actionTitle: String? = "参照..."
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(status.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let action, let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .actionRequired:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
