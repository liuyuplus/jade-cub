//
//  MusicNowPlayingStore.swift
//  PingIsland
//
//  Lightweight now-playing state for the island music panel.
//

import AppKit
import Combine
import Darwin
import Foundation

struct MusicNowPlayingTrack: Equatable {
    let source: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let position: TimeInterval
    let isPlaying: Bool
    let artworkURL: URL?
    let artworkData: Data?
    let capturedAt: Date

    var effectivePosition: TimeInterval {
        guard isPlaying else { return clampedPosition(position) }
        return clampedPosition(position + Date().timeIntervalSince(capturedAt))
    }

    private func clampedPosition(_ value: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return max(0, value) }
        return min(max(0, value), duration)
    }
}

@MainActor
final class MusicNowPlayingStore: ObservableObject {
    static let shared = MusicNowPlayingStore()

    @Published private(set) var track: MusicNowPlayingTrack?
    @Published private(set) var lastError: String?
    @Published private(set) var diagnostic: String = "Music reader idle"

    private static let automaticRefreshInterval: TimeInterval = 1.25
    private static let responsiveRefreshDelays: [TimeInterval] = [0, 0.25, 0.65, 1.2, 2.0, 3.2]
    private static let playbackCommandRefreshDelays: [TimeInterval] = [0.25, 0.65, 1.05, 1.6]

