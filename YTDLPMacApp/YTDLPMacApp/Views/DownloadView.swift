import SwiftUI

struct DownloadView: View {
    @EnvironmentObject var viewModel: DownloadViewModel
    @State private var showFormatPicker = false

    var body: some View {
        HSplitView {
            // 左パネル - URL入力 & 動画情報
            VStack(spacing: 0) {
                // URL入力セクション
                VStack(spacing: 12) {
                    Text("動画をダウンロード")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(alignment: .center, spacing: 8) {
                        TextField("動画のURLを貼り付けてください", text: $viewModel.urlText)
                            .textFieldStyle(.roundedBorder)
                            .frame(height: 32)
                            .onSubmit {
                                Task { await viewModel.fetchVideoInfo() }
                            }
                        Button(action: {
                            Task { await viewModel.fetchVideoInfo() }
                        }) {
                            if viewModel.isLoadingVideoInfo {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 24, height: 24)
                            } else {
                                Image(systemName: "magnifyingglass")
                                    .frame(width: 24, height: 24)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.hasURL)
                        .help("動画情報を取得")

                        Button(action: {
                            if let clipboard = NSPasteboard.general.string(forType: .string) {
                                viewModel.urlText = clipboard
                            }
                        }) {
                            Image(systemName: "doc.on.clipboard")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.bordered)
                        .help("クリップボードから貼り付け")
                    }
                }
                .padding()

                Divider()

                // 動画情報表示
                if let videoInfo = viewModel.videoInfo {
                    ScrollView {
                        VideoInfoCard(videoInfo: videoInfo)
                            .padding()
                    }
                } else if viewModel.isLoadingVideoInfo {
                    VStack(spacing: 12) {
                        ProgressView("動画情報を取得中...")
                            .padding()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.videoInfoError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(error)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("URLを入力して動画を検索")
                            .foregroundColor(.secondary)
                        Text("対応サイト: YouTube, Twitter/X, ニコニコ動画, etc.")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // エラーメッセージ
                if let errorMessage = viewModel.currentErrorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(2)
                        Spacer()
                        Button(action: { viewModel.currentErrorMessage = nil }) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .frame(minWidth: 350)

            // 右パネル - アクティブなダウンロード & フォーマット選択
            VStack(spacing: 0) {
                // フォーマット選択（動画情報がある場合）
                if viewModel.videoInfo != nil {
                    VStack(spacing: 8) {
                        Text("ダウンロード設定")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // フォーマット選択
                        Picker("形式", selection: $viewModel.selectedFormatId) {
                            Text("互換MP4（自動）").tag("")
                            ForEach(viewModel.formatGroups) { group in
                                Section(group.title) {
                                    ForEach(group.formats) { format in
                                        Text(format.menuDisplayName)
                                            .font(.system(.body, design: .monospaced))
                                            .tag(format.formatId)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))

                    // ダウンロードボタン
                    HStack(spacing: 12) {
                        Button(action: {
                            viewModel.clearVideoInfo()
                        }) {
                            Label("キャンセル", systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button(action: {
                            Task { await viewModel.startDownload() }
                        }) {
                            Label("ダウンロード開始", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(viewModel.isDownloading)
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()
                }

                // アクティブなダウンロード一覧
                VStack(spacing: 0) {
                    HStack {
                        Text("ダウンロード状況")
                            .font(.headline)
                        Spacer()
                        if runningTaskCount > 0 {
                            Text("進行中 \(runningTaskCount)件")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if !viewModel.activeTasks.isEmpty {
                            Text("\(viewModel.activeTasks.count)件")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if hasClearableTasks {
                            Button("完了をクリア") {
                                Task { await viewModel.clearCompletedTasks() }
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    if viewModel.activeTasks.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Text("まだダウンロードはありません")
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding()
                    } else {
                        List {
                            ForEach(viewModel.activeTasks) { task in
                                ActiveTaskRow(task: task, viewModel: viewModel)
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .frame(minWidth: 350)
        }
        .sheet(item: $viewModel.postDownloadTask) { task in
            PostDownloadActionSheet(task: task, viewModel: viewModel)
        }
    }

    private var runningTaskCount: Int {
        viewModel.activeTasks.filter { task in
            ["pending", "downloading", "processing"].contains(task.status)
        }.count
    }

    private var hasClearableTasks: Bool {
        viewModel.activeTasks.contains { task in
            ["completed", "error", "cancelled"].contains(task.status)
        }
    }
}

// MARK: - Video Info Card

struct VideoInfoCard: View {
    let videoInfo: VideoInfo
    @EnvironmentObject var viewModel: DownloadViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // サムネイルと基本情報
            HStack(alignment: .top, spacing: 12) {
                // サムネイル
                AsyncImage(url: URL(string: videoInfo.thumbnail)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 160, height: 90)
                        .cornerRadius(8)
                } placeholder: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 160, height: 90)
                        .cornerRadius(8)
                        .overlay(
                            ProgressView()
                        )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(videoInfo.title)
                        .font(.headline)
                        .lineLimit(3)

                    if !videoInfo.uploader.isEmpty {
                        Text(videoInfo.uploader)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // メタ情報
            HStack(spacing: 16) {
                if videoInfo.duration > 0 {
                    Label(videoInfo.durationString, systemImage: "clock")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if videoInfo.viewCount > 0 {
                    Label(videoInfo.formattedViewCount + "回視聴", systemImage: "eye")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let date = videoInfo.displayUploadDate {
                    Label(date, systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // 説明
            if !videoInfo.description.isEmpty {
                Text(videoInfo.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(4)
            }

            // フォーマット数
            Text("\(videoInfo.formats.count)種類のフォーマットが利用可能")
                .font(.caption)
                .foregroundColor(.accentColor)
        }
    }
}

// MARK: - Active Task Row

struct ActiveTaskRow: View {
    let task: DownloadTaskResponse
    let viewModel: DownloadViewModel

    @State private var thumbnailImage: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            // サムネイル
            if !task.thumbnail.isEmpty {
                AsyncImage(url: URL(string: task.thumbnail)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 27)
                        .cornerRadius(4)
                } placeholder: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 48, height: 27)
                        .cornerRadius(4)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title.isEmpty ? "処理中..." : task.title)
                    .font(.caption)
                    .lineLimit(1)

                if task.status == "downloading" || task.status == "processing" {
                    HStack(spacing: 8) {
                        // プログレスバー
                        ProgressView(value: task.progress / 100.0)
                            .frame(maxWidth: 200)

                        Text("\(task.progress, specifier: "%.1f")%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)

                        Text(task.speed)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)

                        if task.eta != "計算中..." {
                            Text(task.eta)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                } else if task.status == "completed" {
                    Label("完了", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                } else if task.status == "error" {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("エラー", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                        if !task.errorMessage.isEmpty {
                            Text(task.errorMessage)
                                .font(.system(size: 10))
                                .foregroundColor(.red.opacity(0.8))
                                .lineLimit(2)
                        }
                    }
                } else if task.status == "cancelled" {
                    Label("キャンセル", systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // アクションボタン
            if task.status == "completed" {
                Button(action: {
                    viewModel.revealFileInFinder(path: task.filepath)
                }) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Finderで表示")
            } else if task.status == "downloading" || task.status == "processing" {
                Button(action: {
                    Task { await viewModel.cancelDownload(taskId: task.taskId) }
                }) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
                .help("キャンセル")
            } else if task.status == "error" {
                Button(action: {
                    viewModel.copyErrorMessage(task.errorMessage)
                }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("エラーをコピー")

                Button(action: {
                    Task { await viewModel.retryDownload(task: task) }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("再試行")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PostDownloadActionSheet: View {
    let task: DownloadTaskResponse
    let viewModel: DownloadViewModel

    @Environment(\.dismiss) private var dismiss
    @AppStorage("showPostDownloadActions") private var showPostDownloadActions = true
    @State private var doNotShowAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("ダウンロードが完了しました", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundColor(.green)

            Text(task.title.isEmpty ? task.filename : task.title)
                .font(.subheadline)
                .lineLimit(2)

            Toggle("今後は表示しない", isOn: $doNotShowAgain)

            HStack {
                Button("何もしない") {
                    close()
                }

                Spacer()

                Button("Finderで表示") {
                    viewModel.openCompletedFileInFinder(task)
                    close()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func close() {
        if doNotShowAgain {
            showPostDownloadActions = false
        }
        dismiss()
    }
}
