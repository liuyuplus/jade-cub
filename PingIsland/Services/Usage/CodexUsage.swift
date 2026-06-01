import Foundation

struct CodexUsageWindow: Equatable, Codable, Sendable, Identifiable {
    let key: String
    let label: String
    let usedPercentage: Double
    let leftPercentage: Double
    let windowMinutes: Int
    let resetsAt: Date?

    var id: String { key }

    var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

struct CodexUsageSnapshot: Equatable, Codable, Sendable {
    let sourceFilePath: String
    let capturedAt: Date?
    let planType: String?
    let limitID: String?
    let windows: [CodexUsageWindow]

    nonisolated var threadID: String? {
        let stem = URL(fileURLWithPath: sourceFilePath).deletingPathExtension().lastPathComponent
        guard stem.count >= 36 else { return nil }

        let candidate = String(stem.suffix(36)).lowercased()
        return UUID(uuidString: candidate) == nil ? nil : candidate
    }

    nonisolated
    var isEmpty: Bool {
        windows.isEmpty
    }
}

enum CodexUsageLoader {
    nonisolated static let defaultRootURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    private struct Candidate {
        let fileURL: URL
        let modifiedAt: Date
    }

    private nonisolated static let reverseReadChunkSize = 64 * 1024

    nonisolated static func load(
        fromRootURL rootURL: URL = defaultRootURL,
        fileManager: FileManager = .default
    ) throws -> CodexUsageSnapshot? {
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var candidates: [Candidate] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                  fileURL.pathExtension == "jsonl",
                  let resourceValues = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  resourceValues.isRegularFile == true else {
                continue
            }

            candidates.append(
                Candidate(
                    fileURL: fileURL,
                    modifiedAt: resourceValues.contentModificationDate ?? .distantPast
                )
            )
        }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.fileURL.path.localizedStandardCompare(rhs.fileURL.path) == .orderedDescending
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }

        var latestDefaultSnapshot: CodexUsageSnapshot?
        var latestFallbackSnapshot: CodexUsageSnapshot?
        for candidate in sortedCandidates {
            guard let snapshot = loadLatestSnapshot(from: candidate.fileURL, modifiedAt: candidate.modifiedAt) else {
                continue
            }

            if isDefaultCodexLimitID(snapshot.limitID) {
                latestDefaultSnapshot = newerSnapshot(snapshot, than: latestDefaultSnapshot)
            } else {
                latestFallbackSnapshot = newerSnapshot(snapshot, than: latestFallbackSnapshot)
            }
        }