    private var refreshTimer: Timer?
    private var responsiveRefreshWorkItems: [DispatchWorkItem] = []
    private var hasRequestedSystemNowPlaying = false
    private var spotifyObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        diagnostic = "Music reader started"
        beginSpotifyObservation()
        beginWorkspaceObservation()
        refresh()

        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.automaticRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        cancelResponsiveRefreshBurst()
        endSpotifyObservation()
        endWorkspaceObservation()
    }

    func refresh() {
        refresh(forceProbe: false)
    }

    func refreshResponsively() {
        scheduleResponsiveRefreshBurst(delays: Self.responsiveRefreshDelays)
    }

    private func refresh(forceProbe: Bool) {
        guard MusicSource.hasRunningSupportedPlayer else {
            track = nil
            lastError = nil
            diagnostic = "No supported music player running"
            return
        }

        diagnostic = "Refreshing system Now Playing..."
        querySystemNowPlaying(forceProbe: forceProbe)

        var latestError: String?
        for source in MusicSource.scriptableCases {
            guard source.isRunning else { continue }

            switch query(source) {
            case .success(let track):
                if let track {
                    self.track = track
                    lastError = nil
                    return
                }
            case .failure(let error):
                latestError = error.localizedDescription
            }
        }

        if track == nil || !hasRequestedSystemNowPlaying {
            track = nil
            lastError = latestError
        }
    }

    func perform(_ command: MusicPlaybackCommand) {
        diagnostic = "Sending \(command.displayName)..."
        SystemMediaCommandSender.shared.send(command)

        scheduleResponsiveRefreshBurst(
            delays: Self.playbackCommandRefreshDelays,
            stopWhenTrackAvailable: false
        )
    }

    private func scheduleResponsiveRefreshBurst(
        delays: [TimeInterval],
        stopWhenTrackAvailable: Bool = true
    ) {
        cancelResponsiveRefreshBurst()

        for delay in delays {
            let workItem = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if stopWhenTrackAvailable, self.track != nil {
                        return
                    }
                    self.refresh(forceProbe: true)
                }
            }
            responsiveRefreshWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func cancelResponsiveRefreshBurst() {
        responsiveRefreshWorkItems.forEach { $0.cancel() }
        responsiveRefreshWorkItems.removeAll()
    }

    private func query(_ source: MusicSource) -> Result<MusicNowPlayingTrack?, Error> {
        guard let script = NSAppleScript(source: source.script) else {
            return .failure(MusicNowPlayingError.invalidScript)
        }

        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo).stringValue ?? ""

        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(MusicNowPlayingError.appleScript(message ?? "Unable to read \(source.displayName)."))
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(nil) }

        let fields = trimmed.components(separatedBy: "\u{1F}")
        guard fields.count >= 7 else {
            return .failure(MusicNowPlayingError.unexpectedResponse)
        }

        let duration = TimeInterval(fields[4]) ?? 0
        let position = TimeInterval(fields[5]) ?? 0
        let state = fields[6].lowercased()
        let artworkURL = fields.indices.contains(7) ? Self.urlValue(fields[7]) : nil

        return .success(
            MusicNowPlayingTrack(
                source: fields[0],
                title: fields[1].isEmpty ? "Unknown Track" : fields[1],
                artist: fields[2].isEmpty ? "Unknown Artist" : fields[2],
                album: fields[3],
                duration: duration,
                position: position,
                isPlaying: state == "playing",
                artworkURL: artworkURL,
                artworkData: nil,
                capturedAt: Date()
            )
        )
    }

    private func querySystemNowPlaying(forceProbe: Bool) {
        hasRequestedSystemNowPlaying = true
        SystemNowPlayingReader.shared.read(forceProbe: forceProbe) { [weak self] snapshot in
            guard let self else { return }
            diagnostic = snapshot.diagnostic

            guard MusicSource.hasRunningSupportedPlayer else {
                self.track = nil
                self.lastError = nil
                self.diagnostic = "No supported music player running"
                return
            }

            guard let track = snapshot.track else {
                self.track = nil
                return
            }

            self.track = track
            self.lastError = nil
        }
    }

    private func beginSpotifyObservation() {
        guard spotifyObserver == nil else { return }
        spotifyObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.applySpotifyUserInfo(notification.userInfo)
            }
        }
    }

    private func endSpotifyObservation() {
        guard let spotifyObserver else { return }
        DistributedNotificationCenter.default().removeObserver(spotifyObserver)
        self.spotifyObserver = nil
    }

    private func beginWorkspaceObservation() {
        guard workspaceObservers.isEmpty else { return }
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]

        workspaceObservers = names.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      MusicSource.supportedBundleIdentifiers.contains(app.bundleIdentifier ?? "")
                else {
                    return
                }

                MainActor.assumeIsolated {
                    if name == NSWorkspace.didTerminateApplicationNotification,
                       !MusicSource.hasRunningSupportedPlayer {
                        self?.track = nil
                        self?.lastError = nil
                        self?.diagnostic = "No supported music player running"
                        self?.cancelResponsiveRefreshBurst()
                    } else {
                        self?.scheduleResponsiveRefreshBurst(delays: Self.responsiveRefreshDelays)
                    }
                }
            }
        }
    }

    private func endWorkspaceObservation() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    private func applySpotifyUserInfo(_ userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              let title = userInfo["Name"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let duration = Self.doubleValue(userInfo["Duration"]) / 1000
        let position = Self.doubleValue(userInfo["Playback Position"])
        let state = (userInfo["Player State"] as? String)?.lowercased()
        let artworkURL = Self.urlValue(
            userInfo["Album Artwork URL"]
                ?? userInfo["Artwork URL"]
                ?? userInfo["artwork_url"]
                ?? userInfo["Artwork"]
        )

        track = MusicNowPlayingTrack(
            source: "Spotify",
            title: title,
            artist: userInfo["Artist"] as? String ?? "Unknown Artist",
            album: userInfo["Album"] as? String ?? "",
            duration: duration,
            position: position,
            isPlaying: state == "playing",
            artworkURL: artworkURL,
            artworkData: nil,
            capturedAt: Date()
        )
        lastError = nil
    }

    private static func doubleValue(_ value: Any?) -> Double {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let double = value as? Double {
            return double
        }
        if let string = value as? String {
            return Double(string) ?? 0
        }
        return 0
    }

    private static func urlValue(_ value: Any?) -> URL? {
        if let url = value as? URL {
            return url
        }
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }
}

private enum MusicSource: CaseIterable {
    case music
    case spotify
    case netease

    static let scriptableCases: [MusicSource] = [.music, .spotify]

    static var supportedBundleIdentifiers: Set<String> {
        Set(allCases.map(\.bundleIdentifier))
    }

    static var hasRunningSupportedPlayer: Bool {
        allCases.contains { $0.isRunning }
    }

