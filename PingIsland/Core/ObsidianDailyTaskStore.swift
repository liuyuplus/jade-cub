//
//  ObsidianDailyTaskStore.swift
//  PingIsland
//
//  Reads the user's daily Obsidian note and exposes a compact task progress.
//

import AppKit
import Combine
import Darwin
import Foundation

struct ObsidianDailyTaskSnapshot: Equatable {
    let completed: Int
    let remaining: Int
    let total: Int
    let fileURL: URL
    let capturedAt: Date

    var displayText: String {
        "\(completed)/\(total)"
    }
}

@MainActor
final class ObsidianDailyTaskStore: ObservableObject {
    static let shared = ObsidianDailyTaskStore()

    @Published private(set) var snapshot: ObsidianDailyTaskSnapshot?
    @Published private(set) var lastError: String?

    private static let defaultDailyFilenamePattern = "yyyy-MM-dd"
    private static let refreshInterval: TimeInterval = 12
    private static let fileEventRefreshDebounce: TimeInterval = 0.16

    private let fileManager = FileManager.default
    private let watcherQueue = DispatchQueue(label: "io.github.liuyuplus.JadeCub.obsidianDailyTaskWatcher")
    private var refreshTimer: Timer?
    private var pendingRefreshWorkItem: DispatchWorkItem?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var noteWatcher: DispatchSourceFileSystemObject?
    private var watchedNoteURL: URL?

    private init() {}

    func start() {
        guard AppSettings.obsidianDailyTasksEnabled else {
            stop(clearSnapshot: true)
            return
        }

        beginWatchingDailyDirectory()
        refresh()

        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stop(clearSnapshot: Bool = false) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        pendingRefreshWorkItem?.cancel()
        pendingRefreshWorkItem = nil
        endNoteWatcher()
        endDirectoryWatcher()

        if clearSnapshot {
            snapshot = nil
            lastError = nil
        }
    }

    func reloadConfiguration() {
        stop(clearSnapshot: !AppSettings.obsidianDailyTasksEnabled)
        start()
    }

    func refresh(date: Date = Date()) {
        guard AppSettings.obsidianDailyTasksEnabled else {
            stop(clearSnapshot: true)
            return
        }

        guard let dailyDirectory = configuredDailyDirectoryURL else {
            snapshot = nil
            lastError = "Obsidian daily folder is not configured."
            updateNoteWatcher(for: nil)
            return
        }

        guard let noteURL = todayNoteURL(in: dailyDirectory, date: date) else {
            snapshot = Self.emptySnapshot(
                fileURL: Self.defaultTodayNoteURL(
                    in: dailyDirectory,
                    for: date,
                    pattern: AppSettings.obsidianDailyFilenamePattern
                )
            )
            lastError = "Today's Obsidian daily note was not found."
            updateNoteWatcher(for: nil)
            return
        }

        do {
            let contents = try String(contentsOf: noteURL, encoding: .utf8)
            let progress = Self.parseTaskProgress(from: contents)
            snapshot = ObsidianDailyTaskSnapshot(
                completed: progress.completed,
                remaining: progress.remaining,
                total: progress.total,
                fileURL: noteURL,
                capturedAt: Date()
            )
            lastError = nil
            updateNoteWatcher(for: noteURL)
        } catch {
            snapshot = Self.emptySnapshot(fileURL: noteURL)
            lastError = error.localizedDescription
        }
    }

