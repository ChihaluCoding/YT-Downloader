import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var viewModel: DownloadViewModel
    @AppStorage("libraryDisplayStyle") private var libraryDisplayStyle = LibraryDisplayStyle.list.rawValue
    @State private var selectedFileID: DownloadedFile.ID?
    @State private var showDeleteConfirmation = false

    private var selectedFile: DownloadedFile? {
        viewModel.filteredFiles.first { $0.id == selectedFileID }
    }

    private var displayStyle: LibraryDisplayStyle {
        LibraryDisplayStyle(rawValue: libraryDisplayStyle) ?? .list
    }

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Text("ダウンロード済みファイル")
                    .font(.headline)

                Spacer()

                // 検索バー
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("検索", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .frame(width: 200)

                Button(action: {
                    Task { await viewModel.refreshDownloadedFiles() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("更新")

                Button(action: {
                    viewModel.openDownloadFolder()
                }) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("ダウンロードフォルダを開く")
            }
            .padding()

            Divider()

            // ファイルリスト
            Group {
                if viewModel.isLoadingFiles {
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView("読み込み中...")
                        Spacer()
                    }
                } else if viewModel.filteredFiles.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "folder")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.5))
                        if viewModel.searchText.isEmpty {
                            Text("ダウンロード済みファイルはありません")
                                .foregroundColor(.secondary)
                            Text("左側のパネルから動画をダウンロードしてください")
                                .font(.caption)
                                .foregroundColor(.secondary.opacity(0.7))
                        } else {
                            Text("\"\(viewModel.searchText)\"に一致するファイルがありません")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    switch displayStyle {
                    case .list:
                        fileList
                    case .grid:
                        fileGrid
                    }
                }
            }
        }
        .alert("ファイルを削除", isPresented: $showDeleteConfirmation) {
            Button("キャンセル", role: .cancel) { }
            Button("削除", role: .destructive) {
                if let file = selectedFile {
                    Task { await viewModel.deleteFile(path: file.path) }
                    selectedFileID = nil
                }
            }
        } message: {
            if let file = selectedFile {
                Text("「\(file.name)」を削除しますか？この操作は取り消せません。")
            }
        }
    }

    private var fileList: some View {
        List(selection: $selectedFileID) {
            ForEach(viewModel.filteredFiles) { file in
                fileListRow(file)
                    .tag(file.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        viewModel.openFile(path: file.path)
                    }
                    .contextMenu {
                        fileContextMenu(file)
                    }
            }
        }
        .onDeleteCommand {
            if selectedFile != nil {
                showDeleteConfirmation = true
            }
        }
    }

    private var fileGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 12)],
                spacing: 12
            ) {
                ForEach(viewModel.filteredFiles) { file in
                    fileGridItem(file)
                        .onTapGesture {
                            selectedFileID = file.id
                        }
                        .onTapGesture(count: 2) {
                            viewModel.openFile(path: file.path)
                        }
                        .contextMenu {
                            fileContextMenu(file)
                        }
                }
            }
            .padding()
        }
    }

    private func fileListRow(_ file: DownloadedFile) -> some View {
        HStack(spacing: 10) {
            fileIcon(for: file.name)
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)

                Text("\(file.sizeStr) - \(file.formattedDate)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private func fileGridItem(_ file: DownloadedFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            fileIcon(for: file.name)
                .font(.system(size: 36))
                .foregroundColor(.accentColor)

            Text(file.name)
                .font(.headline)
                .lineLimit(2)
                .frame(minHeight: 42, alignment: .topLeading)

            Text(file.sizeStr)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(file.formattedDate)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selectedFileID == file.id ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    @ViewBuilder
    private func fileContextMenu(_ file: DownloadedFile) -> some View {
        Button("開く") {
            viewModel.openFile(path: file.path)
        }
        .keyboardShortcut("o", modifiers: .command)

        Divider()

        Button("Finderで表示") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
        }

        Divider()

        Button("ゴミ箱に移動", role: .destructive) {
            selectedFileID = file.id
            showDeleteConfirmation = true
        }
        .keyboardShortcut(.delete, modifiers: .command)
    }

    private func fileIcon(for name: String) -> Image {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v", "mov", "avi", "mkv", "webm":
            return Image(systemName: "film")
        case "mp3", "m4a", "wav", "flac", "aac", "opus":
            return Image(systemName: "music.note")
        case "srt", "ass", "vtt":
            return Image(systemName: "captions.bubble")
        default:
            return Image(systemName: "doc")
        }
    }
}

enum LibraryDisplayStyle: String {
    case list
    case grid
}
