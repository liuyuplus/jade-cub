import Foundation
import Network
import os.log

actor CodexAppServerMonitor {
    static let shared = CodexAppServerMonitor()

    private struct ParsedSubagentMetadata {
        let parentThreadId: String?
        let depth: Int?
        let nickname: String?
        let role: String?
    }

    struct ThreadDiagnosticsSnapshot: Codable, Sendable {
        let threadId: String
        let name: String?
        let preview: String?
        let cwd: String?
        let path: String?
        let statusType: String?
        let isEphemeral: Bool
        let updatedAt: Date?
        let placeholderCandidate: Bool
        let internalContextCandidate: Bool
    }

    private enum PendingRequestKind {
        case commandApproval
        case fileApproval
        case permissionsApproval
        case userInput
    }

    private struct PendingRequest {
        let requestId: String
        let threadId: String
        let kind: PendingRequestKind
        let intervention: SessionIntervention
        let requestedPermissions: [String: Any]?
    }

    private enum TransportKind {
        case webSocket
        case stdio
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.liuyuplus.jadecub",
        category: "Codex"
    )
    private let port = 41241
    private let idleThreadListRefreshInterval: Duration = .seconds(15)
    private let activeThreadListRefreshInterval: Duration = .seconds(3)
    private let rolloutFallbackScanInterval: Duration = .seconds(3)
    private let rolloutFallbackFreshness: TimeInterval = 30 * 60

    private var process: Process?
    private var websocket: URLSessionWebSocketTask?
    private var stdioInput: FileHandle?
    private var transportKind: TransportKind?
    private var receiveTask: Task<Void, Never>?
    private var stderrDrainTask: Task<Void, Never>?
    private var threadListRefreshTask: Task<Void, Never>?
    private var rolloutFallbackScanTask: Task<Void, Never>?
    private var networkMonitor: NWPathMonitor?
    private let networkMonitorQueue = DispatchQueue(label: "io.github.liuyuplus.jadecub.codex-network")
    private var requestSequence = 0
    private var pendingResponses: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingRequestsByThread: [String: PendingRequest] = [:]
    private var resolvedClientBundleIdentifier: String?
    private var resolvedClientName: String?
    private var lastThreadDiagnostics: [ThreadDiagnosticsSnapshot] = []

    private init() {}

    func start() async {
        startNetworkMonitorIfNeeded()
        ensureRolloutFallbackScanLoop()

        if isConnected {
            ensureThreadListRefreshLoop()
            return
        }

        if await connectToServer() {
            ensureThreadListRefreshLoop()
            return
        }

        guard let executable = resolveCodexExecutable() else {
            logger.notice("Codex CLI not found; app-server monitor disabled")
            return
        }

        resolvedClientBundleIdentifier = Self.bundleIdentifier(forCodexExecutable: executable)
        resolvedClientName = Self.clientName(forCodexExecutable: executable)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]

        if await startStdioServer(process: process) {
            ensureThreadListRefreshLoop()
            return
        }

        logger.error("Unable to initialize Codex app-server monitor")
    }

    func stop() {
        rolloutFallbackScanTask?.cancel()
        rolloutFallbackScanTask = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        closeTransport(terminateProcess: true)
        pendingRequestsByThread.removeAll()
        lastThreadDiagnostics.removeAll()
    }

    private var isConnected: Bool {
        websocket != nil || stdioInput != nil
    }

    private func closeTransport(terminateProcess: Bool) {
        threadListRefreshTask?.cancel()
        threadListRefreshTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        stderrDrainTask?.cancel()
        stderrDrainTask = nil
        websocket?.cancel(with: .goingAway, reason: nil)
        websocket = nil
        stdioInput?.closeFile()
        stdioInput = nil
        transportKind = nil
        if terminateProcess {
            process?.terminationHandler = nil
            process?.terminate()
        }
        process = nil
        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: CancellationError())
        }
        pendingResponses.removeAll()
    }

    func approve(threadId: String, forSession: Bool) async {
        guard let pending = pendingRequestsByThread[threadId] else { return }
        let result: [String: Any]

        switch pending.kind {
        case .commandApproval:
            result = ["decision": forSession ? "acceptForSession" : "accept"]
        case .fileApproval:
            result = ["decision": forSession ? "acceptForSession" : "accept"]
        case .permissionsApproval:
            result = [
                "permissions": pending.requestedPermissions ?? [:],
                "scope": forSession ? "session" : "turn"
            ]
        case .userInput:
            guard pending.intervention.kind == .approval,
                  let answers = Self.defaultApprovalAnswers(
                      for: pending.intervention,
                      approving: true
                  ) else {
                return
            }
            await sendUserInputResponse(id: pending.requestId, answers: answers)
            pendingRequestsByThread.removeValue(forKey: threadId)
            await SessionStore.shared.resolveCodexIntervention(sessionId: threadId, nextPhase: .processing)
            return
        }

        await sendResponse(id: pending.requestId, result: result)
        pendingRequestsByThread.removeValue(forKey: threadId)
        await SessionStore.shared.resolveCodexIntervention(sessionId: threadId, nextPhase: .processing)
    }

    func deny(threadId: String) async {
        guard let pending = pendingRequestsByThread[threadId] else { return }
        let result: [String: Any]

        switch pending.kind {
        case .commandApproval:
            result = ["decision": "decline"]
        case .fileApproval:
            result = ["decision": "decline"]
        case .permissionsApproval:
            result = [
                "permissions": [:],
                "scope": "turn"
            ]
        case .userInput:
            guard pending.intervention.kind == .approval,
                  let answers = Self.defaultApprovalAnswers(
                      for: pending.intervention,
                      approving: false
                  ) else {
                return
            }
            await sendUserInputResponse(id: pending.requestId, answers: answers)
            pendingRequestsByThread.removeValue(forKey: threadId)
            await SessionStore.shared.resolveCodexIntervention(sessionId: threadId, nextPhase: .processing)
            return
        }

        await sendResponse(id: pending.requestId, result: result)
        pendingRequestsByThread.removeValue(forKey: threadId)
        await SessionStore.shared.resolveCodexIntervention(sessionId: threadId, nextPhase: .processing)
    }

    func answer(threadId: String, answers: [String: [String]]) async {
        guard let pending = pendingRequestsByThread[threadId], pending.kind == .userInput else { return }

        let formattedAnswers = answers.reduce(into: [String: Any]()) { partial, entry in
            partial[entry.key] = ["answers": entry.value]
        }

        await sendResponse(
            id: pending.requestId,
            result: ["answers": formattedAnswers]
        )
        pendingRequestsByThread.removeValue(forKey: threadId)
        await SessionStore.shared.resolveCodexIntervention(sessionId: threadId, nextPhase: .processing)
    }

    func readThread(threadId: String, includeTurns: Bool = true) async throws -> CodexThreadSnapshot {
        if !isConnected {
            await start()
        }

        let response = try await sendRequest(
            method: "thread/read",
            params: [
                "threadId": threadId,
                "includeTurns": includeTurns
            ]
        )

        guard let thread = response["thread"] as? [String: Any] else {
            throw NSError(domain: "CodexAppServer", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Invalid thread/read response"
            ])
        }
        if Self.shouldFilterInternalContextThreadForUI(thread),
           let threadId = thread["id"] as? String {
            logger.notice("Filtering internal Codex context thread/read thread=\(threadId, privacy: .public)")
            await SessionStore.shared.process(.sessionArchived(sessionId: threadId))
            throw NSError(domain: "CodexAppServer", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Filtered internal Codex context thread"
            ])
        }

        guard let snapshot = parseThreadSnapshot(thread) else {
            throw NSError(domain: "CodexAppServer", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Invalid thread/read response"
            ])
        }

        await SessionStore.shared.syncCodexThreadSnapshot(snapshot)
        return snapshot
    }

    func startThread(cwd: String, model: String? = nil) async throws -> CodexThreadSnapshot {
        if !isConnected {
            await start()
        }

        let response = try await sendRequest(
            method: "thread/start",
            params: [
                "model": model as Any,
                "modelProvider": NSNull(),
                "profile": NSNull(),
                "cwd": cwd,
                "approvalPolicy": NSNull(),
                "sandbox": NSNull(),
                "config": NSNull(),
                "baseInstructions": NSNull(),
                "developerInstructions": NSNull(),
                "compactPrompt": NSNull(),
                "includeApplyPatchTool": NSNull(),
                "experimentalRawEvents": false,
                "persistExtendedHistory": true,
            ]
        )

        guard let thread = response["thread"] as? [String: Any],
              let threadId = thread["id"] as? String else {
            throw NSError(domain: "CodexAppServer", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Invalid thread/start response"
            ])
        }

        return try await readThread(threadId: threadId, includeTurns: true)
    }

    func resumeThread(threadId: String, cwd: String? = nil, model: String? = nil) async throws -> CodexThreadSnapshot {
        if !isConnected {
            await start()
        }

        let response = try await sendRequest(
            method: "thread/resume",
            params: [
                "threadId": threadId,
                "model": model as Any,
                "modelProvider": NSNull(),
                "cwd": cwd as Any,
                "approvalPolicy": NSNull(),
                "sandbox": NSNull(),
                "config": NSNull(),
                "baseInstructions": NSNull(),
                "developerInstructions": NSNull(),
                "persistExtendedHistory": true,
            ]
        )

        guard let thread = response["thread"] as? [String: Any],
              let resumedThreadID = thread["id"] as? String else {
            throw NSError(domain: "CodexAppServer", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Invalid thread/resume response"
            ])
        }

        return try await readThread(threadId: resumedThreadID, includeTurns: true)
    }

    func archiveThread(threadId: String) async throws {
        if !isConnected {
            await start()
        }

        _ = try await sendRequest(
            method: "thread/archive",
            params: [
                "threadId": threadId
            ]
        )
    }

    func continueThread(threadId: String, expectedTurnId: String, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !isConnected {
            await start()
        }

        _ = try await sendRequest(
            method: "turn/steer",
            params: [
                "threadId": threadId,
                "expectedTurnId": expectedTurnId,
                "input": [
                    [
                        "type": "text",
                        "text": trimmed
                    ]
                ]
            ]
        )

        await SessionStore.shared.upsertCodexSession(
            sessionId: threadId,
            name: nil,
            preview: trimmed,
            cwd: nil,
            phase: .processing,
            intervention: nil
        )
    }

    func diagnosticsSnapshot() -> [ThreadDiagnosticsSnapshot] {
        lastThreadDiagnostics
    }

    func refreshThreadDiscovery(threadId: String) async {
        guard !threadId.isEmpty else { return }

        if !isConnected {
            await start()
        }

        do {
            _ = try await readThread(threadId: threadId, includeTurns: false)
        } catch {
            logger.debug(
                "Codex thread/read refresh failed for \(threadId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            await refreshThreadList(reason: "usage-fallback")
        }
    }

    private func connectToServer() async -> Bool {
        guard websocket == nil else { return true }
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else { return false }

        let websocket = URLSession.shared.webSocketTask(with: url)
        websocket.resume()
        self.websocket = websocket
        transportKind = .webSocket

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        do {
            try await initializeTransport()
            return true
        } catch {
            logger.debug("Codex websocket initialize failed: \(error.localizedDescription, privacy: .public)")
            receiveTask?.cancel()
            receiveTask = nil
            websocket.cancel(with: .goingAway, reason: nil)
            self.websocket = nil
            transportKind = nil
            return false
        }
    }

    private func startStdioServer(process: Process) async -> Bool {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] _ in
            Task {
                await self?.handleTransportClosed()
            }
        }

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch codex app-server: \(error.localizedDescription, privacy: .public)")
            return false
        }

        self.process = process
        stdioInput = inputPipe.fileHandleForWriting
        transportKind = .stdio
        startStdioReceiveLoop(from: outputPipe.fileHandleForReading)
        startStderrDrainLoop(from: errorPipe.fileHandleForReading)

        do {
            try await initializeTransport()
            return true
        } catch {
            logger.error("Codex stdio app-server initialize failed: \(error.localizedDescription, privacy: .public)")
            closeTransport(terminateProcess: true)
            return false
        }
    }

    private func initializeTransport() async throws {
        _ = try await sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "Island",
                    "title": "Island",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ]
        )

        await refreshThreadList(reason: "connect")
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let websocket else { return }

            do {
                let message = try await websocket.receive()
                await handle(message)
            } catch {
                logger.debug("Codex websocket closed: \(error.localizedDescription, privacy: .public)")
                break
            }
        }

        handleTransportClosed()
    }

    private func startStdioReceiveLoop(from fileHandle: FileHandle) {
        receiveTask = Task.detached(priority: .userInitiated) { [weak self] in
            var buffer = Data()

            while !Task.isCancelled {
                let chunk: Data?
                do {
                    chunk = try fileHandle.read(upToCount: 64 * 1024)
                } catch {
                    await self?.logStdioReadError(error)
                    break
                }

                guard let chunk, !chunk.isEmpty else { break }
                buffer.append(chunk)

                while let newlineIndex = buffer.firstIndex(of: 10) {
                    var lineData = Data(buffer[..<newlineIndex])
                    buffer.removeSubrange(...newlineIndex)
                    if lineData.last == 13 {
                        lineData.removeLast()
                    }
                    guard !lineData.isEmpty else { continue }
                    await self?.handleStdioLine(lineData)
                }
            }

            if !buffer.isEmpty {
                if buffer.last == 13 {
                    buffer.removeLast()
                }
                await self?.handleStdioLine(buffer)
            }

            await self?.handleTransportClosed()
        }
    }

    private func startStderrDrainLoop(from fileHandle: FileHandle) {
        stderrDrainTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let chunk: Data?
                do {
                    chunk = try fileHandle.read(upToCount: 64 * 1024)
                } catch {
                    break
                }

                guard let chunk, !chunk.isEmpty else { break }
                await self?.logStderrOutput(chunk)
            }
        }
    }

    private func handleTransportClosed() {
        let wasConnected = isConnected
        closeTransport(terminateProcess: false)
        guard wasConnected else { return }

        Task {
            let markedCount = await SessionStore.shared.markCodexFailureForActiveSessions(
                eventID: "codex-transport-closed-\(Int(Date().timeIntervalSince1970))",
                reason: "Codex app-server connection closed while Codex was active."
            )
            if markedCount > 0 {
                logger.notice("Marked active Codex sessions failed after app-server transport closed count=\(markedCount, privacy: .public)")
            }
        }
    }

    private func startNetworkMonitorIfNeeded() {
        guard networkMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .unsatisfied else { return }
            Task {
                await self?.handleNetworkUnavailable()
            }
        }
        monitor.start(queue: networkMonitorQueue)
        networkMonitor = monitor
    }

    private func handleNetworkUnavailable() async {
        let markedCount = await SessionStore.shared.markCodexFailureForActiveSessions(
            eventID: "codex-network-unavailable-\(Int(Date().timeIntervalSince1970))",
            reason: "Network became unavailable while Codex was active."
        )
        if markedCount > 0 {
            logger.notice("Marked active Codex sessions failed after network became unavailable count=\(markedCount, privacy: .public)")
        }
    }

    private func logStdioReadError(_ error: Error) {
        logger.debug("Codex stdio read failed: \(error.localizedDescription, privacy: .public)")
    }

    private func logStderrOutput(_ data: Data) {
        guard let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return
        }
        logger.debug("Codex app-server stderr: \(message.prefix(200), privacy: .public)")
    }

    private func ensureThreadListRefreshLoop() {
        guard threadListRefreshTask == nil else { return }

        threadListRefreshTask = Task { [weak self] in
            await self?.runThreadListRefreshLoop()
        }
    }

    private func runThreadListRefreshLoop() async {
        defer {
            threadListRefreshTask = nil
        }

        while !Task.isCancelled {
            let interval = await currentThreadListRefreshInterval()
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { break }
            guard isConnected else { break }
            await refreshThreadList(reason: "poll")
        }
    }

    private func currentThreadListRefreshInterval() async -> Duration {
        let hasActiveCodexSession = await SessionStore.shared.hasActiveCodexAppServerPollingSession()
        return hasActiveCodexSession ? activeThreadListRefreshInterval : idleThreadListRefreshInterval
    }

    private func refreshThreadList(reason: String) async {
        guard isConnected else { return }

        do {
            let response = try await sendRequest(
                method: "thread/list",
                params: Self.threadListRequestParams()
            )
            await ingestThreadList(response)
            logger.debug("Codex thread/list refresh succeeded reason=\(reason, privacy: .public)")
        } catch {
            logger.debug(
                "Codex thread/list refresh failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func ensureRolloutFallbackScanLoop() {
        guard rolloutFallbackScanTask == nil else { return }

        rolloutFallbackScanTask = Task { [weak self] in
            await self?.runRolloutFallbackScanLoop()
        }
    }

    private func runRolloutFallbackScanLoop() async {
        defer {
            rolloutFallbackScanTask = nil
        }

        while !Task.isCancelled {
            await refreshRecentRolloutSnapshots(reason: "fallback-scan")
            try? await Task.sleep(for: rolloutFallbackScanInterval)
        }
    }

    private func refreshRecentRolloutSnapshots(reason: String) async {
        let fileURLs = Self.recentRolloutFileURLs(
            freshness: rolloutFallbackFreshness,
            referenceDate: Date()
        )
        guard !fileURLs.isEmpty else { return }

        var syncedCount = 0
        for fileURL in fileURLs {
            guard !Task.isCancelled,
                  let threadId = Self.threadIdFromRolloutFileName(fileURL.lastPathComponent) else {
                continue
            }

            let clientInfo = SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: resolvedClientBundleIdentifier ?? "com.openai.codex",
                origin: "desktop",
                sessionFilePath: fileURL.path
            )
            guard let snapshot = await CodexRolloutParser.shared.parseThread(
                threadId: threadId,
                fallbackCwd: "/",
                clientInfo: clientInfo,
                historyMode: .summary
            ) else {
                continue
            }

            let hasExistingSession = await SessionStore.shared.containsSession(snapshot.threadId)
            guard hasExistingSession || snapshot.phase.isActive || snapshot.phase.needsAttention else {
                continue
            }

            await SessionStore.shared.syncCodexThreadSnapshot(snapshot, ingress: .codexAppServer)
            syncedCount += 1
        }

        if syncedCount > 0 {
            logger.info(
                "Codex rollout fallback synced count=\(syncedCount, privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
    }

    nonisolated static func threadIdFromRolloutFileName(_ fileName: String) -> String? {
        guard fileName.hasPrefix("rollout-"), fileName.hasSuffix(".jsonl") else {
            return nil
        }

        let baseName = String(fileName.dropLast(".jsonl".count))
        let pattern = #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
        guard let range = baseName.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        return String(baseName[range])
    }

    private nonisolated static func recentRolloutFileURLs(
        freshness: TimeInterval,
        referenceDate: Date
    ) -> [URL] {
        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions", isDirectory: true)
        let resourceKeys: [URLResourceKey] = [
            .contentModificationDateKey,
            .isRegularFileKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                  fileURL.pathExtension == "jsonl",
                  let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  referenceDate.timeIntervalSince(modifiedAt) <= freshness else {
                continue
            }
            candidates.append((fileURL, modifiedAt))
        }

        return candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(20)
            .map(\.url)
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message {
        case .data(let raw):
            data = raw
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        await handle(json: json)
    }

    private func handleStdioLine(_ data: Data) async {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        await handle(json: json)
    }

    private func handle(json: [String: Any]) async {
        if let method = json["method"] as? String {
            if let idValue = json["id"] {
                await handleServerRequest(
                    id: stringify(idValue),
                    method: method,
                    params: json["params"] as? [String: Any] ?? [:]
                )
            } else {
                await handleNotification(method: method, params: json["params"] as? [String: Any] ?? [:])
            }
            return
        }

        guard let idValue = json["id"] else { return }
        let id = stringify(idValue)

        if let continuation = pendingResponses.removeValue(forKey: id) {
            if let result = json["result"] as? [String: Any] {
                continuation.resume(returning: result)
            } else if json["result"] is NSNull {
                continuation.resume(returning: [:])
            } else if let errorObject = json["error"] as? [String: Any] {
                let message = (errorObject["message"] as? String) ?? "Unknown Codex app-server error"
                continuation.resume(throwing: NSError(domain: "CodexAppServer", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: message
                ]))
            } else {
                continuation.resume(returning: [:])
            }
        }
    }

    private func handleNotification(method: String, params: [String: Any]) async {
        logger.info("Codex notification method=\(method, privacy: .public)")
        switch method {
        case "thread/status/changed":
            let threadId = (params["threadId"] as? String) ?? ""
            guard !threadId.isEmpty else { return }
            let status = Self.statusPayload(from: params["status"], extraFieldsFrom: params)
            let statusType = (status?["type"] as? String) ?? "unknown"
            let intervention = effectiveIntervention(
                threadId: threadId,
                status: status,
                existing: pendingRequestsByThread[threadId]?.intervention
            )
            logger.info(
                "Codex status changed thread=\(threadId, privacy: .public) statusType=\(statusType, privacy: .public)"
            )
            let phase = phaseFromCodexStatus(
                status,
                threadId: threadId,
                intervention: intervention
            )
            let failureInfo = Self.failureStatusInfo(from: status)
            let failureMetadata = Self.failureMetadata(from: failureInfo)
            let hasExistingSession = await SessionStore.shared.containsSession(threadId)
            if !hasExistingSession, pendingRequestsByThread[threadId] == nil {
                if phase.isActive || phase.needsAttention || failureInfo != nil {
                    await SessionStore.shared.upsertCodexSession(
                        sessionId: threadId,
                        name: nil,
                        preview: failureInfo?.reason,
                        cwd: nil,
                        phase: phase,
                        intervention: intervention,
                        clientInfo: SessionClientInfo.codexApp(threadId: threadId),
                        metadata: failureMetadata
                    )
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(300))
                        await self?.refreshThreadDiscovery(threadId: threadId)
                    }
                    return
                }
                logger.notice(
                    "Ignoring status-only update for unknown Codex thread=\(threadId, privacy: .public) statusType=\(statusType, privacy: .public)"
                )
                return
            }
            await SessionStore.shared.upsertCodexSession(
                sessionId: threadId,
                name: nil,
                preview: nil,
                cwd: nil,
                phase: phase,
                intervention: intervention,
                metadata: failureMetadata
            )

        case "item/autoApprovalReview/started":
            guard let threadId = params["threadId"] as? String,
                  let session = await SessionStore.shared.session(for: threadId),
                  session.clientInfo.kind == .codexCLI,
                  let intervention = Self.guardianReviewIntervention(from: params) else {
                return
            }

            await SessionStore.shared.upsertCodexSession(
                sessionId: threadId,
                name: nil,
                preview: intervention.message,
                cwd: nil,
                phase: .waitingForInput,
                intervention: intervention
            )

        case "item/autoApprovalReview/completed":
            guard let threadId = params["threadId"] as? String else { return }
            await SessionStore.shared.resolveCodexIntervention(sessionId: threadId, nextPhase: .processing)
            _ = try? await readThread(threadId: threadId, includeTurns: true)

        case "thread/started":
            if let thread = params["thread"] as? [String: Any] {
                let startedThreadId = (thread["id"] as? String) ?? "unknown"
                let namePresent = (thread["name"] as? String)?.isEmpty == false
                let previewPresent = (thread["preview"] as? String)?.isEmpty == false
                let pathPresent = (thread["path"] as? String)?.isEmpty == false
                logger.info(
                    "Codex thread started thread=\(startedThreadId, privacy: .public) namePresent=\(namePresent, privacy: .public) previewPresent=\(previewPresent, privacy: .public) pathPresent=\(pathPresent, privacy: .public)"
                )
                await ingestThread(thread)
            }

        case "thread/name/updated":
            guard let threadId = params["threadId"] as? String else { return }
            await SessionStore.shared.updateCodexThreadName(
                sessionId: threadId,
                name: params["threadName"] as? String
            )

        case "thread/archived":
            guard let threadId = params["threadId"] as? String else { return }
            logger.info("Codex thread archived thread=\(threadId, privacy: .public)")
            removeThreadDiagnostics(threadId: threadId)
            await SessionStore.shared.process(.sessionEnded(sessionId: threadId))

        default:
            break
        }
    }

    private func handleServerRequest(id: String, method: String, params: [String: Any]) async {
        switch method {
        case "item/commandExecution/requestApproval":
            let threadId = (params["threadId"] as? String) ?? (params["conversationId"] as? String) ?? ""
            guard !threadId.isEmpty else { return }

            let command = ((params["command"] as? [String]) ?? []).joined(separator: " ")
            let cwd = params["cwd"] as? String
            let reason = params["reason"] as? String
            let intervention = SessionIntervention(
                id: id,
                kind: .approval,
                title: "Approve Command",
                message: reason ?? (command.isEmpty ? "Codex wants to run a terminal command." : command),
                options: [],
                questions: [],
                supportsSessionScope: true,
                metadata: [
                    "source": "codex_app_server_request_approval",
                    "command": command,
                    "cwd": cwd ?? ""
                ]
            )

            pendingRequestsByThread[threadId] = PendingRequest(
                requestId: id,
                threadId: threadId,
                kind: .commandApproval,
                intervention: intervention,
                requestedPermissions: nil
            )

            await SessionStore.shared.upsertCodexSession(
                sessionId: threadId,
                name: nil,
                preview: command.isEmpty ? reason : command,
                cwd: cwd,
                phase: .waitingForApproval(PermissionContext(
                    toolUseId: params["callId"] as? String ?? id,
                    toolName: "exec_command",
                    toolInput: nil,
                    receivedAt: Date()
                )),
                intervention: intervention
            )

        case "item/fileChange/requestApproval":
            guard let threadId = params["threadId"] as? String else { return }
            let reason = params["reason"] as? String
            let grantRoot = params["grantRoot"] as? String
            let intervention = SessionIntervention(
                id: id,
                kind: .approval,
                title: "Approve File Changes",
                message: reason ?? grantRoot ?? "Codex wants to modify files in this workspace.",
                options: [],
                questions: [],
                supportsSessionScope: true,
                metadata: [
                    "source": "codex_app_server_request_approval",
                    "grantRoot": grantRoot ?? ""
                ]
            )

            pendingRequestsByThread[threadId] = PendingRequest(
                requestId: id,
                threadId: threadId,
                kind: .fileApproval,
                intervention: intervention,
                requestedPermissions: nil
            )

            await SessionStore.shared.upsertCodexSession(
                sessionId: threadId,
                name: nil,
                preview: reason ?? grantRoot,
                cwd: nil,
                phase: .waitingForApproval(PermissionContext(
                    toolUseId: params["itemId"] as? String ?? id,
                    toolName: "file_change",
                    toolInput: nil,
                    receivedAt: Date()
                )),
                intervention: intervention
            )

        case "item/permissions/requestApproval":
            guard let threadId = params["threadId"] as? String else { return }
            let permissions = params["permissions"] as? [String: Any] ?? [:]
            let reason = params["reason"] as? String
            let message = reason ?? permissionSummary(permissions)
            let intervention = SessionIntervention(
                id: id,
                kind: .approval,
                title: "Approve Permissions",
                message: message,
                options: [],
                questions: [],
                supportsSessionScope: true,
                metadata: [
                    "source": "codex_app_server_request_approval"
                ]
            )

            pendingRequestsByThread[threadId] = PendingRequest(
                requestId: id,
                threadId: threadId,
                kind: .permissionsApproval,
                intervention: intervention,
                requestedPermissions: permissions
            )

            await SessionStore.shared.upsertCodexSession(
                sessionId: threadId,
                name: nil,
                preview: message,
                cwd: nil,
                phase: .waitingForApproval(PermissionContext(
                    toolUseId: params["itemId"] as? String ?? id,
                    toolName: "permissions_request",
                    toolInput: nil,
                    receivedAt: Date()
                )),
                intervention: intervention
            )

        case "item/tool/requestUserInput":
            guard let threadId = params["threadId"] as? String else { return }
            let questions = parseQuestions(params["questions"] as? [[String: Any]] ?? [])
            let prompt = questions.first?.prompt ?? "Codex needs your input."
            let isApprovalPrompt = Self.isApprovalLikeUserInput(questions: questions, prompt: prompt)
            var metadata = [
                "turnId": params["turnId"] as? String ?? "",
                "itemId": params["itemId"] as? String ?? ""
            ]
            if isApprovalPrompt {
                metadata["source"] = "codex_app_server_user_input_approval"
                metadata["semanticRole"] = "approval"
            }
            let intervention = SessionIntervention(
                id: id,
                kind: isApprovalPrompt ? .approval : .question,
                title: isApprovalPrompt ? "Codex Requests Approval" : "Codex Needs Input",
                message: prompt,
                options: questions.first?.options ?? [],
                questions: questions,
                supportsSessionScope: false,
                metadata: metadata
            )

            pendingRequestsByThread[threadId] = PendingRequest(
                requestId: id,
                threadId: threadId,
                kind: .userInput,
                intervention: intervention,
                requestedPermissions: nil
            )

            await SessionStore.shared.upsertCodexSession(
                sessionId: threadId,
                name: nil,
                preview: prompt,
                cwd: nil,
                phase: isApprovalPrompt
                    ? .waitingForApproval(PermissionContext(
                        toolUseId: params["itemId"] as? String ?? id,
                        toolName: "approval",
                        toolInput: nil,
                        receivedAt: Date()
                    ))
                    : .waitingForInput,
                intervention: intervention
            )

        default:
            break
        }
    }

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard isConnected else {
            throw NSError(domain: "CodexAppServer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Codex app-server transport not connected"
            ])
        }

        requestSequence += 1
        let id = String(requestSequence)
        let payload = Self.appServerRequestPayload(
            id: id,
            method: method,
            params: params,
            includeJSONRPCVersion: transportKind == .webSocket
        )

        let message = try Self.webSocketTextMessage(from: payload)

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
            Task {
                do {
                    try await sendTransportMessage(message)
                } catch {
                    if let continuation = pendingResponses.removeValue(forKey: id) {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func sendResponse(id: String, result: [String: Any]) async {
        guard isConnected else { return }

        var payload: [String: Any] = [
            "id": id,
            "result": result
        ]
        if transportKind == .webSocket {
            payload["jsonrpc"] = "2.0"
        }
        guard let message = try? Self.webSocketTextMessage(from: payload) else {
            return
        }

        do {
            try await sendTransportMessage(message)
        } catch {
            logger.error("Failed to send Codex response: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendUserInputResponse(id: String, answers: [String: [String]]) async {
        let formattedAnswers = answers.reduce(into: [String: Any]()) { partial, entry in
            partial[entry.key] = ["answers": entry.value]
        }

        await sendResponse(
            id: id,
            result: ["answers": formattedAnswers]
        )
    }

    private func sendTransportMessage(_ message: String) async throws {
        switch transportKind {
        case .webSocket:
            guard let websocket else {
                throw NSError(domain: "CodexAppServer", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Websocket not connected"
                ])
            }
            try await websocket.send(.string(message))

        case .stdio:
            guard let stdioInput else {
                throw NSError(domain: "CodexAppServer", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Stdio transport not connected"
                ])
            }
            stdioInput.write(Data((message + "\n").utf8))

        case .none:
            throw NSError(domain: "CodexAppServer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Codex app-server transport not connected"
            ])
        }
    }

    private func ingestThreadList(_ response: [String: Any]) async {
        guard let data = response["data"] as? [[String: Any]] else { return }
        lastThreadDiagnostics = data.map(Self.makeThreadDiagnosticsSnapshot(from:))
        logger.info("Codex thread list received count=\(data.count, privacy: .public)")
        for thread in data {
            await ingestThread(thread)
        }
    }

    private static func threadListRequestParams(limit: Int = 30) -> [String: Any] {
        [
            "archived": false,
            "limit": limit,
            "sortKey": "updated_at"
        ]
    }

    private func ingestThread(_ thread: [String: Any]) async {
        guard let threadId = thread["id"] as? String else { return }
        let name = thread["name"] as? String
        let preview = thread["preview"] as? String
        let cwd = thread["cwd"] as? String
        let clientInfo = makeClientInfo(from: thread, threadId: threadId)
        let status = Self.statusPayload(from: thread["status"], extraFieldsFrom: thread)
        var intervention = effectiveIntervention(
            threadId: threadId,
            status: status,
            existing: pendingRequestsByThread[threadId]?.intervention
        )
        var phase = phaseFromCodexStatus(
            status,
            threadId: threadId,
            intervention: intervention
        )
        let failureInfo = Self.failureStatusInfo(from: status)
        let failureMetadata = Self.failureMetadata(from: failureInfo)
        if Self.textIndicatesTurnAbort(preview) {
            intervention = nil
            phase = .idle
        }
        let diagnostics = Self.makeThreadDiagnosticsSnapshot(from: thread)
        recordThreadDiagnostics(diagnostics)
        let pathPresent = (thread["path"] as? String)?.isEmpty == false

        if Self.shouldFilterInternalContextThreadForUI(thread) {
            logger.notice(
                "Filtering internal Codex context thread=\(threadId, privacy: .public) name=\((diagnostics.name ?? ""), privacy: .public) preview=\((diagnostics.preview ?? "").prefix(80), privacy: .public)"
            )
            await SessionStore.shared.process(.sessionArchived(sessionId: threadId))
            return
        }

        if let rolloutSnapshot = await preferredRolloutSnapshot(
            threadId: threadId,
            cwd: cwd,
            clientInfo: clientInfo,
            appServerPhase: phase,
            intervention: intervention,
            status: status
        ) {
            logger.info(
                "Codex rollout snapshot preferred thread=\(threadId, privacy: .public) appServerPhase=\(phase.description, privacy: .public) snapshotPhase=\(rolloutSnapshot.phase.description, privacy: .public) historyItems=\(rolloutSnapshot.historyItems.count, privacy: .public)"
            )
            await SessionStore.shared.syncCodexThreadSnapshot(rolloutSnapshot, ingress: .codexAppServer)
            return
        }

        logger.info(
            "Codex ingest thread=\(threadId, privacy: .public) phase=\(String(describing: phase), privacy: .public) namePresent=\(name?.isEmpty == false, privacy: .public) previewPresent=\(preview?.isEmpty == false, privacy: .public) cwd=\((cwd ?? ""), privacy: .public) pathPresent=\(pathPresent, privacy: .public) ephemeral=\(diagnostics.isEphemeral, privacy: .public) placeholderCandidate=\(diagnostics.placeholderCandidate, privacy: .public) internalContextCandidate=\(diagnostics.internalContextCandidate, privacy: .public)"
        )
        if diagnostics.placeholderCandidate {
            logger.notice("Codex ingest placeholder candidate thread=\(threadId, privacy: .public)")
        }

        await SessionStore.shared.upsertCodexSession(
            sessionId: threadId,
            name: name,
            preview: preview,
            cwd: cwd,
            phase: phase,
            intervention: intervention,
            clientInfo: clientInfo,
            activityAt: diagnostics.updatedAt,
            metadata: failureMetadata
        )
    }

    private func preferredRolloutSnapshot(
        threadId: String,
        cwd: String?,
        clientInfo: SessionClientInfo,
        appServerPhase: SessionPhase,
        intervention: SessionIntervention?,
        status: [String: Any]?
    ) async -> CodexThreadSnapshot? {
        guard Self.shouldPreferRolloutSnapshot(
            appServerPhase: appServerPhase,
            intervention: intervention,
            status: status,
            clientInfo: clientInfo
        ) else {
            return nil
        }

        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackCwd = trimmedCwd?.isEmpty == false ? (cwd ?? "/") : "/"
        return await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: fallbackCwd,
            clientInfo: clientInfo,
            historyMode: .summary
        )
    }

    nonisolated static func shouldPreferRolloutSnapshot(
        appServerPhase: SessionPhase,
        intervention: SessionIntervention?,
        status: [String: Any]?,
        clientInfo: SessionClientInfo
    ) -> Bool {
        guard clientInfo.sessionFilePath?.isEmpty == false else {
            return false
        }
        guard case .none = intervention else {
            return false
        }
        guard !appServerPhase.isActive, !appServerPhase.needsAttention else {
            return false
        }
        guard failureStatusInfo(from: status) == nil else {
            return false
        }

        guard let statusType = status?["type"] as? String else {
            return appServerPhase == .idle
        }

        let normalizedStatus = normalizedStatusToken(statusType)
        return normalizedStatus == "notloaded" || appServerPhase == .idle
    }

    private func recordThreadDiagnostics(_ snapshot: ThreadDiagnosticsSnapshot) {
        if let existingIndex = lastThreadDiagnostics.firstIndex(where: { $0.threadId == snapshot.threadId }) {
            lastThreadDiagnostics[existingIndex] = snapshot
        } else {
            lastThreadDiagnostics.insert(snapshot, at: 0)
        }
    }

    private func removeThreadDiagnostics(threadId: String) {
        lastThreadDiagnostics.removeAll { $0.threadId == threadId }
    }

    private static func makeThreadDiagnosticsSnapshot(from thread: [String: Any]) -> ThreadDiagnosticsSnapshot {
        func normalize(_ text: String?) -> String? {
            guard let text else { return nil }
            let collapsed = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.isEmpty ? nil : collapsed
        }

        func date(from rawValue: Any?) -> Date? {
            if let value = rawValue as? NSNumber {
                return Date(timeIntervalSince1970: value.doubleValue)
            }
            if let value = rawValue as? Double {
                return Date(timeIntervalSince1970: value)
            }
            if let value = rawValue as? Int {
                return Date(timeIntervalSince1970: TimeInterval(value))
            }
            return nil
        }

        let threadId = thread["id"] as? String ?? "unknown"
        let name = normalize(thread["name"] as? String)
        let preview = normalize(thread["preview"] as? String)
        let cwd = normalize(thread["cwd"] as? String)
        let path = normalize(thread["path"] as? String)
        let status = statusPayload(from: thread["status"], extraFieldsFrom: thread)
        let statusType = status?["type"] as? String
        let isEphemeral = thread["ephemeral"] as? Bool ?? false
        let updatedAt = date(from: thread["updatedAt"])
        let internalContextCandidate = isLikelyInternalContextThreadForUI(
            threadId: threadId,
            name: name,
            preview: preview,
            cwd: cwd,
            path: path,
            status: status
        )
        let placeholderCandidate =
            !isEphemeral
            && (name?.isEmpty != false)
            && (preview?.isEmpty != false)
            && (path?.isEmpty != false)
            && (statusType != "active" || {
                guard let updatedAt else { return false }
                return Date().timeIntervalSince(updatedAt) >= 60
            }())

        return ThreadDiagnosticsSnapshot(
            threadId: threadId,
            name: name,
            preview: preview,
            cwd: cwd,
            path: path,
            statusType: statusType,
            isEphemeral: isEphemeral,
            updatedAt: updatedAt,
            placeholderCandidate: placeholderCandidate,
            internalContextCandidate: internalContextCandidate
        )
    }

    static func shouldFilterInternalContextThreadForUI(_ thread: [String: Any]) -> Bool {
        let diagnostics = makeThreadDiagnosticsSnapshot(from: thread)
        return diagnostics.internalContextCandidate
    }

    private static func isLikelyInternalContextThreadForUI(
        threadId: String,
        name: String?,
        preview: String?,
        cwd: String?,
        path: String?,
        status: [String: Any]?
    ) -> Bool {
        if statusIndicatesWaitingOnApproval(status) || statusIndicatesWaitingOnUserInput(status) {
            return false
        }

        let textLooksInternal = containsInternalContextMarker(name)
            || containsInternalContextMarker(preview)
        guard textLooksInternal else {
            return false
        }

        let weakName = name == nil
            || isUUIDLike(name)
            || containsInternalContextMarker(name)
        let weakLocation = path == nil
            || path?.isEmpty == true
            || isInternalCodexContextPath(cwd)
            || isInternalCodexContextPath(path)
            || isUUIDLike(lastPathComponent(cwd))
        let idBackedDisplay = isUUIDLike(threadId)
            && (weakName || weakLocation)

        return weakName || weakLocation || idBackedDisplay
    }

    private static func containsInternalContextMarker(_ text: String?) -> Bool {
        guard let text else { return false }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return false }
        let markers = [
            "<environment_context",
            "# instructions (read first)",
            "# od core directives",
            "<permissions instructions>",
            "<app-context>",
            "<skills_instructions>",
            "<collaboration_mode>"
        ]
        return markers.contains { normalized.contains($0) }
    }

    private static func isInternalCodexContextPath(_ text: String?) -> Bool {
        guard let text else { return false }
        let normalized = text
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        return normalized.contains("/library/application support/")
            || normalized.contains("/.codex/")
            || normalized.contains("/private/var/folders/")
            || normalized.contains("/var/folders/")
    }

    private static func isUUIDLike(_ text: String?) -> Bool {
        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func lastPathComponent(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return URL(fileURLWithPath: text).lastPathComponent
    }

    private func parseThreadSnapshot(_ thread: [String: Any]) -> CodexThreadSnapshot? {
        guard let threadId = thread["id"] as? String else { return nil }

        let createdAt = date(fromUnixTimestamp: thread["createdAt"]) ?? Date()
        let updatedAt = date(fromUnixTimestamp: thread["updatedAt"]) ?? createdAt
        let status = Self.statusPayload(from: thread["status"], extraFieldsFrom: thread)
        let snapshotClientInfo = makeClientInfo(from: thread, threadId: threadId)
        let statusIntervention = effectiveIntervention(
            threadId: threadId,
            status: status,
            existing: pendingRequestsByThread[threadId]?.intervention
        )
        let phase = phaseFromCodexStatus(
            status,
            threadId: threadId,
            intervention: statusIntervention
        )
        let turns = thread["turns"] as? [[String: Any]] ?? []

        var historyItems: [ChatHistoryItem] = []
        var firstUserMessage: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastUserMessageDate: Date?
        var latestUserText: String?
        var latestAgentText: String?
        var latestAgentPhase: String?
        var latestFinalText: String?
        var latestFinalPhase: String?
        var latestTurnId: String?
        var inferredIntervention: SessionIntervention?
        var itemOffset: TimeInterval = 0
        let subagentMetadata = parseSubagentMetadata(from: thread)

        for (turnIndex, turn) in turns.enumerated() {
            if turnIndex == turns.count - 1 {
                latestTurnId = turn["id"] as? String
            }

            let items = turn["items"] as? [[String: Any]] ?? []
            for item in items {
                itemOffset += 1
                let timestamp = createdAt.addingTimeInterval(itemOffset)
                let itemId = item["id"] as? String ?? UUID().uuidString

                switch item["type"] as? String {
                case "userMessage":
                    let text = parseUserMessageText(item["content"] as? [[String: Any]] ?? [])
                    guard let text else { continue }

                    if firstUserMessage == nil {
                        firstUserMessage = text
                    }
                    latestUserText = text
                    lastMessage = text
                    lastMessageRole = "user"
                    lastUserMessageDate = timestamp
                    historyItems.append(ChatHistoryItem(id: itemId, type: .user(text), timestamp: timestamp))

                case "agentMessage":
                    guard let text = sanitizedText(item["text"] as? String) else { continue }
                    let messagePhase = item["phase"] as? String
                    latestAgentText = text
                    latestAgentPhase = messagePhase
                    if messagePhase != "commentary" {
                        latestFinalText = text
                        latestFinalPhase = messagePhase
                    }

                    lastMessage = text
                    lastMessageRole = "assistant"
                    let type: ChatHistoryItemType = messagePhase == "commentary" ? .thinking(text) : .assistant(text)
                    historyItems.append(ChatHistoryItem(id: itemId, type: type, timestamp: timestamp))

                case "mcpToolCall":
                    let server = sanitizedText(item["server"] as? String) ?? "unknown"
                    let tool = sanitizedText(item["tool"] as? String) ?? "tool"
                    let statusValue = item["status"] as? String
                    let toolStatus: ToolStatus
                    switch statusValue {
                    case "completed":
                        toolStatus = .success
                    case "failed":
                        toolStatus = .error
                    default:
                        toolStatus = .running
                    }
                    let input = stringifyDictionary(item["arguments"] as? [String: Any] ?? [:])
                    let result = normalizedToolResultString(item["result"])
                    let toolName = "mcp__\(server)__\(tool)"
                    historyItems.append(ChatHistoryItem(
                        id: itemId,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: toolStatus,
                            result: result,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: timestamp
                    ))
                    if toolStatus == .running, snapshotClientInfo.kind == .codexCLI {
                        inferredIntervention = SessionIntervention(
                            id: "mcp-pending-\(server)-\(tool)",
                            kind: .question,
                            title: "MCP Tool Approval Needed",
                            message: "Allow the \(server) MCP server to run tool \"\(tool)\"?",
                            options: [],
                            questions: [],
                            supportsSessionScope: false,
                            metadata: [
                                "responseMode": "external_only",
                                "source": "app_server_pending_mcp",
                                "server": server,
                                "toolName": tool
                            ]
                        )
                    }

                default:
                    continue
                }
            }
        }

        let preview = sanitizedText(thread["preview"] as? String)
        let summary = sanitizedText(thread["name"] as? String) ?? preview ?? firstUserMessage
        let conversationInfo = ConversationInfo(
            summary: summary,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: nil,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )
        let indicatesTurnAbort = Self.textIndicatesTurnAbort(latestUserText ?? conversationInfo.lastMessage ?? preview)
        let finalIntervention = indicatesTurnAbort ? nil : (inferredIntervention ?? statusIntervention)
        let finalPhase: SessionPhase = if indicatesTurnAbort {
            .idle
        } else if inferredIntervention != nil {
            .waitingForInput
        } else {
            phase
        }

        return CodexThreadSnapshot(
            threadId: threadId,
            name: sanitizedText(thread["name"] as? String),
            preview: preview,
            cwd: (thread["cwd"] as? String) ?? "/",
            parentThreadId: subagentMetadata?.parentThreadId,
            subagentDepth: subagentMetadata?.depth,
            subagentNickname: subagentMetadata?.nickname,
            subagentRole: subagentMetadata?.role,
            clientInfo: snapshotClientInfo,
            intervention: finalIntervention,
            createdAt: createdAt,
            updatedAt: updatedAt,
            phase: finalPhase,
            historyItems: historyItems,
            conversationInfo: conversationInfo,
            latestTurnId: latestTurnId,
            latestResponseText: latestFinalText ?? latestAgentText ?? preview,
            latestResponsePhase: latestFinalPhase ?? latestAgentPhase,
            latestUserText: latestUserText
        )
    }

    private func parseSubagentMetadata(from thread: [String: Any]) -> ParsedSubagentMetadata? {
        let topLevelNickname = sanitizedText(thread["agentNickname"] as? String)
            ?? sanitizedText(thread["agent_nickname"] as? String)
        let topLevelRole = sanitizedText(thread["agentRole"] as? String)
            ?? sanitizedText(thread["agent_role"] as? String)
        let topLevelParent = sanitizedText(thread["parentThreadId"] as? String)
            ?? sanitizedText(thread["parent_thread_id"] as? String)
            ?? sanitizedText(thread["forkedFromId"] as? String)
            ?? sanitizedText(thread["forked_from_id"] as? String)
        let topLevelDepth = intValue(thread["subagentDepth"]) ?? intValue(thread["depth"])

        guard let source = thread["source"] as? [String: Any] else {
            guard topLevelParent != nil || topLevelDepth != nil || topLevelNickname != nil || topLevelRole != nil else {
                return nil
            }
            return ParsedSubagentMetadata(
                parentThreadId: topLevelParent,
                depth: topLevelDepth,
                nickname: topLevelNickname,
                role: topLevelRole
            )
        }

        let subagent = source["subagent"] as? [String: Any]
        let threadSpawn = subagent?["thread_spawn"] as? [String: Any]

        let parentThreadId = sanitizedText(threadSpawn?["parent_thread_id"] as? String) ?? topLevelParent
        let depth = intValue(threadSpawn?["depth"]) ?? topLevelDepth
        let nickname = sanitizedText(threadSpawn?["agent_nickname"] as? String) ?? topLevelNickname
        let role = sanitizedText(threadSpawn?["agent_role"] as? String) ?? topLevelRole

        guard parentThreadId != nil || depth != nil || nickname != nil || role != nil else {
            return nil
        }

        return ParsedSubagentMetadata(
            parentThreadId: parentThreadId,
            depth: depth,
            nickname: nickname,
            role: role
        )
    }

    private func effectiveIntervention(
        threadId: String,
        status: [String: Any]?,
        existing: SessionIntervention?
    ) -> SessionIntervention? {
        if let existing {
            return existing
        }
        guard Self.statusIndicatesWaitingOnApproval(status) else {
            return nil
        }
        return SessionIntervention(
            id: "codex-status-approval-\(threadId)",
            kind: .approval,
            title: "Codex Requests Approval",
            message: "Codex Desktop is waiting for approval.",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [
                "source": "codex_app_server_status_waiting_approval",
                "responseMode": "external_only"
            ]
        )
    }

    private static func statusPayload(
        from rawStatus: Any?,
        extraFieldsFrom source: [String: Any]? = nil
    ) -> [String: Any]? {
        var payload: [String: Any]
        switch rawStatus {
        case let dictionary as [String: Any]:
            payload = dictionary
        case let string as String:
            payload = [
                "type": string,
                "label": string
            ]
        case let number as NSNumber:
            payload = [
                "type": number.stringValue,
                "label": number.stringValue
            ]
        default:
            payload = [:]
        }

        if let source {
            for key in [
                "label",
                "statusLabel",
                "status_label",
                "statusText",
                "status_text",
                "badge",
                "state",
                "phase"
            ] {
                guard key != "status", let value = source[key] else { continue }
                payload[key] = value
            }
        }

        return payload.isEmpty ? nil : payload
    }

    static func statusIndicatesWaitingOnApproval(_ status: [String: Any]?) -> Bool {
        guard let status else { return false }
        if normalizedStatusTokens(from: status).contains("waitingonapproval") {
            return true
        }
        let searchableText = statusSearchText(from: status)
        return searchableText.contains("等待审批")
            || searchableText.contains("等待批准")
            || searchableText.contains("需要审批")
            || searchableText.contains("需要批准")
            || searchableText.contains("等待用户审批")
            || searchableText.contains("waitingapproval")
            || searchableText.contains("waitingforapproval")
            || searchableText.contains("waitingonapproval")
            || searchableText.contains("approvalrequired")
            || searchableText.contains("needsapproval")
            || searchableText.contains("requiresapproval")
    }

    static func statusIndicatesWaitingOnUserInput(_ status: [String: Any]?) -> Bool {
        guard let status else { return false }
        if normalizedStatusTokens(from: status).contains("waitingonuserinput") {
            return true
        }
        let searchableText = statusSearchText(from: status)
        return searchableText.contains("等待输入")
            || searchableText.contains("等待回复")
            || searchableText.contains("需要输入")
            || searchableText.contains("需要回复")
            || searchableText.contains("waitingonuserinput")
            || searchableText.contains("waitingforinput")
            || searchableText.contains("needsinput")
            || searchableText.contains("requiresinput")
    }

    static func failureStatusInfo(from status: [String: Any]?) -> (eventID: String, reason: String)? {
        guard let status else { return nil }
        guard !statusIndicatesWaitingOnApproval(status),
              !statusIndicatesWaitingOnUserInput(status) else {
            return nil
        }

        let normalizedType = (status["type"] as? String).map(normalizedStatusToken(_:))
        let tokens = normalizedStatusTokens(from: status)
        let failureTokens: Set<String> = [
            "aborted",
            "connectionlost",
            "crashed",
            "disconnected",
            "error",
            "failed",
            "failure",
            "networkerror",
            "offline",
            "systemerror",
            "terminated"
        ]

        let hasFailureToken = normalizedType.map(failureTokens.contains) == true
            || !tokens.intersection(failureTokens).isEmpty
        guard hasFailureToken else { return nil }

        let reason = preferredFailureMessage(from: status)
            ?? "Codex reported a failure."
        let typeComponent = normalizedType ?? "failure"
        let reasonComponent = String(normalizedStatusToken(reason).prefix(80))
        return (
            eventID: "codex-status-\(typeComponent)-\(reasonComponent)",
            reason: reason
        )
    }

    private static func failureMetadata(
        from failureInfo: (eventID: String, reason: String)?
    ) -> [String: String] {
        guard let failureInfo else { return [:] }
        return [
            "failureEventID": failureInfo.eventID,
            "failureReason": failureInfo.reason,
            "reason": failureInfo.reason
        ]
    }

    private static func preferredFailureMessage(from status: [String: Any]) -> String? {
        for key in ["message", "error", "reason", "detail", "label", "description"] {
            if let value = normalizedFailureString(status[key]) {
                return value
            }
        }

        for key in ["state", "status", "payload"] {
            if let dictionary = status[key] as? [String: Any],
               let value = preferredFailureMessage(from: dictionary) {
                return value
            }
        }

        return nil
    }

    private static func normalizedFailureString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func textIndicatesTurnAbort(_ text: String?) -> Bool {
        guard let text else { return false }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("<turn_aborted>")
            || normalized.contains("turn_aborted")
            || normalized.contains("the user interrupt")
            || normalized.contains("user interrupted")
    }

    private static func statusFlags(from status: [String: Any]) -> Set<String> {
        var flags = Set<String>()
        for key in ["activeFlags", "flags"] {
            if let values = status[key] as? [String] {
                flags.formUnion(values)
            }
        }
        if let values = status["active_flags"] as? [String] {
            flags.formUnion(values)
        }
        return flags
    }

    private static func normalizedStatusTokens(from status: [String: Any]) -> Set<String> {
        Set(statusStringValues(from: status).map(normalizedStatusToken(_:)))
    }

    private static func statusSearchText(from status: [String: Any]) -> String {
        statusStringValues(from: status)
            .map(normalizedStatusToken(_:))
            .joined(separator: " ")
    }

    private static func statusStringValues(from value: Any?) -> [String] {
        switch value {
        case let string as String:
            return [string]
        case let number as NSNumber:
            return [number.stringValue]
        case let array as [Any]:
            return array.flatMap(statusStringValues(from:))
        case let dictionary as [String: Any]:
            return dictionary.flatMap { key, value in
                [key] + statusStringValues(from: value)
            }
        default:
            return []
        }
    }

    private static func normalizedStatusToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "/", with: "")
            .lowercased()
    }

    private func phaseFromCodexStatus(
        _ status: [String: Any]?,
        threadId: String,
        intervention: SessionIntervention?
    ) -> SessionPhase {
        if intervention?.kind == .approval {
            return .waitingForApproval(PermissionContext(
                toolUseId: intervention?.id ?? "codex-approval-\(threadId)",
                toolName: intervention?.title ?? "approval",
                toolInput: nil,
                receivedAt: Date()
            ))
        }

        if Self.statusIndicatesWaitingOnApproval(status) {
            return .waitingForApproval(PermissionContext(
                toolUseId: intervention?.id ?? "codex-approval-\(threadId)",
                toolName: intervention?.title ?? "approval",
                toolInput: nil,
                receivedAt: Date()
            ))
        }

        if Self.statusIndicatesWaitingOnUserInput(status) {
            return .waitingForInput
        }

        guard let type = status?["type"] as? String else {
            if intervention?.kind == .question {
                return .waitingForInput
            }
            return .idle
        }

        let normalizedType = Self.normalizedStatusToken(type)
        let activeStatusTypes: Set<String> = [
            "active",
            "busy",
            "generating",
            "inprogress",
            "processing",
            "running",
            "runningturn",
            "turnrunning"
        ]

        if activeStatusTypes.contains(normalizedType) {
            let flags = Self.statusFlags(from: status ?? [:])
            if flags.contains("waitingOnApproval") {
                return .waitingForApproval(PermissionContext(
                    toolUseId: intervention?.id ?? "codex-approval-\(threadId)",
                    toolName: intervention?.title ?? "approval",
                    toolInput: nil,
                    receivedAt: Date()
                ))
            }
            if flags.contains("waitingOnUserInput") {
                return .waitingForInput
            }
            return .processing
        }

        if normalizedType == "systemerror" {
            return .idle
        }

        return .idle
    }

    static func guardianReviewIntervention(from params: [String: Any]) -> SessionIntervention? {
        func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let collapsed = value
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.isEmpty ? nil : collapsed
        }

        guard let review = params["review"] as? [String: Any],
              (review["status"] as? String) == "inProgress",
              let action = params["action"] as? [String: Any],
              let actionType = action["type"] as? String else {
            return nil
        }

        let title: String
        let message: String
        var metadata: [String: String] = [
            "responseMode": "external_only",
            "source": "guardian_review",
            "guardianActionType": actionType
        ]

        switch actionType {
        case "mcpToolCall":
            let server = normalized(action["server"] as? String) ?? "unknown"
            let toolName = normalized(action["toolName"] as? String) ?? "tool"
            let toolTitle = normalized(action["toolTitle"] as? String)
            title = "MCP Tool Approval Needed"
            message = "Allow the \(server) MCP server to run tool \"\(toolTitle ?? toolName)\"?"
            metadata["server"] = server
            metadata["toolName"] = toolName
            if let toolTitle {
                metadata["toolTitle"] = toolTitle
            }

        case "command":
            let command = normalized(action["command"] as? String) ?? "command"
            title = "Command Approval Needed"
            message = "Allow command:\n\(command)"
            metadata["command"] = command

        case "execve":
            let program = normalized(action["program"] as? String) ?? "command"
            let argv = (action["argv"] as? [String] ?? []).joined(separator: " ")
            title = "Command Approval Needed"
            message = argv.isEmpty ? "Allow command:\n\(program)" : "Allow command:\n\(program) \(argv)"
            metadata["command"] = message

        case "applyPatch":
            let cwd = normalized(action["cwd"] as? String) ?? ""
            let files = (action["files"] as? [String] ?? []).joined(separator: "\n")
            title = "Patch Approval Needed"
            message = files.isEmpty
                ? "Allow file changes\(cwd.isEmpty ? "" : " in \(cwd)")?"
                : "Allow file changes to:\n\(files)"
            if !cwd.isEmpty {
                metadata["cwd"] = cwd
            }

        case "networkAccess":
            let target = normalized(action["target"] as? String) ?? "network target"
            title = "Network Approval Needed"
            message = "Allow network access to \(target)?"
            metadata["target"] = target

        default:
            return nil
        }

        return SessionIntervention(
            id: (params["targetItemId"] as? String) ?? UUID().uuidString,
            kind: .question,
            title: title,
            message: message,
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: metadata
        )
    }

    private func parseQuestions(_ rawQuestions: [[String: Any]]) -> [SessionInterventionQuestion] {
        rawQuestions.map { question in
            let options = (question["options"] as? [[String: Any]] ?? []).enumerated().map { index, option in
                SessionInterventionOption(
                    id: option["label"] as? String ?? "option-\(index)",
                    title: option["label"] as? String ?? "Option \(index + 1)",
                    detail: option["description"] as? String
                )
            }

            return SessionInterventionQuestion(
                id: question["id"] as? String ?? UUID().uuidString,
                header: question["header"] as? String ?? "Question",
                prompt: question["question"] as? String ?? "",
                detail: nil,
                options: options,
                allowsMultiple: question["isMultiple"] as? Bool
                    ?? question["allowsMultiple"] as? Bool
                    ?? question["multiSelect"] as? Bool
                    ?? question["multiple"] as? Bool
                    ?? false,
                allowsOther: question["isOther"] as? Bool ?? false,
                isSecret: question["isSecret"] as? Bool ?? false
            )
        }
    }

    private static func isApprovalLikeUserInput(
        questions: [SessionInterventionQuestion],
        prompt: String
    ) -> Bool {
        let combinedText = ([prompt] + questions.flatMap { question -> [String] in
            [
                question.header,
                question.prompt,
                question.detail
            ].compactMap(\.self) + question.options.flatMap { option in
                [option.title, option.detail].compactMap(\.self)
            }
        })
        .joined(separator: " ")
        .lowercased()

        let hasApprovalDecisionOption = questions.contains { question in
            hasPositiveApprovalOption(question.options)
                && hasNegativeApprovalOption(question.options)
        }

        guard hasApprovalDecisionOption else {
            return false
        }

        let approvalCues = [
            "是否允许",
            "是否准许",
            "是否批准",
            "是否审批",
            "要关闭",
            "要删除",
            "要覆盖",
            "要替换",
            "要运行",
            "要执行",
            "允许",
            "批准",
            "approval",
            "approve",
            "permission",
            "allow",
            "run command",
            "execute command",
            "kill ",
            "rm ",
            "delete",
            "overwrite",
            "replace"
        ]

        return approvalCues.contains { combinedText.contains($0) }
    }

    private static func defaultApprovalAnswers(
        for intervention: SessionIntervention,
        approving: Bool
    ) -> [String: [String]]? {
        let questions = intervention.resolvedQuestions
        guard !questions.isEmpty else { return nil }

        var answers: [String: [String]] = [:]
        for question in questions {
            guard let option = approving
                ? positiveApprovalOption(in: question.options)
                : negativeApprovalOption(in: question.options) else {
                return nil
            }
            answers[question.id] = [option.title]
        }
        return answers
    }

    private static func hasPositiveApprovalOption(_ options: [SessionInterventionOption]) -> Bool {
        positiveApprovalOption(in: options) != nil
    }

    private static func hasNegativeApprovalOption(_ options: [SessionInterventionOption]) -> Bool {
        negativeApprovalOption(in: options) != nil
    }

    private static func positiveApprovalOption(in options: [SessionInterventionOption]) -> SessionInterventionOption? {
        options.first { option in
            let label = normalizedDecisionLabel(option.title)
            return label == "yes"
                || label == "allow"
                || label == "approve"
                || label == "accept"
                || label == "是"
                || label.hasPrefix("是，")
                || label.hasPrefix("是,")
                || label.hasPrefix("允许")
                || label.hasPrefix("批准")
        }
    }

    private static func negativeApprovalOption(in options: [SessionInterventionOption]) -> SessionInterventionOption? {
        options.first { option in
            let label = normalizedDecisionLabel(option.title)
            return label == "no"
                || label == "deny"
                || label == "reject"
                || label == "decline"
                || label == "否"
                || label.hasPrefix("否，")
                || label.hasPrefix("否,")
                || label.hasPrefix("拒绝")
                || label.hasPrefix("不允许")
        }
    }

    private static func normalizedDecisionLabel(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func makeClientInfo(from thread: [String: Any], threadId: String) -> SessionClientInfo {
        let origin = sanitizedText(thread["origin"] as? String)
            ?? sanitizedText(thread["clientOrigin"] as? String)
        let originator = sanitizedText(thread["originator"] as? String)
            ?? sanitizedText(thread["clientOriginator"] as? String)
        let threadSource = sanitizedText(thread["threadSource"] as? String)
            ?? sanitizedText(thread["source"] as? String)
            ?? sanitizedText(thread["sessionStartSource"] as? String)
        let sessionFilePath = sanitizedText(thread["rolloutPath"] as? String)
            ?? sanitizedText(thread["sessionFilePath"] as? String)
            ?? sanitizedText(thread["rollout_path"] as? String)
            ?? sanitizedText(thread["path"] as? String)

        let resolvedOrigin = origin ?? "desktop"

        let inferredKind: SessionClientKind
        if resolvedOrigin.localizedCaseInsensitiveContains("cli") {
            inferredKind = .codexCLI
        } else {
            inferredKind = .codexApp
        }

        let defaultInfo = inferredKind == .codexApp
            ? SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: resolvedClientName ?? "Codex App",
                bundleIdentifier: resolvedClientBundleIdentifier ?? "com.openai.codex",
                launchURL: SessionClientInfo.appLaunchURL(
                    bundleIdentifier: resolvedClientBundleIdentifier ?? "com.openai.codex",
                    sessionId: threadId
                ),
                origin: "desktop"
            )
            : SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI")

        return defaultInfo.merged(with: SessionClientInfo(
            kind: inferredKind,
            profileID: inferredKind == .codexApp ? "codex-app" : "codex-cli",
            name: originator ?? defaultInfo.name,
            bundleIdentifier: inferredKind == .codexApp ? defaultInfo.bundleIdentifier : nil,
            launchURL: inferredKind == .codexApp ? defaultInfo.launchURL : nil,
            origin: resolvedOrigin,
            originator: originator,
            threadSource: threadSource,
            sessionFilePath: sessionFilePath
        ))
    }

    private func permissionSummary(_ permissions: [String: Any]) -> String {
        var parts: [String] = []

        if let fileSystem = permissions["fileSystem"] as? [String: Any] {
            if let read = fileSystem["read"] as? [String], !read.isEmpty {
                parts.append("Read: \(read.joined(separator: ", "))")
            }
            if let write = fileSystem["write"] as? [String], !write.isEmpty {
                parts.append("Write: \(write.joined(separator: ", "))")
            }
        }

        if let network = permissions["network"] as? [String: Any],
           let enabled = network["enabled"] as? Bool {
            parts.append(enabled ? "Network access requested" : "Network access disabled")
        }

        return parts.isEmpty ? "Codex requested extra permissions." : parts.joined(separator: "\n")
    }

    private func normalizedToolResultString(_ value: Any?) -> String? {
        if let text = sanitizedText(value as? String) {
            return text
        }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private func stringifyDictionary(_ value: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, raw) in value {
            if let text = sanitizedText(raw as? String) {
                result[key] = text
            } else if JSONSerialization.isValidJSONObject(raw),
                      let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
                      let text = String(data: data, encoding: .utf8) {
                result[key] = text
            } else {
                result[key] = String(describing: raw)
            }
        }
        return result
    }

    private func parseUserMessageText(_ content: [[String: Any]]) -> String? {
        let fragments = content.compactMap { item -> String? in
            switch item["type"] as? String {
            case "text":
                return sanitizedText(item["text"] as? String)
            case "image":
                return "[Image]"
            case "localImage":
                if let path = item["path"] as? String {
                    return "[Image] \(URL(fileURLWithPath: path).lastPathComponent)"
                }
                return "[Image]"
            case "mention", "skill":
                return sanitizedText(item["name"] as? String)
            default:
                return nil
            }
        }

        guard !fragments.isEmpty else { return nil }
        return sanitizedText(fragments.joined(separator: "\n"))
    }

    private func sanitizedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return collapsed.isEmpty ? nil : collapsed
    }

    private func date(fromUnixTimestamp rawValue: Any?) -> Date? {
        if let value = rawValue as? NSNumber {
            return Date(timeIntervalSince1970: value.doubleValue)
        }
        if let value = rawValue as? Double {
            return Date(timeIntervalSince1970: value)
        }
        if let value = rawValue as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        return nil
    }

    static func webSocketTextMessage(from payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let message = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "CodexAppServer", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode websocket payload as UTF-8 text"
            ])
        }
        return message
    }

    static func appServerRequestPayload(
        id: String,
        method: String,
        params: [String: Any],
        includeJSONRPCVersion: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params
        ]
        if includeJSONRPCVersion {
            payload["jsonrpc"] = "2.0"
        }
        return payload
    }

    private func stringify(_ value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func resolveCodexExecutable() -> String? {
        let bundled = "/Applications/Codex.app/Contents/Resources/codex"
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        for searchRoot in [
            "/Applications",
            "\(NSHomeDirectory())/Applications"
        ] {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: searchRoot),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "app" {
                    enumerator.skipDescendants()
                    let candidate = fileURL
                        .appendingPathComponent("Contents", isDirectory: true)
                        .appendingPathComponent("Resources", isDirectory: true)
                        .appendingPathComponent("codex")
                    if FileManager.default.isExecutableFile(atPath: candidate.path) {
                        return candidate.path
                    }
                }
            }
        }

        return Foundation.ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .map { "\($0)/codex" }
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private static func bundleIdentifier(forCodexExecutable executable: String) -> String? {
        let executableURL = URL(fileURLWithPath: executable)
        guard executableURL.path.contains(".app/") else { return nil }
        let appPath = executableURL.path.components(separatedBy: "/Contents/").first ?? ""
        guard !appPath.isEmpty else { return nil }
        return Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
    }

    private static func clientName(forCodexExecutable executable: String) -> String? {
        let executableURL = URL(fileURLWithPath: executable)
        guard executableURL.path.contains(".app/") else { return nil }
        let appPath = executableURL.path.components(separatedBy: "/Contents/").first ?? ""
        guard !appPath.isEmpty,
              let bundle = Bundle(url: URL(fileURLWithPath: appPath)) else {
            return nil
        }

        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}
