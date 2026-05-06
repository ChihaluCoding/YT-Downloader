import Foundation

// MARK: - API Models

struct VideoInfo: Codable, Identifiable {
    let id: String
    let title: String
    let thumbnail: String
    let duration: Int
    let durationString: String
    let uploader: String
    let uploadDate: String
    let viewCount: Int
    let description: String
    let formats: [VideoFormat]
    let bestFormatId: String

    var formattedViewCount: String {
        if viewCount >= 1_000_000 {
            return String(format: "%.1fM", Double(viewCount) / 1_000_000)
        } else if viewCount >= 1_000 {
            return String(format: "%.1fK", Double(viewCount) / 1_000)
        }
        return "\(viewCount)"
    }

    var displayUploadDate: String? {
        guard uploadDate.count == 8 else { return nil }
        let year = String(uploadDate.prefix(4))
        let month = String(uploadDate.dropFirst(4).prefix(2))
        let day = String(uploadDate.suffix(2))
        return "\(year)/\(month)/\(day)"
    }
}

struct VideoFormat: Codable, Identifiable {
    var id: String { formatId }

    let formatId: String
    let ext: String
    let resolution: String
    let width: Int
    let height: Int
    let fps: Double
    let vcodec: String
    let acodec: String
    let filesize: Int64
    let filesizeStr: String?
    let tbr: Double
    let formatNote: String

    var normalizedExtension: String {
        ext.isEmpty ? "UNKNOWN" : ext.uppercased()
    }

    var hasVideo: Bool {
        vcodec != "none"
    }

    var isAudioOnly: Bool {
        vcodec == "none" && acodec != "none"
    }

    var displayName: String {
        formattedLabel(includeExtension: true)
    }

    var menuDisplayName: String {
        "\(paddedExtension)  \(formattedLabel(includeExtension: false))"
    }

    var codecInfo: String {
        var codecs: [String] = []
        if vcodec != "none" {
            codecs.append(vcodec)
        }
        if acodec != "none" {
            codecs.append(acodec)
        }
        return codecs.joined(separator: " / ")
    }

    private var paddedExtension: String {
        if normalizedExtension.count >= 5 {
            return normalizedExtension
        }
        return normalizedExtension.padding(toLength: 5, withPad: " ", startingAt: 0)
    }

    private func formattedLabel(includeExtension: Bool) -> String {
        var parts: [String] = []
        if includeExtension {
            parts.append(normalizedExtension)
        }

        if isAudioOnly {
            parts.append(formatNote.isEmpty ? "音声" : formatNote)
            if tbr > 0 {
                parts.append(String(format: "%.0fkbps", tbr))
            }
            if !codecInfo.isEmpty {
                parts.append(codecInfo)
            }
            return labelWithSize(parts: parts)
        }

        if !resolution.isEmpty {
            parts.append(resolution)
        } else if width > 0 && height > 0 {
            parts.append("\(width)x\(height)")
        }
        if fps > 0 {
            parts.append(String(format: "%.0ffps", fps))
        }
        if !formatNote.isEmpty {
            parts.append(formatNote)
        }
        if !codecInfo.isEmpty {
            parts.append(codecInfo)
        }
        if tbr > 0 {
            parts.append(String(format: "%.0fkbps", tbr))
        }

        return labelWithSize(parts: parts)
    }

    private func labelWithSize(parts: [String]) -> String {
        let label = parts.isEmpty ? "形式 \(formatId)" : parts.joined(separator: " - ")
        if let size = filesizeStr {
            return "\(label) (\(size))"
        }
        return label
    }
}

// MARK: - Download Models

struct DownloadTaskResponse: Codable, Identifiable {
    let taskId: String
    let url: String
    let status: String
    let formatId: String
    let duplicatePolicy: String
    let progress: Double
    let speed: String
    let eta: String
    let totalBytes: Int64
    let downloadedBytes: Int64
    let totalBytesStr: String
    let downloadedBytesStr: String
    let filename: String
    let filepath: String
    let thumbnail: String
    let title: String
    let errorMessage: String

    var id: String { taskId }

    enum CodingKeys: String, CodingKey {
        case taskId
        case url
        case status
        case formatId
        case duplicatePolicy
        case progress
        case speed
        case eta
        case totalBytes
        case downloadedBytes
        case totalBytesStr
        case downloadedBytesStr
        case filename
        case filepath
        case thumbnail
        case title
        case errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try container.decode(String.self, forKey: .taskId)
        url = try container.decode(String.self, forKey: .url)
        status = try container.decode(String.self, forKey: .status)
        formatId = try container.decodeIfPresent(String.self, forKey: .formatId) ?? ""
        duplicatePolicy = try container.decodeIfPresent(String.self, forKey: .duplicatePolicy) ?? "skip"
        progress = try container.decode(Double.self, forKey: .progress)
        speed = try container.decode(String.self, forKey: .speed)
        eta = try container.decode(String.self, forKey: .eta)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        downloadedBytes = try container.decode(Int64.self, forKey: .downloadedBytes)
        totalBytesStr = try container.decode(String.self, forKey: .totalBytesStr)
        downloadedBytesStr = try container.decode(String.self, forKey: .downloadedBytesStr)
        filename = try container.decode(String.self, forKey: .filename)
        filepath = try container.decode(String.self, forKey: .filepath)
        thumbnail = try container.decode(String.self, forKey: .thumbnail)
        title = try container.decode(String.self, forKey: .title)
        errorMessage = try container.decode(String.self, forKey: .errorMessage)
    }
}

struct DownloadStartResponse: Codable {
    let taskId: String
    let message: String
    let status: DownloadTaskResponse
}

struct DownloadedFile: Codable, Identifiable {
    let name: String
    let path: String
    let size: Int64
    let sizeStr: String
    let modified: Double

    var id: String { path }

    var formattedDate: String {
        let date = Date(timeIntervalSince1970: modified)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Server Models

struct ServerStatus: Codable {
    let service: String
    let version: String
    let status: String
    let downloadsDir: String
    let activeTasks: Int
}

struct ServerSettings: Codable {
    let downloadDir: String
    let defaultFormat: String
    let subtitleLanguages: [String]
    let ffmpegPath: String
}

struct HealthStatus: Codable {
    let status: String
    let ffmpeg: Bool
    let ytdlpVersion: String
}