        return latestDefaultSnapshot ?? latestFallbackSnapshot
    }

    private nonisolated static func isDefaultCodexLimitID(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return true
        }
        return value == "codex"
    }

    private nonisolated static func newerSnapshot(
        _ candidate: CodexUsageSnapshot,
        than current: CodexUsageSnapshot?
    ) -> CodexUsageSnapshot {
        guard let current else {
            return candidate
        }

        let candidateDate = candidate.capturedAt ?? .distantPast
        let currentDate = current.capturedAt ?? .distantPast
        if candidateDate != currentDate {
            return candidateDate > currentDate ? candidate : current
        }

        return candidate.sourceFilePath.localizedStandardCompare(current.sourceFilePath) == .orderedDescending
            ? candidate
            : current
    }

    private nonisolated static func loadLatestSnapshot(from fileURL: URL, modifiedAt: Date) -> CodexUsageSnapshot? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer {
            try? fileHandle.close()
        }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return nil
        }

        var offset = fileSize
        var suffix = Data()
        while offset > 0 {
            let readSize = min(UInt64(reverseReadChunkSize), offset)
            offset -= readSize

            guard let chunk = try? readChunk(fileHandle, offset: offset, count: Int(readSize)) else {
                return nil
            }

            var data = chunk
            data.append(suffix)
            let scanStart = data.startIndex
            var searchEnd = data.endIndex

            while searchEnd > scanStart,
                  let newlineIndex = data[..<searchEnd].lastIndex(of: UInt8(ascii: "\n")) {
                let lineStart = data.index(after: newlineIndex)
                if lineStart < searchEnd,
                   let snapshot = snapshot(
                    from: Data(data[lineStart..<searchEnd]),
                    filePath: fileURL.path,
                    fallbackTimestamp: modifiedAt
                   ) {
                    return snapshot
                }
                searchEnd = newlineIndex
            }

            suffix = Data(data[scanStart..<searchEnd])
        }

        if !suffix.isEmpty,
           let snapshot = snapshot(
            from: suffix,
            filePath: fileURL.path,
            fallbackTimestamp: modifiedAt
           ) {
            return snapshot
        }
        return nil
    }

    private nonisolated static func readChunk(_ fileHandle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try fileHandle.seek(toOffset: offset)
        return fileHandle.readData(ofLength: count)
    }

    private nonisolated static func snapshot(from lineData: Data, filePath: String, fallbackTimestamp: Date) -> CodexUsageSnapshot? {
        guard lineData.contains(UInt8(ascii: "{")),
              let object = jsonObject(for: lineData),
              object["type"] as? String == "event_msg" else {
            return nil
        }

        let payload = object["payload"] as? [String: Any] ?? [:]
        guard payload["type"] as? String == "token_count",
              let rateLimits = payload["rate_limits"] as? [String: Any] else {
            return nil
        }

        let windows = ["primary", "secondary"].compactMap { key in
            usageWindow(for: key, in: rateLimits)
        }
        guard !windows.isEmpty else {
            return nil
        }

        return CodexUsageSnapshot(
            sourceFilePath: filePath,
            capturedAt: timestamp(from: object["timestamp"]) ?? fallbackTimestamp,
            planType: string(from: rateLimits["plan_type"]),
            limitID: string(from: rateLimits["limit_id"]),
            windows: windows
        )
    }

    private nonisolated static func snapshot(from line: String, filePath: String, fallbackTimestamp: Date) -> CodexUsageSnapshot? {
        snapshot(from: Data(line.utf8), filePath: filePath, fallbackTimestamp: fallbackTimestamp)
    }

    private nonisolated static func usageWindow(for key: String, in rateLimits: [String: Any]) -> CodexUsageWindow? {
        guard let payload = rateLimits[key] as? [String: Any],
              let usedPercentage = number(from: payload["used_percent"]),
              let windowMinutes = integer(from: payload["window_minutes"]) else {
            return nil
        }

        return CodexUsageWindow(
            key: key,
            label: windowLabel(forMinutes: windowMinutes),
            usedPercentage: usedPercentage,
            leftPercentage: max(0, 100 - usedPercentage),
            windowMinutes: windowMinutes,
            resetsAt: date(from: payload["resets_at"])
        )
    }

    private nonisolated static func windowLabel(forMinutes minutes: Int) -> String {
        let days = minutes / 1_440
        let remainingMinutesAfterDays = minutes % 1_440
        let hours = remainingMinutesAfterDays / 60
        let remainingMinutes = remainingMinutesAfterDays % 60

        if days > 0, hours == 0, remainingMinutes == 0 {
            return "\(days)d"
        }
        if days > 0, hours > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0, remainingMinutes == 0 {
            return "\(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(remainingMinutes)m"
        }
        return "\(minutes)m"
    }

    private nonisolated static func jsonObject(for line: String) -> [String: Any]? {
        guard !line.isEmpty else {
            return nil
        }

        return jsonObject(for: Data(line.utf8))
    }

    private nonisolated static func jsonObject(for data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private nonisolated static func timestamp(from value: Any?) -> Date? {
        guard let string = value as? String else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    private nonisolated static func number(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private nonisolated static func integer(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private nonisolated static func date(from value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            return Date(timeIntervalSince1970: number.doubleValue)
        case let string as String:
            guard let seconds = Double(string) else {
                return nil
            }
            return Date(timeIntervalSince1970: seconds)
        default:
            return nil
        }
    }

    private nonisolated static func string(from value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.isEmpty ? nil : string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