    var displayName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        case .netease: return "NeteaseMusic"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .netease: return "com.netease.163music"
        }
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier
        }
    }

    var script: String {
        switch self {
        case .music:
            return """
            set sep to ASCII character 31
            tell application "Music"
                if player state is not stopped then
                    set trackName to name of current track as text
                    set trackArtist to artist of current track as text
                    set trackAlbum to album of current track as text
                    set trackDuration to duration of current track as text
                    set trackPosition to player position as text
                    set trackState to player state as text
                    return "Music" & sep & trackName & sep & trackArtist & sep & trackAlbum & sep & trackDuration & sep & trackPosition & sep & trackState & sep & ""
                end if
            end tell
            return ""
            """
        case .spotify:
            return """
            set sep to ASCII character 31
            tell application "Spotify"
                if player state is not stopped then
                    set trackName to name of current track as text
                    set trackArtist to artist of current track as text
                    set trackAlbum to album of current track as text
                    set trackDuration to duration of current track as text
                    set trackPosition to player position as text
                    set trackState to player state as text
                    set trackArtworkURL to ""
                    try
                        set trackArtworkURL to artwork url of current track as text
                    end try
                    return "Spotify" & sep & trackName & sep & trackArtist & sep & trackAlbum & sep & trackDuration & sep & trackPosition & sep & trackState & sep & trackArtworkURL
                end if
            end tell
            return ""
            """
        case .netease:
            return """
            set sep to ASCII character 31
            tell application id "com.netease.163music"
                if player state is not stopped then
                    set trackName to name of current track as text
                    set trackArtist to artist of current track as text
                    set trackAlbum to album of current track as text
                    set trackDuration to duration of current track as text
                    set trackPosition to player position as text
                    set trackState to player state as text
                    return "NeteaseMusic" & sep & trackName & sep & trackArtist & sep & trackAlbum & sep & trackDuration & sep & trackPosition & sep & trackState & sep & ""
                end if
            end tell
            return ""
            """
        }
    }
}

enum MusicPlaybackCommand {
    case previousTrack
    case togglePlayPause
    case nextTrack

    var displayName: String {
        switch self {
        case .previousTrack: return "previous track"
        case .togglePlayPause: return "play/pause"
        case .nextTrack: return "next track"
        }
    }

    fileprivate var mediaRemoteValue: Int32 {
        switch self {
        case .previousTrack: return 5
        case .togglePlayPause: return 2
        case .nextTrack: return 4
        }
    }
}

private final class SystemMediaCommandSender {
    static let shared = SystemMediaCommandSender()

    private typealias SendCommandFunction = @convention(c) (
        Int32,
        CFDictionary?
    ) -> Void

    private let sendCommand: SendCommandFunction?

    private init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_LAZY
        )
        guard let symbol = handle.flatMap({ dlsym($0, "MRMediaRemoteSendCommand") }) else {
            sendCommand = nil
            return
        }
        sendCommand = unsafeBitCast(symbol, to: SendCommandFunction.self)
    }

    func send(_ command: MusicPlaybackCommand) {
        sendCommand?(command.mediaRemoteValue, nil)
    }
}

private final class SystemNowPlayingReader {
    static let shared = SystemNowPlayingReader()

    struct Snapshot {
        let track: MusicNowPlayingTrack?
        let diagnostic: String
    }

    private typealias GetNowPlayingInfoFunction = @convention(c) (
        DispatchQueue,
        @escaping ([AnyHashable: Any]?) -> Void
    ) -> Void

    private let queue = DispatchQueue.global(qos: .userInitiated)
    private let getNowPlayingInfo: GetNowPlayingInfoFunction?
    private let fallbackCacheLock = NSLock()
    private var fallbackCache: (capturedAt: Date, snapshot: Snapshot)?
    private var swiftProbeCache: (capturedAt: Date, snapshot: Snapshot)?
    private var lastSwiftProbeAttemptAt: Date?

    private static let fallbackCacheMaximumAge: TimeInterval = 0.65
    private static let swiftProbeFallbackCacheMaximumAge: TimeInterval = 1.25
    private static let swiftProbeMinimumInterval: TimeInterval = 1.25
    private static let forcedSwiftProbeMinimumInterval: TimeInterval = 0.35