    func openTodayNote(date: Date = Date()) {
        guard let dailyDirectory = configuredDailyDirectoryURL else { return }

        let noteURL = snapshot?.fileURL ?? Self.defaultTodayNoteURL(
            in: dailyDirectory,
            for: date,
            pattern: AppSettings.obsidianDailyFilenamePattern
        )
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "path", value: noteURL.path)
        ]

        if let obsidianURL = components.url {
            NSWorkspace.shared.open(obsidianURL)
        } else {
            NSWorkspace.shared.open(noteURL)
        }
    }

    static func defaultTodayNotePath(directoryPath: String, date: Date = Date(), pattern: String) -> String? {
        let trimmedDirectoryPath = directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDirectoryPath.isEmpty else { return nil }
        let directoryURL = URL(
            fileURLWithPath: (trimmedDirectoryPath as NSString).expandingTildeInPath,
            isDirectory: true
        )
        return defaultTodayNoteURL(in: directoryURL, for: date, pattern: pattern).path
    }

    private func todayNoteURL(in directory: URL, date: Date) -> URL? {
        let stem = Self.dailyNoteStem(for: date, pattern: AppSettings.obsidianDailyFilenamePattern)
        let exactURL = directory.appendingPathComponent("\(stem).md", isDirectory: false)
        if fileManager.fileExists(atPath: exactURL.path) {
            return exactURL
        }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .filter { $0.deletingPathExtension().lastPathComponent.contains(stem) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private static func dailyNoteStem(for date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = normalizedDailyFilenamePattern(pattern)
        return formatter.string(from: date)
    }

    private static func defaultTodayNoteURL(in directory: URL, for date: Date, pattern: String) -> URL {
        directory.appendingPathComponent(
            "\(dailyNoteStem(for: date, pattern: pattern)).md",
            isDirectory: false
        )
    }

    private static func emptySnapshot(fileURL: URL) -> ObsidianDailyTaskSnapshot {
        ObsidianDailyTaskSnapshot(
            completed: 0,
            remaining: 0,
            total: 0,
            fileURL: fileURL,
            capturedAt: Date()
        )
    }

    private static func normalizedDailyFilenamePattern(_ rawPattern: String) -> String {
        var pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.lowercased().hasSuffix(".md") {
            pattern.removeLast(3)
        }
        return pattern.isEmpty ? defaultDailyFilenamePattern : pattern
    }

    private var configuredDailyDirectoryURL: URL? {
        let path = AppSettings.obsidianDailyDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private func beginWatchingDailyDirectory() {
        guard directoryWatcher == nil else { return }

        guard let directoryURL = configuredDailyDirectoryURL else { return }
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }

        let fileDescriptor = Darwin.open(directoryURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: watcherQueue
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefreshAfterFileEvent(rearmNoteWatcher: true)
            }
        }
        source.setCancelHandler {
            Darwin.close(fileDescriptor)
        }
        source.resume()
        directoryWatcher = source
    }

    private func endDirectoryWatcher() {
        directoryWatcher?.cancel()
        directoryWatcher = nil
    }

    private func updateNoteWatcher(for noteURL: URL?, force: Bool = false) {
        guard let noteURL else {
            endNoteWatcher()
            return
        }

        guard force || watchedNoteURL != noteURL || noteWatcher == nil else { return }

        endNoteWatcher()

        guard fileManager.fileExists(atPath: noteURL.path) else { return }

        let fileDescriptor = Darwin.open(noteURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: watcherQueue
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefreshAfterFileEvent(rearmNoteWatcher: true)
            }
        }
        source.setCancelHandler {
            Darwin.close(fileDescriptor)
        }
        source.resume()

        watchedNoteURL = noteURL
        noteWatcher = source
    }

    private func endNoteWatcher() {
        noteWatcher?.cancel()
        noteWatcher = nil
        watchedNoteURL = nil
    }

    private func scheduleRefreshAfterFileEvent(rearmNoteWatcher: Bool) {
        pendingRefreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.pendingRefreshWorkItem = nil
                if rearmNoteWatcher {
                    self?.updateNoteWatcher(for: self?.watchedNoteURL, force: true)
                }
                self?.refresh()
            }
        }

        pendingRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.fileEventRefreshDebounce,
            execute: workItem
        )
    }

    private static func parseTaskProgress(from markdown: String) -> (completed: Int, remaining: Int, total: Int) {
        let lines = markdown.components(separatedBy: .newlines)
        let todoSectionLines = todoSection(from: lines)
        let taskLines = todoSectionLines.isEmpty ? lines : todoSectionLines

        var completed = 0
        var total = 0

        for line in taskLines {
            guard let state = markdownTaskState(in: line) else { continue }
            total += 1
            if state == "x" {
                completed += 1
            }
        }

        return (completed, max(0, total - completed), total)
    }

    private static func todoSection(from lines: [String]) -> [String] {
        var isCollecting = false
        var collected: [String] = []
        var todoHeadingLevel: Int?

        for line in lines {
            let normalized = normalizedSectionLine(line)

            if isCollecting {
                if let level = markdownHeadingLevel(normalized),
                   let todoHeadingLevel,
                   level <= todoHeadingLevel {
                    break
                }
                if isNewCalloutSection(normalized), !isTodoSectionStart(normalized) {
                    break
                }
                collected.append(line)
                continue
            }

            if isTodoSectionStart(normalized) {
                isCollecting = true
                todoHeadingLevel = markdownHeadingLevel(normalized)
            }
        }

        return collected
    }

    private static func normalizedSectionLine(_ line: String) -> String {
        var normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasPrefix(">") {
            normalized.removeFirst()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized
    }

    private static func isTodoSectionStart(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        if lowercased == "todo" || lowercased == "todos" {
            return true
        }
        if lowercased.hasPrefix("#") {
            let title = lowercased
                .drop { $0 == "#" || $0.isWhitespace }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return title == "todo" || title == "todos"
        }
        if lowercased.hasPrefix("[!") && lowercased.contains("todo") {
            return true
        }
        if lowercased.hasPrefix("<summary") && lowercased.contains("todo") {
            return true
        }
        return false
    }

    private static func markdownHeadingLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }

        let level = trimmed.prefix { $0 == "#" }.count
        guard level > 0, level <= 6 else { return nil }
        return level
    }

    private static func isNewCalloutSection(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("[!")
    }

    private static func markdownTaskState(in line: String) -> String? {
        let normalized = normalizedSectionLine(line)
        guard let openBracket = normalized.firstIndex(of: "[") else { return nil }
        let stateIndex = normalized.index(after: openBracket)
        guard stateIndex < normalized.endIndex,
              normalized[stateIndex] == " " || normalized[stateIndex].lowercased() == "x" else {
            return nil
        }
        let closeBracket = normalized.index(after: stateIndex)
        guard closeBracket < normalized.endIndex,
              normalized[closeBracket] == "]" else {
            return nil
        }

        return normalized[stateIndex].lowercased()
    }
}
