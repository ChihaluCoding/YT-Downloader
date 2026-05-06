import SwiftUI
import Combine
import Foundation
import UserNotifications

struct FormatGroup: Identifiable {
    let category: String
    let ext: String
    let formats: [VideoFormat]

    var id: String { "\(category)-\(ext)" }
    var title: String { "\(category) / \(ext)" }
}

@MainActor
class DownloadViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var urlText: String = ""
    @Published var videoInfo: VideoInfo?
    @Published var isLoadingVideoInfo = false
    @Published var videoInfoError: String?

    @Published var activeTasks: [DownloadTaskResponse] = []
    @Published var downloadedFiles: [DownloadedFile] = []
    @Published var isLoadingFiles = false

    @Published var selectedFormatId: String = ""
    @Published var isConnected = false
    @Published var serverVersion: String?

    @Published var isDownloading = false
    @Published var currentErrorMessage: String?
    @Published var postDownloadTask: DownloadTaskResponse?

    @Published var searchText: String = ""

    // MARK: - Private Properties

    @AppStorage("showLowResolutionFormats") private var showLowResolutionFormats = false
    @AppStorage("duplicateFilePolicy") private var duplicateFilePolicy = "skip"
    @AppStorage("showPostDownloadActions") private var showPostDownloadActions = true

    private let api = APIClient.shared
    private var refreshTimer: Timer?
    private var progressTasks: Set<String> = []

    init() {
        activeTasks = Self.loadPersistedTasks()
        requestNotificationAuthorization()
    }

    var trimmedURLText: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasURL: Bool {
        !trimmedURLText.isEmpty
    }

    // MARK: - Filtered Downloads

    var filteredFiles: [DownloadedFile] {
        if searchText.isEmpty {
            return downloadedFiles
        }
        return downloadedFiles.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Server Connection

    func checkServerConnection() {
        Task {
            await refreshServerConnection()
        }
    }

    func refreshServerConnection() async {
        isConnected = await api.isConnected()
        if isConnected {
            await refreshAllTasks()
            await refreshDownloadedFiles()
            startAutoRefresh()
        } else {
            stopAutoRefresh()
        }
    }

    func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshActiveTasks()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Video Info

    func fetchVideoInfo() async {
        let urlText = trimmedURLText
        guard !urlText.isEmpty else {
            videoInfoError = "URLを入力してください"
            return
        }

        // URLのバリデーション
        guard let url = URL(string: urlText),
              let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            videoInfoError = "有効なURLを入力してください（https://...）"
            return
        }

        isLoadingVideoInfo = true
        videoInfoError = nil
        videoInfo = nil

        do {
            let info = try await api.getVideoInfo(url: urlText)
            videoInfo = info
            selectedFormatId = ""
        } catch {
            videoInfoError = error.localizedDescription
        }

        isLoadingVideoInfo = false
    }

    func clearVideoInfo() {
        videoInfo = nil
        videoInfoError = nil
        urlText = ""
        selectedFormatId = ""
    }

    // MARK: - Downloads

    func startDownload() async {
        let url = trimmedURLText
        guard !url.isEmpty else { return }

        isDownloading = true
        currentErrorMessage = nil

        do {
            let response = try await api.startDownload(
                url: url,
                formatId: selectedFormatId,
                subtitle: false,
                duplicatePolicy: duplicateFilePolicy
            )

            activeTasks.insert(response.status, at: 0)
            progressTasks.insert(response.taskId)
            Task { await monitorProgress(taskId: response.taskId) }

        } catch {
            currentErrorMessage = error.localizedDescription
        }

        isDownloading = false
    }

    func monitorProgress(taskId: String) async {
        while progressTasks.contains(taskId) {
            do {
                let task = try await api.getTaskStatus(taskId: taskId)

                // タスクリストを更新
                if let index = activeTasks.firstIndex(where: { $0.taskId == taskId }) {
                    activeTasks[index] = task
                } else {
                    activeTasks.insert(task, at: 0)
                }

                // 終了状態なら監視を終了
                if ["completed", "error", "cancelled"].contains(task.status) {
                    progressTasks.remove(taskId)

                    // 完了したらファイルリストを更新
                    if task.status == "completed" {
                        await refreshDownloadedFiles()
                        notify(title: "ダウンロード完了", body: task.title.isEmpty ? task.filename : task.title)
                        if showPostDownloadActions {
                            postDownloadTask = task
                        }
                    } else if task.status == "error" {
                        notify(title: "ダウンロード失敗", body: task.errorMessage.isEmpty ? task.url : task.errorMessage)
                    }
                    persistHistory()
                    return
                }
            } catch {
                // エラー時は少し待ってリトライ
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        }
    }

    func cancelDownload(taskId: String) async {
        do {
            try await api.cancelDownload(taskId: taskId)
            progressTasks.remove(taskId)
            await refreshAllTasks()
        } catch {
            currentErrorMessage = error.localizedDescription
        }
    }

    func retryDownload(task: DownloadTaskResponse) async {
        guard !task.url.isEmpty else { return }

        currentErrorMessage = nil

        do {
            let response = try await api.startDownload(
                url: task.url,
                formatId: task.formatId,
                subtitle: false,
                duplicatePolicy: task.duplicatePolicy
            )

            activeTasks.insert(response.status, at: 0)
            progressTasks.insert(response.taskId)
            Task { await monitorProgress(taskId: response.taskId) }
        } catch {
            currentErrorMessage = error.localizedDescription
        }
    }

    func clearCompletedTasks() async {
        do {
            try await api.clearCompleted()
            activeTasks.removeAll { ["completed", "error", "cancelled"].contains($0.status) }
            persistHistory()
        } catch { }
    }

    // MARK: - File Management

    func refreshDownloadedFiles() async {
        isLoadingFiles = true
        do {
            downloadedFiles = try await api.getDownloadedFiles()
        } catch { }
        isLoadingFiles = false
    }

    func openDownloadFolder() {
        Task {
            do {
                try await api.openDownloadFolder()
            } catch {
                currentErrorMessage = error.localizedDescription
            }
        }
    }

    func openFile(path: String) {
        Task {
            do {
                try await api.openFile(path: path)
            } catch {
                currentErrorMessage = error.localizedDescription
            }
        }
    }

    func revealFileInFinder(path: String) {
        Task {
            do {
                try await api.revealFile(path: path)
            } catch {
                currentErrorMessage = error.localizedDescription
            }
        }
    }

    func copyErrorMessage(_ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }

    func openCompletedFileInFinder(_ task: DownloadTaskResponse) {
        revealFileInFinder(path: task.filepath)
    }

    func deleteFile(path: String) async {
        do {
            try await api.deleteFile(path: path)
            await refreshDownloadedFiles()
        } catch {
            currentErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Task Refresh

    func refreshAllTasks() async {
        do {
            activeTasks = mergedTasks(serverTasks: try await api.getAllTasks())
            persistHistory()
        } catch { }
    }

    func refreshActiveTasks() async {
        // アクティブなタスクのみ更新
        for task in activeTasks where progressTasks.contains(task.taskId) {
            do {
                let updated = try await api.getTaskStatus(taskId: task.taskId)
                if let index = activeTasks.firstIndex(where: { $0.taskId == task.taskId }) {
                    activeTasks[index] = updated
                }
            } catch { }
        }
    }

    // MARK: - Format Helpers

    var sortedFormats: [VideoFormat] {
        guard let info = videoInfo else { return [] }
        return sortFormats(info.formats)
    }

    var formatGroups: [FormatGroup] {
        guard let info = videoInfo else { return [] }

        let videoGroups = groupedFormats(
            category: "動画",
            formats: info.formats.filter { format in
                format.hasVideo && (showLowResolutionFormats || format.height > 480)
            }
        )
        let audioGroups = groupedFormats(
            category: "音声",
            formats: info.formats.filter { $0.isAudioOnly }
        )

        return videoGroups + audioGroups
    }

    var bestFormat: VideoFormat? {
        sortedFormats.first
    }

    private func groupedFormats(category: String, formats: [VideoFormat]) -> [FormatGroup] {
        Dictionary(grouping: formats, by: { $0.normalizedExtension })
            .map { ext, formats in
                FormatGroup(category: category, ext: ext, formats: sortFormats(formats))
            }
            .sorted { lhs, rhs in
                let lhsRank = extensionRank(lhs.ext, category: category)
                let rhsRank = extensionRank(rhs.ext, category: category)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.ext.localizedStandardCompare(rhs.ext) == .orderedAscending
            }
    }

    private func sortFormats(_ formats: [VideoFormat]) -> [VideoFormat] {
        formats.sorted { lhs, rhs in
            if lhs.isAudioOnly || rhs.isAudioOnly {
                if lhs.tbr != rhs.tbr {
                    return lhs.tbr > rhs.tbr
                }
                if lhs.formatNote != rhs.formatNote {
                    return lhs.formatNote.localizedStandardCompare(rhs.formatNote) == .orderedAscending
                }
                return lhs.formatId.localizedStandardCompare(rhs.formatId) == .orderedAscending
            }

            if lhs.height != rhs.height {
                return lhs.height > rhs.height
            }
            if lhs.fps != rhs.fps {
                return lhs.fps > rhs.fps
            }
            if lhs.tbr != rhs.tbr {
                return lhs.tbr > rhs.tbr
            }
            return lhs.formatId.localizedStandardCompare(rhs.formatId) == .orderedAscending
        }
    }

    private func extensionRank(_ ext: String, category: String) -> Int {
        let preferredOrder: [String]
        if category == "音声" {
            preferredOrder = ["MP3", "M4A", "WAV", "FLAC", "OPUS", "WEBM", "AAC", "OGG"]
        } else {
            preferredOrder = ["MP4", "WEBM", "MOV", "MKV"]
        }

        return preferredOrder.firstIndex(of: ext) ?? (preferredOrder.count + 100)
    }

    private func mergedTasks(serverTasks: [DownloadTaskResponse]) -> [DownloadTaskResponse] {
        let serverIDs = Set(serverTasks.map(\.taskId))
        let savedHistory = activeTasks.filter { task in
            !serverIDs.contains(task.taskId) && isTerminalStatus(task.status)
        }
        return serverTasks + savedHistory
    }

    private func isTerminalStatus(_ status: String) -> Bool {
        ["completed", "error", "cancelled"].contains(status)
    }

    private func persistHistory() {
        let history = activeTasks.filter { isTerminalStatus($0.status) }
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: "downloadTaskHistory")
    }

    private static func loadPersistedTasks() -> [DownloadTaskResponse] {
        guard let data = UserDefaults.standard.data(forKey: "downloadTaskHistory"),
              let tasks = try? JSONDecoder().decode([DownloadTaskResponse].self, from: data) else {
            return []
        }
        return tasks
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