    private init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_LAZY
        )
        guard let symbol = handle.flatMap({ dlsym($0, "MRMediaRemoteGetNowPlayingInfo") }) else {
            getNowPlayingInfo = nil
            return
        }
        getNowPlayingInfo = unsafeBitCast(symbol, to: GetNowPlayingInfoFunction.self)

    }

    @MainActor
    func read(
        forceProbe: Bool = false,
        _ completion: @escaping @MainActor (Snapshot) -> Void
    ) {
        guard let getNowPlayingInfo else {
            completion(Snapshot(track: nil, diagnostic: "MediaRemote symbol unavailable"))
            return
        }

        getNowPlayingInfo(queue) { info in
            let track = Self.track(from: info)
            let diagnostic = Self.diagnostic(from: info, track: track)
            let snapshot = track.map {
                Snapshot(track: $0, diagnostic: diagnostic)
            } ?? self.fallbackSnapshot(after: diagnostic, forceProbe: forceProbe)

            Task { @MainActor in
                completion(snapshot)
            }
        }
    }

    private func fallbackSnapshot(after directDiagnostic: String, forceProbe: Bool) -> Snapshot {
        guard Self.shouldTryBridgeFallback else {
            return Snapshot(track: nil, diagnostic: directDiagnostic)
        }

        if !forceProbe, let snapshot = cachedFallbackSnapshot(maximumAge: Self.fallbackCacheMaximumAge) {
            return snapshot
        }

        let bridgeSnapshot: Snapshot?
        if Self.bridgeExecutableURL != nil {
            let snapshot = Self.bridgeFallbackSnapshot(after: directDiagnostic)
            if snapshot.track != nil {
                storeFallbackSnapshot(snapshot)
                return snapshot
            }
            bridgeSnapshot = snapshot
        } else {
            bridgeSnapshot = nil
        }

        let cachedSwiftSnapshot = cachedSwiftProbeSnapshot(maximumAge: Self.swiftProbeFallbackCacheMaximumAge)
        if !forceProbe, let snapshot = cachedSwiftSnapshot {
            storeFallbackSnapshot(snapshot)
            return snapshot
        }

        guard Self.swiftProbeExecutableURL != nil else {
            let snapshot = bridgeSnapshot ?? Snapshot(track: nil, diagnostic: "\(directDiagnostic); fallback unavailable")
            storeFallbackSnapshot(snapshot)
            return snapshot
        }

        guard shouldAttemptSwiftProbe(forceProbe: forceProbe) else {
            if let snapshot = cachedSwiftSnapshot {
                storeFallbackSnapshot(snapshot)
                return snapshot
            }
            let snapshot = bridgeSnapshot ?? Snapshot(track: nil, diagnostic: directDiagnostic)
            storeFallbackSnapshot(snapshot)
            return snapshot
        }

        let snapshot = Self.swiftProbeFallbackSnapshot(after: bridgeSnapshot?.diagnostic ?? directDiagnostic)
        storeSwiftProbeSnapshot(snapshot)
        storeFallbackSnapshot(snapshot)
        return snapshot
    }

    private func cachedFallbackSnapshot(maximumAge: TimeInterval) -> Snapshot? {
        fallbackCacheLock.lock()
        defer { fallbackCacheLock.unlock() }

        guard let fallbackCache,
              Date().timeIntervalSince(fallbackCache.capturedAt) < maximumAge
        else {
            return nil
        }
        return fallbackCache.snapshot
    }

    private func storeFallbackSnapshot(_ snapshot: Snapshot) {
        fallbackCacheLock.lock()
        fallbackCache = (Date(), snapshot)
        fallbackCacheLock.unlock()
    }

    private func cachedSwiftProbeSnapshot(maximumAge: TimeInterval) -> Snapshot? {
        fallbackCacheLock.lock()
        defer { fallbackCacheLock.unlock() }

        guard let swiftProbeCache,
              Date().timeIntervalSince(swiftProbeCache.capturedAt) < maximumAge
        else {
            return nil
        }
        return swiftProbeCache.snapshot
    }

    private func shouldAttemptSwiftProbe(forceProbe: Bool) -> Bool {
        fallbackCacheLock.lock()
        defer { fallbackCacheLock.unlock() }

        let now = Date()
        let minimumInterval = forceProbe
            ? Self.forcedSwiftProbeMinimumInterval
            : Self.swiftProbeMinimumInterval
        if let lastSwiftProbeAttemptAt,
           now.timeIntervalSince(lastSwiftProbeAttemptAt) < minimumInterval {
            return false
        }

        lastSwiftProbeAttemptAt = now
        return true
    }

    private func storeSwiftProbeSnapshot(_ snapshot: Snapshot) {
        fallbackCacheLock.lock()
        swiftProbeCache = (Date(), snapshot)
        fallbackCacheLock.unlock()
    }

    private static func bridgeFallbackSnapshot(after directDiagnostic: String) -> Snapshot {
        guard let bridgeURL = bridgeExecutableURL else {
            return Snapshot(track: nil, diagnostic: "\(directDiagnostic); bridge unavailable")
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = bridgeURL
        process.arguments = ["--mode", "now-playing"]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return Snapshot(track: nil, diagnostic: "\(directDiagnostic); bridge failed to start")
        }

        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = message?.isEmpty == false ? message! : "exit \(process.terminationStatus)"
            return Snapshot(track: nil, diagnostic: "\(directDiagnostic); bridge \(detail)")
        }

        do {
            let response = try JSONDecoder().decode(BridgeNowPlayingResponse.self, from: output)
            guard let track = response.track?.musicTrack(source: detectedSourceName) else {
                return Snapshot(track: nil, diagnostic: "\(directDiagnostic); \(response.diagnostic)")
            }
            return Snapshot(track: track, diagnostic: response.diagnostic)
        } catch {
            return Snapshot(track: nil, diagnostic: "\(directDiagnostic); bridge decode failed")
        }
    }

    private static func swiftProbeFallbackSnapshot(after directDiagnostic: String) -> Snapshot {
        guard let swiftURL = swiftProbeExecutableURL else {
            return Snapshot(track: nil, diagnostic: "\(directDiagnostic); swift probe unavailable")
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = swiftURL
        process.arguments = ["-e", swiftNowPlayingProbeScript]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return Snapshot(track: nil, diagnostic: "\(directDiagnostic); swift probe failed to start")
        }

        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = message?.isEmpty == false ? message! : "exit \(process.terminationStatus)"
            return Snapshot(track: nil, diagnostic: "\(directDiagnostic); swift probe \(detail)")
        }

        do {
            let response = try JSONDecoder().decode(BridgeNowPlayingResponse.self, from: output)
            guard let track = response.track?.musicTrack(source: detectedSourceName) else {
                return Snapshot(track: nil, diagnostic: "\(directDiagnostic); \(response.diagnostic)")
            }
            return Snapshot(track: track, diagnostic: response.diagnostic)
        } catch {
            return Snapshot(track: nil, diagnostic: "\(directDiagnostic); swift probe decode failed")
        }
    }

    private static var shouldTryBridgeFallback: Bool {
        MusicSource.allCases.contains { $0.isRunning }
    }

    private static var swiftProbeExecutableURL: URL? {
        [
            "/usr/bin/swift",
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
        ]
        .map { URL(fileURLWithPath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static var bridgeExecutableURL: URL? {
        guard let url = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("PingIslandBridge"),
              FileManager.default.isExecutableFile(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    private static let swiftNowPlayingProbeScript = """
    import Foundation
    import Darwin

    typealias GetNowPlayingInfoFunction = @convention(c) (
        DispatchQueue,
        @escaping ([AnyHashable: Any]?) -> Void
    ) -> Void

    func value(for key: String, in info: [AnyHashable: Any]) -> Any? {
        info[key] ?? info[AnyHashable(key)]
    }

    func stringValue(for key: String, in info: [AnyHashable: Any]) -> String? {
        value(for: key, in: info) as? String
    }

    func doubleValue(for key: String, in info: [AnyHashable: Any]) -> Double {
        if let number = value(for: key, in: info) as? NSNumber {
            return number.doubleValue
        }
        if let double = value(for: key, in: info) as? Double {
            return double
        }
        return 0
    }

    func writeResponse(_ response: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\\n".utf8))
    }

    guard let handle = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        RTLD_LAZY
    ), let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
        writeResponse(["track": NSNull(), "diagnostic": "Swift probe MediaRemote unavailable"])
        exit(0)
    }

    let getNowPlayingInfo = unsafeBitCast(symbol, to: GetNowPlayingInfoFunction.self)
    let semaphore = DispatchSemaphore(value: 0)
    var response: [String: Any] = [
        "track": NSNull(),
        "diagnostic": "Swift probe MediaRemote timed out",
    ]

    getNowPlayingInfo(DispatchQueue.global(qos: .userInitiated)) { info in
        guard let info else {
            response = ["track": NSNull(), "diagnostic": "Swift probe MediaRemote returned nil"]
            semaphore.signal()
            return
        }

        guard let title = stringValue(for: "kMRMediaRemoteNowPlayingInfoTitle", in: info),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let keys = info.keys.map { String(describing: $0) }.sorted().prefix(4).joined(separator: ", ")
            response = ["track": NSNull(), "diagnostic": "Swift probe info had no title. keys: \\(keys)"]
            semaphore.signal()
            return
        }

        let artist = stringValue(for: "kMRMediaRemoteNowPlayingInfoArtist", in: info) ?? "Unknown Artist"
        let artworkData = value(for: "kMRMediaRemoteNowPlayingInfoArtworkData", in: info) as? Data
        response = [
            "diagnostic": "Swift probe read: \\(title) / \\(artist) / artwork \\(artworkData?.count ?? 0)b",
            "track": [
                "title": title,
                "artist": artist,
                "album": stringValue(for: "kMRMediaRemoteNowPlayingInfoAlbum", in: info) ?? "",
                "duration": doubleValue(for: "kMRMediaRemoteNowPlayingInfoDuration", in: info),
                "position": doubleValue(for: "kMRMediaRemoteNowPlayingInfoElapsedTime", in: info),
                "isPlaying": doubleValue(for: "kMRMediaRemoteNowPlayingInfoPlaybackRate", in: info) > 0,
                "timestampInterval": (value(for: "kMRMediaRemoteNowPlayingInfoTimestamp", in: info) as? Date)?.timeIntervalSince1970 ?? NSNull(),
                "artworkDataBase64": artworkData?.base64EncodedString() ?? NSNull(),
            ],
        ]
        semaphore.signal()
    }

    _ = semaphore.wait(timeout: .now() + .milliseconds(900))
    writeResponse(response)
    """

    private static func track(from info: [AnyHashable: Any]?) -> MusicNowPlayingTrack? {
        guard let info,
              let title = stringValue(for: "kMRMediaRemoteNowPlayingInfoTitle", in: info),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let duration = doubleValue(for: "kMRMediaRemoteNowPlayingInfoDuration", in: info)
        let elapsed = doubleValue(for: "kMRMediaRemoteNowPlayingInfoElapsedTime", in: info)
        let rate = doubleValue(for: "kMRMediaRemoteNowPlayingInfoPlaybackRate", in: info)
        let artworkData = value(for: "kMRMediaRemoteNowPlayingInfoArtworkData", in: info) as? Data
        let timestamp = value(for: "kMRMediaRemoteNowPlayingInfoTimestamp", in: info) as? Date

        return MusicNowPlayingTrack(
            source: detectedSourceName,
            title: title,
            artist: stringValue(for: "kMRMediaRemoteNowPlayingInfoArtist", in: info) ?? "Unknown Artist",
            album: stringValue(for: "kMRMediaRemoteNowPlayingInfoAlbum", in: info) ?? "",
            duration: duration,
            position: elapsed,
            isPlaying: rate > 0,
            artworkURL: nil,
            artworkData: artworkData,
            capturedAt: timestamp ?? Date()
        )
    }

    private static var detectedSourceName: String {
        if MusicSource.netease.isRunning {
            return MusicSource.netease.displayName
        }
        if MusicSource.spotify.isRunning {
            return MusicSource.spotify.displayName
        }
        if MusicSource.music.isRunning {
            return MusicSource.music.displayName
        }
        return "Now Playing"
    }

    private static func diagnostic(
        from info: [AnyHashable: Any]?,
        track: MusicNowPlayingTrack?
    ) -> String {
        guard let info else { return "System Now Playing returned nil" }
        if let track {
            let artworkBytes = track.artworkData?.count ?? 0
            return "System read: \(track.title) / \(track.artist) / artwork \(artworkBytes)b"
        }
        let keys = info.keys.map { String(describing: $0) }.sorted().prefix(4).joined(separator: ", ")
        return "System info had no title. keys: \(keys)"
    }

    private static func stringValue(for key: String, in info: [AnyHashable: Any]) -> String? {
        value(for: key, in: info) as? String
    }

    private static func doubleValue(for key: String, in info: [AnyHashable: Any]) -> Double {
        if let number = value(for: key, in: info) as? NSNumber {
            return number.doubleValue
        }
        if let double = value(for: key, in: info) as? Double {
            return double
        }
        return 0
    }

    private static func value(for key: String, in info: [AnyHashable: Any]) -> Any? {
        info[key] ?? info[AnyHashable(key)]
    }
}

private struct BridgeNowPlayingResponse: Decodable {
    let track: BridgeNowPlayingTrack?
    let diagnostic: String
}

private struct BridgeNowPlayingTrack: Decodable {
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let position: Double
    let isPlaying: Bool
    let timestampInterval: Double?
    let artworkDataBase64: String?

    func musicTrack(source: String) -> MusicNowPlayingTrack {
        MusicNowPlayingTrack(
            source: source,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: position,
            isPlaying: isPlaying,
            artworkURL: nil,
            artworkData: artworkDataBase64.flatMap { Data(base64Encoded: $0) },
            capturedAt: timestampInterval.map { Date(timeIntervalSince1970: $0) } ?? Date()
        )
    }
}

private enum MusicNowPlayingError: LocalizedError {
    case invalidScript
    case appleScript(String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidScript:
            return "Unable to prepare the music status script."
        case .appleScript(let message):
            return message
        case .unexpectedResponse:
            return "The music app returned an unexpected response."
        }
    }
}
