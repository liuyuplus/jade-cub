import Foundation

actor CodexRolloutParser {
    static let shared = CodexRolloutParser()

    enum HistoryMode: Equatable, Sendable {
        case summary
        case fullHistory
    }

    private let activeTurnStalenessWindow: TimeInterval = 10 * 60
    private let completionFreshnessWindow: TimeInterval = 45

    private struct ParsedSubagentMetadata {
        let parentThreadId: String?
        let depth: Int?
        let nickname: String?
        let role: String?
    }

    private struct CachedSnapshot {
        let modificationDate: Date
        let historyMode: HistoryMode
        let snapshot: CodexThreadSnapshot
    }

    private struct SummaryState {
        var resolvedThreadId: String
        var resolvedCwd: String
        var createdAt: Date?
        var updatedAt: Date?
        var latestTurnId: String?
        var historyItems: [ChatHistoryItem] = []
        var toolIndexes: [String: Int] = [:]
        var firstUserMessage: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastUserMessageDate: Date?
        var latestUserText: String?
        var latestAgentText: String?
        var latestAgentPhase: String?
        var latestFinalText: String?
        var latestFinalPhase: String?
        var latestTaskStartedAt: Date?
        var latestTaskCompletedAt: Date?
        var runningTaskStartedAtByTurnID: [String: Date] = [:]
        var latestTurnAborted = false
        var phase: SessionPhase = .idle
        var intervention: SessionIntervention?
        var sessionName: String?
        var origin: String?
        var originator: String?
        var threadSource: String?
        var subagentMetadata = ParsedSubagentMetadata(
            parentThreadId: nil,
            depth: nil,
            nickname: nil,
            role: nil
        )
    }

    private var cache: [String: CachedSnapshot] = [:]

    private func hasFreshUnfinishedTask(
        startedAt: Date?,
        completedAt: Date?,
        lastEventAt: Date?,
        runningTaskStartedAts: [Date],
        now: Date
    ) -> Bool {
        if let runningStartedAt = runningTaskStartedAts.max() {
            let canUseThreadFreshness = startedAt == runningStartedAt
            let freshnessAnchor = canUseThreadFreshness
                ? ([runningStartedAt, lastEventAt].compactMap { $0 }.max() ?? runningStartedAt)
                : runningStartedAt
            if now.timeIntervalSince(freshnessAnchor) < activeTurnStalenessWindow {
                return true
            }
        }

        guard let startedAt else { return false }
        if let completedAt, completedAt >= startedAt {
            return false
        }
        let freshnessAnchor = [startedAt, lastEventAt].compactMap { $0 }.max() ?? startedAt
        return now.timeIntervalSince(freshnessAnchor) < activeTurnStalenessWindow
    }

    func parseThread(
        threadId: String,
        fallbackCwd: String,
        clientInfo: SessionClientInfo?,
        historyMode: HistoryMode = .fullHistory
    ) -> CodexThreadSnapshot? {
        guard let fileURL = resolveRolloutURL(threadId: threadId, clientInfo: clientInfo),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }

        if let cached = cache[fileURL.path],
           cached.modificationDate == modificationDate,
           cached.historyMode == historyMode {
            return cached.snapshot
        }

        let snapshot: CodexThreadSnapshot?
        if historyMode == .summary {
            snapshot = parseSummaryRolloutFile(
                fileURL,
                fallbackThreadId: threadId,
                fallbackCwd: fallbackCwd,
                clientInfo: clientInfo
            )
        } else {
            guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return nil
            }

            snapshot = parseRollout(
                raw,
                fileURL: fileURL,
                fallbackThreadId: threadId,
                fallbackCwd: fallbackCwd,
                clientInfo: clientInfo,
                historyMode: historyMode
            )
        }

        if let snapshot {
            cache[fileURL.path] = CachedSnapshot(
                modificationDate: modificationDate,
                historyMode: historyMode,
                snapshot: snapshot
            )
        }

        return snapshot
    }

    private func parseSummaryRolloutFile(
        _ fileURL: URL,
        fallbackThreadId: String,
        fallbackCwd: String,
        clientInfo: SessionClientInfo?
    ) -> CodexThreadSnapshot? {
        var state = SummaryState(
            resolvedThreadId: fallbackThreadId,
            resolvedCwd: fallbackCwd.nonEmpty ?? "/"
        )
        var index = 0
        var sawLine = false

        do {
            try forEachLine(in: fileURL) { line in
                sawLine = true
                processSummaryRolloutLine(line, index: index, state: &state)
                compactSummaryHistoryIfNeeded(&state)
                index += 1
            }
        } catch {
            return nil
        }

        guard sawLine else { return nil }
        state.historyItems = ChatHistoryRetentionPolicy.compactForResidentStorage(state.historyItems)
        state.toolIndexes = Self.toolIndexes(for: state.historyItems)

        return makeSummarySnapshot(
            state: state,
            fileURL: fileURL,
            clientInfo: clientInfo
        )
    }

    private func forEachLine(in fileURL: URL, _ body: (String) -> Void) throws {
        guard let stream = InputStream(url: fileURL) else {
            throw CocoaError(.fileReadUnknown)
        }

        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pending = Data()

        stream.open()
        defer { stream.close() }

        while true {
            let count = stream.read(&buffer, maxLength: bufferSize)
            if count < 0 {
                throw stream.streamError ?? CocoaError(.fileReadUnknown)
            }
            if count == 0 {
                break
            }

            pending.append(buffer, count: count)
            while let newlineIndex = pending.firstIndex(of: 10) {
                var lineData = Data(pending[..<newlineIndex])
                if lineData.last == 13 {
                    lineData.removeLast()
                }
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    body(line)
                }
                pending.removeSubrange(...newlineIndex)
            }
        }

        if !pending.isEmpty {
            if pending.last == 13 {
                pending.removeLast()
            }
            if let line = String(data: pending, encoding: .utf8), !line.isEmpty {
                body(line)
            }
        }
    }

    private func processSummaryRolloutLine(
        _ line: String,
        index: Int,
        state: inout SummaryState
    ) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let timestamp = parseISO8601(json["timestamp"] as? String) ?? Date()
        state.createdAt = state.createdAt ?? timestamp
        state.updatedAt = timestamp

        switch json["type"] as? String {
        case "session_meta":
            let payload = json["payload"] as? [String: Any] ?? [:]
            state.resolvedThreadId = stringValue(payload["id"]) ?? state.resolvedThreadId
            state.resolvedCwd = stringValue(payload["cwd"]) ?? state.resolvedCwd
            state.sessionName = stringValue(payload["title"]) ?? state.sessionName
            let sourceValue = payload["source"]
            let source = stringValue(sourceValue)
            state.origin = stringValue(payload["origin"]) ?? (source == "cli" ? "cli" : state.origin)
            state.originator = stringValue(payload["originator"]) ?? state.originator
            state.threadSource = source ?? state.threadSource
            if let parsedSubagentMetadata = parseSubagentMetadata(
                payload: payload,
                sourceValue: sourceValue
            ) {
                state.subagentMetadata = parsedSubagentMetadata
                state.threadSource = state.threadSource ?? "subagent"
            }

        case "turn_context":
            let payload = json["payload"] as? [String: Any] ?? [:]
            state.latestTurnId = stringValue(payload["turn_id"]) ?? state.latestTurnId
            state.resolvedCwd = stringValue(payload["cwd"]) ?? state.resolvedCwd

        case "event_msg":
            let payload = json["payload"] as? [String: Any] ?? [:]
            switch payload["type"] as? String {
            case "user_message":
                guard let text = normalizedText(payload["message"]) else { return }
                state.latestFinalText = nil
                state.latestFinalPhase = nil
                if state.firstUserMessage == nil {
                    state.firstUserMessage = text
                }
                state.latestUserText = text
                state.lastMessage = text
                state.lastMessageRole = "user"
                state.lastUserMessageDate = timestamp
                state.historyItems.append(ChatHistoryItem(
                    id: "codex-user-\(index)",
                    type: .user(text),
                    timestamp: timestamp
                ))
                if Self.isTurnAbortMessage(text) {
                    state.latestTurnAborted = true
                    state.latestTaskCompletedAt = timestamp
                    state.intervention = nil
                    Self.markRunningToolsInterrupted(in: &state.historyItems)
                    state.phase = .idle
                } else {
                    state.latestTurnAborted = false
                    state.phase = .processing
                }

            case "agent_message":
                guard let text = normalizedText(payload["message"]) else { return }
                let messagePhase = stringValue(payload["phase"]) ?? "assistant"
                state.latestAgentText = text
                state.latestAgentPhase = messagePhase
                state.lastMessage = text
                state.lastMessageRole = "assistant"

                let itemType: ChatHistoryItemType
                if messagePhase == "commentary" {
                    itemType = .thinking(text)
                    state.latestFinalText = nil
                    state.latestFinalPhase = nil
                    state.phase = .processing
                } else {
                    itemType = .assistant(text)
                    state.latestFinalText = text
                    state.latestFinalPhase = messagePhase
                }

                state.historyItems.append(ChatHistoryItem(
                    id: "codex-agent-\(index)",
                    type: itemType,
                    timestamp: timestamp
                ))

            case "task_started":
                state.latestTurnAborted = false
                state.latestTaskStartedAt = timestamp
                if let turnId = stringValue(payload["turn_id"])?.nonEmpty {
                    state.runningTaskStartedAtByTurnID[turnId] = timestamp
                    state.latestTurnId = turnId
                }
                state.latestFinalText = nil
                state.latestFinalPhase = nil
                state.phase = .processing

            case "task_complete":
                state.latestTaskCompletedAt = timestamp
                if let turnId = stringValue(payload["turn_id"])?.nonEmpty {
                    state.runningTaskStartedAtByTurnID.removeValue(forKey: turnId)
                } else {
                    state.runningTaskStartedAtByTurnID.removeAll()
                }
                if hasFreshUnfinishedTask(
                    startedAt: state.latestTaskStartedAt,
                    completedAt: state.latestTaskCompletedAt,
                    lastEventAt: state.updatedAt,
                    runningTaskStartedAts: Array(state.runningTaskStartedAtByTurnID.values),
                    now: Date()
                ) {
                    state.phase = .processing
                } else if !state.historyItems.contains(where: Self.isRunningToolItem(_:)) {
                    state.phase = state.latestFinalText == nil ? .idle : .waitingForInput
                }

            case "mcp_tool_call_end":
                applyMCPToolCallEnd(
                    payload: payload,
                    historyItems: &state.historyItems,
                    toolIndexes: state.toolIndexes,
                    intervention: &state.intervention,
                    phase: &state.phase
                )

            case "context_compacted":
                state.phase = .compacting

            case "turn_aborted", "turn_cancelled", "turn_canceled":
                state.latestTurnAborted = true
                state.latestTaskCompletedAt = timestamp
                if let turnId = stringValue(payload["turn_id"])?.nonEmpty {
                    state.runningTaskStartedAtByTurnID.removeValue(forKey: turnId)
                } else {
                    state.runningTaskStartedAtByTurnID.removeAll()
                }
                state.intervention = nil
                Self.markRunningToolsInterrupted(in: &state.historyItems)
                state.phase = .idle

            default:
                return
            }

        case "response_item":
            let payload = json["payload"] as? [String: Any] ?? [:]
            switch payload["type"] as? String {
            case "message":
                let role = (stringValue(payload["role"]) ?? "assistant").lowercased()
                guard role == "user" || role == "assistant" else { return }
                guard let text = normalizedResponseMessageText(payload) else { return }
                if role == "user" {
                    state.latestFinalText = nil
                    state.latestFinalPhase = nil
                    if state.firstUserMessage == nil {
                        state.firstUserMessage = text
                    }
                    state.latestUserText = text
                    state.lastMessage = text
                    state.lastMessageRole = "user"
                    state.lastUserMessageDate = timestamp
                    state.historyItems.append(ChatHistoryItem(
                        id: "codex-response-user-\(index)",
                        type: .user(text),
                        timestamp: timestamp
                    ))
                    if Self.isTurnAbortMessage(text) {
                        state.latestTurnAborted = true
                        state.latestTaskCompletedAt = timestamp
                        state.intervention = nil
                        Self.markRunningToolsInterrupted(in: &state.historyItems)
                        state.phase = .idle
                    } else {
                        state.latestTurnAborted = false
                        state.phase = .processing
                    }
                } else {
                    let messagePhase = stringValue(payload["phase"]) ?? "assistant"
                    state.latestAgentText = text
                    state.latestAgentPhase = messagePhase
                    state.lastMessage = text
                    state.lastMessageRole = "assistant"

                    let itemType: ChatHistoryItemType
                    if messagePhase == "commentary" {
                        itemType = .thinking(text)
                        state.latestFinalText = nil
                        state.latestFinalPhase = nil
                        state.phase = .processing
                    } else {
                        itemType = .assistant(text)
                        state.latestFinalText = text
                        state.latestFinalPhase = messagePhase
                        state.latestTaskCompletedAt = timestamp
                        state.phase = .waitingForInput
                    }

                    state.historyItems.append(ChatHistoryItem(
                        id: "codex-response-agent-\(index)",
                        type: itemType,
                        timestamp: timestamp
                    ))
                }

            case "reasoning":
                state.latestTurnAborted = false
                state.latestFinalText = nil
                state.latestFinalPhase = nil
                state.phase = .processing

            case "function_call":
                guard let callId = stringValue(payload["call_id"]),
                      let name = stringValue(payload["name"]) else { return }
                let inputObject = parseJSONStringObject(payload["arguments"])
                var input = parseJSONStringDictionary(inputObject ?? payload["arguments"])
                if let namespace = stringValue(payload["namespace"]) {
                    input["_namespace"] = namespace
                }
                let item = ChatHistoryItem(
                    id: callId,
                    type: .toolCall(ToolCallItem(
                        name: name,
                        input: input,
                        status: .running,
                        result: nil,
                        structuredResult: nil,
                        subagentTools: []
                    )),
                    timestamp: timestamp
                )
                state.toolIndexes[callId] = state.historyItems.count
                state.historyItems.append(item)
                state.latestTurnAborted = false
                state.latestFinalText = nil
                state.latestFinalPhase = nil
                if let questionIntervention = codexUserInputIntervention(
                    callId: callId,
                    toolName: name,
                    input: inputObject
                ) {
                    state.intervention = questionIntervention
                    state.phase = .waitingForInput
                } else {
                    state.phase = .processing
                }

            case "custom_tool_call":
                guard let callId = stringValue(payload["call_id"]),
                      let name = stringValue(payload["name"]) else { return }
                let input = customToolInput(from: payload["input"])
                let status = stringValue(payload["status"]) == "completed" ? ToolStatus.success : .running
                let item = ChatHistoryItem(
                    id: callId,
                    type: .toolCall(ToolCallItem(
                        name: name,
                        input: input,
                        status: status,
                        result: nil,
                        structuredResult: nil,
                        subagentTools: []
                    )),
                    timestamp: timestamp
                )
                state.toolIndexes[callId] = state.historyItems.count
                state.historyItems.append(item)
                if status == .running {
                    state.latestTurnAborted = false
                    state.latestFinalText = nil
                    state.latestFinalPhase = nil
                    state.phase = .processing
                }

            case "web_search_call":
                guard let callId = stringValue(payload["call_id"]) else { return }
                let query = stringValue(payload["query"]) ?? stringValue(payload["input"]) ?? ""
                let item = ChatHistoryItem(
                    id: callId,
                    type: .toolCall(ToolCallItem(
                        name: "web_search",
                        input: query.isEmpty ? [:] : ["query": query],
                        status: .running,
                        result: nil,
                        structuredResult: nil,
                        subagentTools: []
                    )),
                    timestamp: timestamp
                )
                state.toolIndexes[callId] = state.historyItems.count
                state.historyItems.append(item)
                state.latestTurnAborted = false
                state.latestFinalText = nil
                state.latestFinalPhase = nil
                state.phase = .processing

            case "function_call_output":
                guard let callId = stringValue(payload["call_id"]),
                      let toolIndex = state.toolIndexes[callId],
                      case .toolCall(var tool) = state.historyItems[toolIndex].type else { return }
                let output = normalizedText(payload["output"])
                tool.status = inferredToolStatus(fromOutput: output) ?? .success
                tool.result = output
                state.historyItems[toolIndex] = ChatHistoryItem(
                    id: callId,
                    type: .toolCall(tool),
                    timestamp: state.historyItems[toolIndex].timestamp
                )
                if state.intervention?.matchesResolvedToolUseId(callId) == true {
                    state.intervention = nil
                    state.phase = .processing
                }

            case "custom_tool_call_output":
                guard let callId = stringValue(payload["call_id"]),
                      let toolIndex = state.toolIndexes[callId],
                      case .toolCall(var tool) = state.historyItems[toolIndex].type else { return }
                let nested = parseJSONStringObject(payload["output"])
                let output = normalizedText(nested?["output"] ?? payload["output"])
                let exitCode = nested?["metadata"].flatMap { metadata -> Int? in
                    guard let metadata = metadata as? [String: Any] else { return nil }
                    return intValue(metadata["exit_code"])
                }
                tool.status = (exitCode == nil || exitCode == 0) ? .success : .error
                tool.result = output
                state.historyItems[toolIndex] = ChatHistoryItem(
                    id: callId,
                    type: .toolCall(tool),
                    timestamp: state.historyItems[toolIndex].timestamp
                )

            default:
                return
            }

        default:
            return
        }
    }

    private func compactSummaryHistoryIfNeeded(_ state: inout SummaryState) {
        guard state.historyItems.count > ChatHistoryRetentionPolicy.maxResidentItems * 2 else {
            return
        }
        state.historyItems = ChatHistoryRetentionPolicy.compactForResidentStorage(state.historyItems)
        state.toolIndexes = Self.toolIndexes(for: state.historyItems)
    }

    private func makeSummarySnapshot(
        state: SummaryState,
        fileURL: URL,
        clientInfo: SessionClientInfo?
    ) -> CodexThreadSnapshot {
        var state = state
        let now = Date()

        if state.intervention?.kind == .approval {
            let toolUseId = state.intervention?.metadata["toolUseId"] ?? state.intervention?.id ?? "codex-approval"
            state.phase = .waitingForApproval(PermissionContext(
                toolUseId: toolUseId,
                toolName: state.intervention?.metadata["toolName"] ?? "approval",
                toolInput: nil,
                receivedAt: state.updatedAt ?? Date()
            ))
        } else if state.intervention?.kind == .question {
            state.phase = .waitingForInput
        } else if state.latestTurnAborted {
            state.phase = .idle
        } else if state.historyItems.contains(where: Self.isRunningToolItem(_:)) {
            state.phase = .processing
        } else if hasFreshUnfinishedTask(
            startedAt: state.latestTaskStartedAt,
            completedAt: state.latestTaskCompletedAt,
            lastEventAt: state.updatedAt,
            runningTaskStartedAts: Array(state.runningTaskStartedAtByTurnID.values),
            now: now
        ) {
            state.phase = .processing
        } else if let latestTaskCompletedAt = state.latestTaskCompletedAt,
                  state.latestFinalText != nil,
                  now.timeIntervalSince(latestTaskCompletedAt) < completionFreshnessWindow {
            state.phase = .waitingForInput
        } else if state.phase == .processing, state.latestFinalText != nil {
            state.phase = .idle
        } else if state.phase == .waitingForInput {
            state.phase = .idle
        }

        let preview = state.latestFinalText ?? state.latestAgentText ?? state.latestUserText ?? state.firstUserMessage
        let conversationInfo = ConversationInfo(
            summary: state.sessionName ?? state.firstUserMessage,
            lastMessage: state.lastMessage,
            lastMessageRole: state.lastMessageRole,
            lastToolName: nil,
            firstUserMessage: state.firstUserMessage,
            lastUserMessageDate: state.lastUserMessageDate
        )

        let prefersCLIContext = clientInfo?.kind == .codexCLI
            || state.origin == "cli"
            || state.threadSource == "cli"
            || (clientInfo?.terminalBundleIdentifier?.isEmpty == false
                && clientInfo?.terminalBundleIdentifier != "com.openai.codex")
            || clientInfo?.terminalSessionIdentifier?.isEmpty == false
            || clientInfo?.iTermSessionIdentifier?.isEmpty == false

        if prefersCLIContext,
           let inferredIntervention = Self.pendingMCPApprovalIntervention(from: state.historyItems) {
            state.intervention = inferredIntervention
            state.phase = .waitingForInput
        }

        let baseClientInfo = prefersCLIContext
            ? SessionClientInfo.codexCLI()
            : SessionClientInfo.codexApp(threadId: state.resolvedThreadId)

        let resolvedClientInfo = baseClientInfo.merged(with: SessionClientInfo(
            kind: prefersCLIContext ? .codexCLI : .codexApp,
            name: state.originator ?? clientInfo?.name,
            bundleIdentifier: prefersCLIContext ? clientInfo?.bundleIdentifier : (clientInfo?.bundleIdentifier ?? "com.openai.codex"),
            launchURL: prefersCLIContext
                ? clientInfo?.launchURL
                : (clientInfo?.launchURL ?? SessionClientInfo.appLaunchURL(
                    bundleIdentifier: clientInfo?.bundleIdentifier ?? "com.openai.codex",
                    sessionId: state.resolvedThreadId,
                    workspacePath: state.resolvedCwd
                )),
            origin: state.origin ?? clientInfo?.origin ?? (prefersCLIContext ? "cli" : "desktop"),
            originator: state.originator ?? clientInfo?.originator,
            threadSource: state.threadSource ?? clientInfo?.threadSource,
            transport: clientInfo?.transport,
            remoteHost: clientInfo?.remoteHost,
            sessionFilePath: fileURL.path,
            terminalBundleIdentifier: clientInfo?.terminalBundleIdentifier,
            terminalProgram: clientInfo?.terminalProgram,
            terminalSessionIdentifier: clientInfo?.terminalSessionIdentifier,
            iTermSessionIdentifier: clientInfo?.iTermSessionIdentifier,
            tmuxSessionIdentifier: clientInfo?.tmuxSessionIdentifier,
            tmuxPaneIdentifier: clientInfo?.tmuxPaneIdentifier,
            processName: clientInfo?.processName
        ))

        return CodexThreadSnapshot(
            threadId: state.resolvedThreadId,
            name: state.sessionName,
            preview: preview,
            cwd: state.resolvedCwd,
            parentThreadId: state.subagentMetadata.parentThreadId,
            subagentDepth: state.subagentMetadata.depth,
            subagentNickname: state.subagentMetadata.nickname,
            subagentRole: state.subagentMetadata.role,
            clientInfo: resolvedClientInfo,
            intervention: state.intervention,
            createdAt: state.createdAt ?? Date(),
            updatedAt: state.updatedAt ?? state.createdAt ?? Date(),
            phase: state.phase,
            historyItems: state.historyItems,
            conversationInfo: conversationInfo,
            latestTurnId: state.latestTurnId,
            latestResponseText: state.latestFinalText ?? state.latestAgentText,
            latestResponsePhase: state.latestFinalPhase ?? state.latestAgentPhase,
            latestUserText: state.latestUserText,
            isHistoryCompact: true
        )
    }

    private func parseRollout(
        _ content: String,
        fileURL: URL,
        fallbackThreadId: String,
        fallbackCwd: String,
        clientInfo: SessionClientInfo?,
        historyMode: HistoryMode
    ) -> CodexThreadSnapshot? {
        let lines = content.split(separator: "\n")
        guard !lines.isEmpty else { return nil }

        var resolvedThreadId = fallbackThreadId
        var resolvedCwd = fallbackCwd.nonEmpty ?? "/"
        var createdAt: Date?
        var updatedAt: Date?
        var latestTurnId: String?

        var historyItems: [ChatHistoryItem] = []
        var toolIndexes: [String: Int] = [:]
        var firstUserMessage: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastUserMessageDate: Date?
        var latestUserText: String?
        var latestAgentText: String?
        var latestAgentPhase: String?
        var latestFinalText: String?
        var latestFinalPhase: String?
        var latestTaskStartedAt: Date?
        var latestTaskCompletedAt: Date?
        var runningTaskStartedAtByTurnID: [String: Date] = [:]
        var latestTurnAborted = false
        var phase: SessionPhase = .idle
        var intervention: SessionIntervention?
        var sessionName: String?
        var origin: String?
        var originator: String?
        var threadSource: String?
        var subagentMetadata = ParsedSubagentMetadata(
            parentThreadId: nil,
            depth: nil,
            nickname: nil,
            role: nil
        )

        for (index, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let timestamp = parseISO8601(json["timestamp"] as? String) ?? Date()
            createdAt = createdAt ?? timestamp
            updatedAt = timestamp

            switch json["type"] as? String {
            case "session_meta":
                let payload = json["payload"] as? [String: Any] ?? [:]
                resolvedThreadId = stringValue(payload["id"]) ?? resolvedThreadId
                resolvedCwd = stringValue(payload["cwd"]) ?? resolvedCwd
                sessionName = stringValue(payload["title"]) ?? sessionName
                let sourceValue = payload["source"]
                let source = stringValue(sourceValue)
                origin = stringValue(payload["origin"]) ?? (source == "cli" ? "cli" : origin)
                originator = stringValue(payload["originator"]) ?? originator
                threadSource = source ?? threadSource
                if let parsedSubagentMetadata = parseSubagentMetadata(
                    payload: payload,
                    sourceValue: sourceValue
                ) {
                    subagentMetadata = parsedSubagentMetadata
                    threadSource = threadSource ?? "subagent"
                }

            case "turn_context":
                let payload = json["payload"] as? [String: Any] ?? [:]
                latestTurnId = stringValue(payload["turn_id"]) ?? latestTurnId
                resolvedCwd = stringValue(payload["cwd"]) ?? resolvedCwd

            case "event_msg":
                let payload = json["payload"] as? [String: Any] ?? [:]
                switch payload["type"] as? String {
                case "user_message":
                    guard let text = normalizedText(payload["message"]) else { continue }
                    latestFinalText = nil
                    latestFinalPhase = nil
                    if firstUserMessage == nil {
                        firstUserMessage = text
                    }
                    latestUserText = text
                    lastMessage = text
                    lastMessageRole = "user"
                    lastUserMessageDate = timestamp
                    historyItems.append(ChatHistoryItem(
                        id: "codex-user-\(index)",
                        type: .user(text),
                        timestamp: timestamp
                    ))
                    if Self.isTurnAbortMessage(text) {
                        latestTurnAborted = true
                        latestTaskCompletedAt = timestamp
                        intervention = nil
                        Self.markRunningToolsInterrupted(in: &historyItems)
                        phase = .idle
                    } else {
                        latestTurnAborted = false
                        phase = .processing
                    }

                case "agent_message":
                    guard let text = normalizedText(payload["message"]) else { continue }
                    let messagePhase = stringValue(payload["phase"]) ?? "assistant"
                    latestAgentText = text
                    latestAgentPhase = messagePhase
                    lastMessage = text
                    lastMessageRole = "assistant"

                    let itemType: ChatHistoryItemType
                    if messagePhase == "commentary" {
                        itemType = .thinking(text)
                        latestFinalText = nil
                        latestFinalPhase = nil
                        phase = .processing
                    } else {
                        itemType = .assistant(text)
                        latestFinalText = text
                        latestFinalPhase = messagePhase
                    }

                    historyItems.append(ChatHistoryItem(
                        id: "codex-agent-\(index)",
                        type: itemType,
                        timestamp: timestamp
                    ))

                case "task_started":
                    latestTurnAborted = false
                    latestTaskStartedAt = timestamp
                    if let turnId = stringValue(payload["turn_id"])?.nonEmpty {
                        runningTaskStartedAtByTurnID[turnId] = timestamp
                        latestTurnId = turnId
                    }
                    latestFinalText = nil
                    latestFinalPhase = nil
                    phase = .processing

                case "task_complete":
                    latestTaskCompletedAt = timestamp
                    if let turnId = stringValue(payload["turn_id"])?.nonEmpty {
                        runningTaskStartedAtByTurnID.removeValue(forKey: turnId)
                    } else {
                        runningTaskStartedAtByTurnID.removeAll()
                    }
                    if hasFreshUnfinishedTask(
                        startedAt: latestTaskStartedAt,
                        completedAt: latestTaskCompletedAt,
                        lastEventAt: updatedAt,
                        runningTaskStartedAts: Array(runningTaskStartedAtByTurnID.values),
                        now: Date()
                    ) {
                        phase = .processing
                    } else if !historyItems.contains(where: Self.isRunningToolItem(_:)) {
                        phase = latestFinalText == nil ? .idle : .waitingForInput
                    }

                case "mcp_tool_call_end":
                    applyMCPToolCallEnd(
                        payload: payload,
                        historyItems: &historyItems,
                        toolIndexes: toolIndexes,
                        intervention: &intervention,
                        phase: &phase
                    )

                case "context_compacted":
                    phase = .compacting

                case "turn_aborted", "turn_cancelled", "turn_canceled":
                    latestTurnAborted = true
                    latestTaskCompletedAt = timestamp
                    if let turnId = stringValue(payload["turn_id"])?.nonEmpty {
                        runningTaskStartedAtByTurnID.removeValue(forKey: turnId)
                    } else {
                        runningTaskStartedAtByTurnID.removeAll()
                    }
                    intervention = nil
                    Self.markRunningToolsInterrupted(in: &historyItems)
                    phase = .idle

                default:
                    continue
                }

            case "response_item":
                let payload = json["payload"] as? [String: Any] ?? [:]
                let payloadType = payload["type"] as? String

                switch payloadType {
                case "message":
                    let role = (stringValue(payload["role"]) ?? "assistant").lowercased()
                    guard role == "user" || role == "assistant" else { continue }
                    guard let text = normalizedResponseMessageText(payload) else { continue }
                    if role == "user" {
                        latestFinalText = nil
                        latestFinalPhase = nil
                        if firstUserMessage == nil {
                            firstUserMessage = text
                        }
                        latestUserText = text
                        lastMessage = text
                        lastMessageRole = "user"
                        lastUserMessageDate = timestamp
                        historyItems.append(ChatHistoryItem(
                            id: "codex-response-user-\(index)",
                            type: .user(text),
                            timestamp: timestamp
                        ))
                        if Self.isTurnAbortMessage(text) {
                            latestTurnAborted = true
                            latestTaskCompletedAt = timestamp
                            intervention = nil
                            Self.markRunningToolsInterrupted(in: &historyItems)
                            phase = .idle
                        } else {
                            latestTurnAborted = false
                            phase = .processing
                        }
                    } else {
                        let messagePhase = stringValue(payload["phase"]) ?? "assistant"
                        latestAgentText = text
                        latestAgentPhase = messagePhase
                        lastMessage = text
                        lastMessageRole = "assistant"

                        let itemType: ChatHistoryItemType
                        if messagePhase == "commentary" {
                            itemType = .thinking(text)
                            latestFinalText = nil
                            latestFinalPhase = nil
                            phase = .processing
                        } else {
                            itemType = .assistant(text)
                            latestFinalText = text
                            latestFinalPhase = messagePhase
                            latestTaskCompletedAt = timestamp
                            phase = .waitingForInput
                        }

                        historyItems.append(ChatHistoryItem(
                            id: "codex-response-agent-\(index)",
                            type: itemType,
                            timestamp: timestamp
                        ))
                    }

                case "reasoning":
                    latestTurnAborted = false
                    latestFinalText = nil
                    latestFinalPhase = nil
                    phase = .processing

                case "function_call":
                    guard let callId = stringValue(payload["call_id"]),
                          let name = stringValue(payload["name"]) else { continue }
                    let inputObject = parseJSONStringObject(payload["arguments"])
                    var input = parseJSONStringDictionary(inputObject ?? payload["arguments"])
                    if let namespace = stringValue(payload["namespace"]) {
                        input["_namespace"] = namespace
                    }
                    let item = ChatHistoryItem(
                        id: callId,
                        type: .toolCall(ToolCallItem(
                            name: name,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: timestamp
                    )
                    toolIndexes[callId] = historyItems.count
                    historyItems.append(item)
                    latestTurnAborted = false
                    latestFinalText = nil
                    latestFinalPhase = nil
                    if let questionIntervention = codexUserInputIntervention(
                        callId: callId,
                        toolName: name,
                        input: inputObject
                    ) {
                        intervention = questionIntervention
                        phase = .waitingForInput
                    } else {
                        phase = .processing
                    }

                case "custom_tool_call":
                    guard let callId = stringValue(payload["call_id"]),
                          let name = stringValue(payload["name"]) else { continue }
                    let input = customToolInput(from: payload["input"])
                    let status = stringValue(payload["status"]) == "completed" ? ToolStatus.success : .running
                    let item = ChatHistoryItem(
                        id: callId,
                        type: .toolCall(ToolCallItem(
                            name: name,
                            input: input,
                            status: status,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: timestamp
                    )
                    toolIndexes[callId] = historyItems.count
                    historyItems.append(item)
                    if status == .running {
                        latestTurnAborted = false
                        latestFinalText = nil
                        latestFinalPhase = nil
                        phase = .processing
                    }

                case "web_search_call":
                    guard let callId = stringValue(payload["call_id"]) else { continue }
                    let query = stringValue(payload["query"]) ?? stringValue(payload["input"]) ?? ""
                    let item = ChatHistoryItem(
                        id: callId,
                        type: .toolCall(ToolCallItem(
                            name: "web_search",
                            input: query.isEmpty ? [:] : ["query": query],
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: timestamp
                    )
                    toolIndexes[callId] = historyItems.count
                    historyItems.append(item)
                    latestTurnAborted = false
                    latestFinalText = nil
                    latestFinalPhase = nil
                    phase = .processing

                case "function_call_output":
                    guard let callId = stringValue(payload["call_id"]),
                          let toolIndex = toolIndexes[callId],
                          case .toolCall(var tool) = historyItems[toolIndex].type else { continue }
                    let output = normalizedText(payload["output"])
                    tool.status = inferredToolStatus(fromOutput: output) ?? .success
                    tool.result = output
                    historyItems[toolIndex] = ChatHistoryItem(
                        id: callId,
                        type: .toolCall(tool),
                        timestamp: historyItems[toolIndex].timestamp
                    )
                    if intervention?.matchesResolvedToolUseId(callId) == true {
                        intervention = nil
                        phase = .processing
                    }

                case "custom_tool_call_output":
                    guard let callId = stringValue(payload["call_id"]),
                          let toolIndex = toolIndexes[callId],
                          case .toolCall(var tool) = historyItems[toolIndex].type else { continue }
                    let nested = parseJSONStringObject(payload["output"])
                    let output = normalizedText(nested?["output"] ?? payload["output"])
                    let exitCode = nested?["metadata"].flatMap { metadata -> Int? in
                        guard let metadata = metadata as? [String: Any] else { return nil }
                        return intValue(metadata["exit_code"])
                    }
                    tool.status = (exitCode == nil || exitCode == 0) ? .success : .error
                    tool.result = output
                    historyItems[toolIndex] = ChatHistoryItem(
                        id: callId,
                        type: .toolCall(tool),
                        timestamp: historyItems[toolIndex].timestamp
                    )

                default:
                    continue
                }

            default:
                continue
            }
        }

        let now = Date()

        if intervention?.kind == .approval {
            let toolUseId = intervention?.metadata["toolUseId"] ?? intervention?.id ?? "codex-approval"
            phase = .waitingForApproval(PermissionContext(
                toolUseId: toolUseId,
                toolName: intervention?.metadata["toolName"] ?? "approval",
                toolInput: nil,
                receivedAt: updatedAt ?? Date()
            ))
        } else if intervention?.kind == .question {
            phase = .waitingForInput
        } else if latestTurnAborted {
            phase = .idle
        } else if historyItems.contains(where: Self.isRunningToolItem(_:)) {
            phase = .processing
        } else if hasFreshUnfinishedTask(
            startedAt: latestTaskStartedAt,
            completedAt: latestTaskCompletedAt,
            lastEventAt: updatedAt,
            runningTaskStartedAts: Array(runningTaskStartedAtByTurnID.values),
            now: now
        ) {
            phase = .processing
        } else if let latestTaskCompletedAt,
                  latestFinalText != nil,
                  now.timeIntervalSince(latestTaskCompletedAt) < completionFreshnessWindow {
            phase = .waitingForInput
        } else if phase == .processing, latestFinalText != nil {
            phase = .idle
        } else if phase == .waitingForInput {
            phase = .idle
        }

        let preview = latestFinalText ?? latestAgentText ?? latestUserText ?? firstUserMessage
        let conversationInfo = ConversationInfo(
            summary: sessionName ?? firstUserMessage,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: nil,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )

        let prefersCLIContext = clientInfo?.kind == .codexCLI
            || origin == "cli"
            || threadSource == "cli"
            || (clientInfo?.terminalBundleIdentifier?.isEmpty == false
                && clientInfo?.terminalBundleIdentifier != "com.openai.codex")
            || clientInfo?.terminalSessionIdentifier?.isEmpty == false
            || clientInfo?.iTermSessionIdentifier?.isEmpty == false

        if prefersCLIContext,
           let inferredIntervention = Self.pendingMCPApprovalIntervention(from: historyItems) {
            intervention = inferredIntervention
            phase = .waitingForInput
        }

        let baseClientInfo = prefersCLIContext
            ? SessionClientInfo.codexCLI()
            : SessionClientInfo.codexApp(threadId: resolvedThreadId)

        let resolvedClientInfo = baseClientInfo.merged(with: SessionClientInfo(
            kind: prefersCLIContext ? .codexCLI : .codexApp,
            name: originator ?? clientInfo?.name,
            bundleIdentifier: prefersCLIContext ? clientInfo?.bundleIdentifier : (clientInfo?.bundleIdentifier ?? "com.openai.codex"),
            launchURL: prefersCLIContext
                ? clientInfo?.launchURL
                : (clientInfo?.launchURL ?? SessionClientInfo.appLaunchURL(
                    bundleIdentifier: clientInfo?.bundleIdentifier ?? "com.openai.codex",
                    sessionId: resolvedThreadId,
                    workspacePath: resolvedCwd
                )),
            origin: origin ?? clientInfo?.origin ?? (prefersCLIContext ? "cli" : "desktop"),
            originator: originator ?? clientInfo?.originator,
            threadSource: threadSource ?? clientInfo?.threadSource,
            transport: clientInfo?.transport,
            remoteHost: clientInfo?.remoteHost,
            sessionFilePath: fileURL.path,
            terminalBundleIdentifier: clientInfo?.terminalBundleIdentifier,
            terminalProgram: clientInfo?.terminalProgram,
            terminalSessionIdentifier: clientInfo?.terminalSessionIdentifier,
            iTermSessionIdentifier: clientInfo?.iTermSessionIdentifier,
            tmuxSessionIdentifier: clientInfo?.tmuxSessionIdentifier,
            tmuxPaneIdentifier: clientInfo?.tmuxPaneIdentifier,
            processName: clientInfo?.processName
        ))

        let retainedHistoryItems = historyMode == .summary
            ? ChatHistoryRetentionPolicy.compactForResidentStorage(historyItems)
            : historyItems

        return CodexThreadSnapshot(
            threadId: resolvedThreadId,
            name: sessionName,
            preview: preview,
            cwd: resolvedCwd,
            parentThreadId: subagentMetadata.parentThreadId,
            subagentDepth: subagentMetadata.depth,
            subagentNickname: subagentMetadata.nickname,
            subagentRole: subagentMetadata.role,
            clientInfo: resolvedClientInfo,
            intervention: intervention,
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? createdAt ?? Date(),
            phase: phase,
            historyItems: retainedHistoryItems,
            conversationInfo: conversationInfo,
            latestTurnId: latestTurnId,
            latestResponseText: latestFinalText ?? latestAgentText,
            latestResponsePhase: latestFinalPhase ?? latestAgentPhase,
            latestUserText: latestUserText,
            isHistoryCompact: historyMode == .summary
        )
    }

    private func resolveRolloutURL(threadId: String, clientInfo: SessionClientInfo?) -> URL? {
        if let sessionFilePath = clientInfo?.sessionFilePath?.nonEmpty,
           FileManager.default.fileExists(atPath: sessionFilePath) {
            return URL(fileURLWithPath: sessionFilePath)
        }

        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions", isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        let suffix = "-\(threadId).jsonl"
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), name.hasSuffix(suffix) else {
                continue
            }
            return fileURL
        }

        return nil
    }

    private func parseSubagentMetadata(
        payload: [String: Any],
        sourceValue: Any?
    ) -> ParsedSubagentMetadata? {
        let topLevelNickname = stringValue(payload["agent_nickname"])
        let topLevelRole = stringValue(payload["agent_role"])
        let forkedFromId = stringValue(payload["forked_from_id"])

        guard let sourceObject = sourceValue as? [String: Any] else {
            if forkedFromId == nil, topLevelNickname == nil, topLevelRole == nil {
                return nil
            }

            return ParsedSubagentMetadata(
                parentThreadId: forkedFromId,
                depth: nil,
                nickname: topLevelNickname,
                role: topLevelRole
            )
        }

        let subagent = sourceObject["subagent"] as? [String: Any]
        let threadSpawn = subagent?["thread_spawn"] as? [String: Any]

        let parentThreadId = stringValue(threadSpawn?["parent_thread_id"]) ?? forkedFromId
        let depth = intValue(threadSpawn?["depth"])
        let nickname = stringValue(threadSpawn?["agent_nickname"]) ?? topLevelNickname
        let role = stringValue(threadSpawn?["agent_role"]) ?? topLevelRole

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

    private static func isRunningToolItem(_ item: ChatHistoryItem) -> Bool {
        guard case .toolCall(let tool) = item.type else {
            return false
        }
        return tool.status == .running || tool.status == .waitingForApproval
    }

    private static func isTurnAbortMessage(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("<turn_aborted>")
            || normalized.contains("turn_aborted")
            || normalized.contains("the user interrupt")
    }

    private static func markRunningToolsInterrupted(in items: inout [ChatHistoryItem]) {
        for index in items.indices {
            guard case .toolCall(var tool) = items[index].type,
                  tool.status == .running || tool.status == .waitingForApproval else {
                continue
            }

            tool.status = .interrupted
            items[index] = ChatHistoryItem(
                id: items[index].id,
                type: .toolCall(tool),
                timestamp: items[index].timestamp
            )
        }
    }

    private static func toolIndexes(for items: [ChatHistoryItem]) -> [String: Int] {
        var indexes: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            if case .toolCall = item.type {
                indexes[item.id] = index
            }
        }
        return indexes
    }

    private func applyMCPToolCallEnd(
        payload: [String: Any],
        historyItems: inout [ChatHistoryItem],
        toolIndexes: [String: Int],
        intervention: inout SessionIntervention?,
        phase: inout SessionPhase
    ) {
        guard let callId = stringValue(payload["call_id"]),
              let toolIndex = toolIndexes[callId],
              case .toolCall(var tool) = historyItems[toolIndex].type else {
            return
        }

        tool.status = mcpToolCallEndStatus(from: payload)
        tool.result = mcpToolCallResultText(from: payload) ?? tool.result
        historyItems[toolIndex] = ChatHistoryItem(
            id: callId,
            type: .toolCall(tool),
            timestamp: historyItems[toolIndex].timestamp
        )

        if intervention?.matchesResolvedToolUseId(callId) == true {
            intervention = nil
            phase = .processing
        }
    }

    private func mcpToolCallEndStatus(from payload: [String: Any]) -> ToolStatus {
        guard let result = parseJSONStringObject(payload["result"]) else {
            return .success
        }

        if let ok = result["Ok"] as? [String: Any] {
            return boolValue(ok["isError"]) == true ? .error : .success
        }

        if result["Err"] != nil {
            return .error
        }

        return .success
    }

    private func mcpToolCallResultText(from payload: [String: Any]) -> String? {
        guard let result = parseJSONStringObject(payload["result"]) else {
            return nil
        }

        if let ok = result["Ok"] as? [String: Any] {
            return mcpContentText(ok["content"])
                ?? normalizedText(ok["text"])
                ?? normalizedText(ok["message"])
        }

        if let error = result["Err"] {
            if let text = normalizedText(error) {
                return text
            }
            if let object = error as? [String: Any] {
                return normalizedText(object["message"])
                    ?? normalizedText(object["error"])
                    ?? normalizedText(object["text"])
            }
        }

        return nil
    }

    private func mcpContentText(_ value: Any?) -> String? {
        guard let content = value as? [[String: Any]] else {
            return nil
        }

        let text = content.compactMap { item -> String? in
            normalizedText(item["text"])
                ?? normalizedText(item["output_text"])
                ?? normalizedText(item["content"])
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.nonEmpty
    }

    private static func pendingMCPApprovalIntervention(from historyItems: [ChatHistoryItem]) -> SessionIntervention? {
        for item in historyItems.reversed() {
            guard case .toolCall(let tool) = item.type,
                  tool.status == .running,
                  tool.name.hasPrefix("mcp__") else {
                continue
            }

            let parts = tool.name.split(separator: "__", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let server = String(parts[1])
            let toolName = parts[2...].joined(separator: "__")

            return SessionIntervention(
                id: "mcp-pending-\(server)-\(toolName)",
                kind: .question,
                title: "MCP Tool Approval Needed",
                message: "Allow the \(server) MCP server to run tool \"\(toolName)\"?",
                options: [],
                questions: [],
                supportsSessionScope: false,
                metadata: [
                    "responseMode": "external_only",
                    "source": "rollout_pending_mcp",
                    "server": server,
                    "toolName": toolName
                ]
            )
        }

        return nil
    }

    private func codexUserInputIntervention(
        callId: String,
        toolName: String,
        input: [String: Any]?
    ) -> SessionIntervention? {
        guard normalizedToolName(toolName) == "requestuserinput" else {
            return nil
        }

        let questions = parseInterventionQuestions(input?["questions"] as? [[String: Any]] ?? [])
        guard !questions.isEmpty else {
            return nil
        }

        let prompt = questions.first?.prompt ?? "Codex needs your input."
        let isApprovalPrompt = isApprovalLikeUserInput(questions)
        var metadata: [String: String] = [
            "source": "codex_rollout_request_user_input",
            "responseMode": "external_only",
            "toolName": toolName,
            "toolUseId": callId
        ]
        if isApprovalPrompt {
            metadata["semanticRole"] = "approval"
        }
        if let input,
           JSONSerialization.isValidJSONObject(input),
           let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            metadata["toolInputJSON"] = json
        }

        return SessionIntervention(
            id: callId,
            kind: isApprovalPrompt ? .approval : .question,
            title: isApprovalPrompt ? "Codex Requests Approval" : "Codex Needs Input",
            message: prompt,
            options: questions.first?.options ?? [],
            questions: questions,
            supportsSessionScope: false,
            metadata: metadata
        )
    }

    private func parseInterventionQuestions(_ rawQuestions: [[String: Any]]) -> [SessionInterventionQuestion] {
        rawQuestions.enumerated().compactMap { index, question in
            let prompt = stringValue(question["question"])
                ?? stringValue(question["prompt"])
                ?? stringValue(question["label"])
            guard let prompt, !prompt.isEmpty else { return nil }

            let objectOptions = (question["options"] as? [[String: Any]] ?? []).enumerated().compactMap { optionIndex, option -> SessionInterventionOption? in
                guard let label = stringValue(option["label"]) ?? stringValue(option["title"]),
                      !label.isEmpty else { return nil }
                return SessionInterventionOption(
                    id: stringValue(option["id"]) ?? label,
                    title: label,
                    detail: stringValue(option["description"])
                )
            }

            let stringOptions = (question["options"] as? [String] ?? []).enumerated().map { optionIndex, label in
                SessionInterventionOption(
                    id: "\(index)-option-\(optionIndex)",
                    title: label,
                    detail: nil
                )
            }

            return SessionInterventionQuestion(
                id: stringValue(question["id"]) ?? prompt,
                header: stringValue(question["header"]) ?? "\(index + 1).",
                prompt: prompt,
                detail: stringValue(question["description"]),
                options: objectOptions.isEmpty ? stringOptions : objectOptions,
                allowsMultiple: boolValue(question["isMultiple"])
                    ?? boolValue(question["allowsMultiple"])
                    ?? boolValue(question["multiSelect"])
                    ?? boolValue(question["multiple"])
                    ?? false,
                allowsOther: boolValue(question["isOther"])
                    ?? boolValue(question["allowsOther"])
                    ?? false,
                isSecret: boolValue(question["isSecret"])
                    ?? boolValue(question["secret"])
                    ?? false
            )
        }
    }

    private func isApprovalLikeUserInput(_ questions: [SessionInterventionQuestion]) -> Bool {
        let combinedText = questions
            .flatMap { question -> [String] in
                [
                    question.header,
                    question.prompt,
                    question.detail
                ].compactMap(\.self) + question.options.flatMap { option in
                    [option.title, option.detail].compactMap(\.self)
                }
            }
            .joined(separator: " ")
            .lowercased()

        let hasApprovalDecisionOption = questions.contains { question in
            let labels = question.options.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let hasPositive = labels.contains { label in
                label == "yes"
                    || label == "allow"
                    || label == "approve"
                    || label == "是"
                    || label.hasPrefix("是，")
                    || label.hasPrefix("是,")
                    || label.hasPrefix("允许")
                    || label.hasPrefix("批准")
            }
            let hasNegative = labels.contains { label in
                label == "no"
                    || label == "deny"
                    || label == "reject"
                    || label == "否"
                    || label.hasPrefix("否，")
                    || label.hasPrefix("否,")
                    || label.hasPrefix("拒绝")
                    || label.hasPrefix("不允许")
            }
            return hasPositive && hasNegative
        }

        guard hasApprovalDecisionOption else {
            return false
        }

        let approvalCues = [
            "是否允许",
            "是否准许",
            "是否批准",
            "要关闭",
            "要删除",
            "要覆盖",
            "要替换",
            "要运行",
            "要执行",
            "allow",
            "approve",
            "permission",
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

    private func parseJSONStringDictionary(_ value: Any?) -> [String: String] {
        guard let object = parseJSONStringObject(value) else {
            return [:]
        }

        var result: [String: String] = [:]
        for (key, raw) in object {
            if let string = stringValue(raw) {
                result[key] = string
            } else if JSONSerialization.isValidJSONObject(raw),
                      let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
                      let string = String(data: data, encoding: .utf8) {
                result[key] = string
            }
        }
        return result
    }

    private func parseJSONStringObject(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] {
            return object
        }
        guard let string = value as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func customToolInput(from value: Any?) -> [String: String] {
        if let dictionary = parseJSONStringObject(value), !dictionary.isEmpty {
            return parseJSONStringDictionary(dictionary)
        }
        if let string = stringValue(value) {
            return ["input": string]
        }
        return [:]
    }

    private func inferredToolStatus(fromOutput output: String?) -> ToolStatus? {
        guard let output else { return nil }

        if let range = output.range(of: "Process exited with code ") {
            let suffix = output[range.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            if let code = Int(digits) {
                return code == 0 ? .success : .error
            }
        }

        return nil
    }

    private func parseISO8601(_ value: String?) -> Date? {
        guard let value = value?.nonEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func normalizedText(_ value: Any?) -> String? {
        stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func normalizedResponseMessageText(_ payload: [String: Any]) -> String? {
        if let direct = normalizedText(payload["message"]) ?? normalizedText(payload["text"]) {
            return direct
        }

        if let content = payload["content"] as? [[String: Any]] {
            let text = content.compactMap { item -> String? in
                normalizedText(item["text"])
                    ?? normalizedText(item["output_text"])
                    ?? normalizedText(item["content"])
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.nonEmpty
        }

        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "1"].contains(normalized) {
                return true
            }
            if ["false", "no", "0"].contains(normalized) {
                return false
            }
            return nil
        default:
            return nil
        }
    }

    private func normalizedToolName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

private extension String {
    nonisolated var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
