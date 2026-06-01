import XCTest
@testable import Ping_Island

final class SessionStoreCodexInterventionTests: XCTestCase {
    func testCodexAppServerFiltersInternalEnvironmentContextThread() {
        let threadId = "8e4ece59-2fb3-4cff-b9f4-84bfb36a4e7f"
        let thread: [String: Any] = [
            "id": threadId,
            "name": "<environment_context>",
            "preview": "# Instructions (read first)\n# OD core directives (read first)",
            "cwd": "/Users/test/Library/Application Support/Codex/session-\(threadId)",
            "status": [
                "type": "active"
            ]
        ]

        XCTAssertTrue(CodexAppServerMonitor.shouldFilterInternalContextThreadForUI(thread))
    }

    func testCodexAppServerDoesNotFilterInternalContextThreadWhenApprovalIsWaiting() {
        let threadId = "8e4ece59-2fb3-4cff-b9f4-84bfb36a4e7f"
        let thread: [String: Any] = [
            "id": threadId,
            "name": "<environment_context>",
            "preview": "# Instructions (read first)\n# OD core directives (read first)",
            "cwd": "/Users/test/Library/Application Support/Codex/session-\(threadId)",
            "status": [
                "type": "active",
                "activeFlags": ["waitingOnApproval"]
            ]
        ]

        XCTAssertFalse(CodexAppServerMonitor.shouldFilterInternalContextThreadForUI(thread))
    }

    func testCodexAppServerDoesNotFilterInternalContextThreadWithTopLevelWaitingApprovalLabel() {
        let threadId = "8e4ece59-2fb3-4cff-b9f4-84bfb36a4e7f"
        let thread: [String: Any] = [
            "id": threadId,
            "name": "<environment_context>",
            "preview": "# Instructions (read first)\n# OD core directives (read first)",
            "cwd": "/Users/test/Library/Application Support/Codex/session-\(threadId)",
            "label": "等待审批",
            "status": [
                "type": "active"
            ]
        ]

        XCTAssertFalse(CodexAppServerMonitor.shouldFilterInternalContextThreadForUI(thread))
    }

    func testCodexAppServerDoesNotFilterInternalContextThreadWithApprovalStatusString() {
        let threadId = "8e4ece59-2fb3-4cff-b9f4-84bfb36a4e7f"
        let thread: [String: Any] = [
            "id": threadId,
            "name": "<environment_context>",
            "preview": "# Instructions (read first)\n# OD core directives (read first)",
            "cwd": "/Users/test/Library/Application Support/Codex/session-\(threadId)",
            "status": "waiting_on_approval"
        ]

        XCTAssertFalse(CodexAppServerMonitor.shouldFilterInternalContextThreadForUI(thread))
    }

    func testCodexAppServerDoesNotFilterNormalProjectThread() {
        let thread: [String: Any] = [
            "id": "019dc0b1-1b2c-73d8-9d3d-9833ecfc7fb4",
            "name": "大屏设计 tab1",
            "preview": "默认视角能看到底部三项已经换成成本结构指标了",
            "cwd": "/Users/test/Documents/New project 7",
            "path": "/Users/test/.codex/sessions/rollout-019dc0b1-1b2c-73d8-9d3d-9833ecfc7fb4.jsonl",
            "status": [
                "type": "active"
            ]
        ]

        XCTAssertFalse(CodexAppServerMonitor.shouldFilterInternalContextThreadForUI(thread))
    }

    func testCodexStatusRecognizesChineseWaitingApprovalLabel() {
        let status: [String: Any] = [
            "type": "active",
            "label": "等待审批"
        ]

        XCTAssertTrue(CodexAppServerMonitor.statusIndicatesWaitingOnApproval(status))
    }

    func testCodexStatusRecognizesNestedApprovalRequiredState() {
        let status: [String: Any] = [
            "type": "in_progress",
            "state": [
                "kind": "approval_required",
                "message": "Approval required before running command"
            ]
        ]

        XCTAssertTrue(CodexAppServerMonitor.statusIndicatesWaitingOnApproval(status))
    }

    func testCodexFailureMetadataMarksSessionFailure() async {
        let sessionId = "codex-system-error-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: nil,
            preview: nil,
            cwd: "/tmp/project",
            phase: .idle,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexApp, profileID: "codex-app", name: "Codex App"),
            metadata: [
                "failureEventID": "codex-status-systemerror-offline",
                "failureReason": "The Internet connection appears to be offline."
            ]
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.sessionFailureEventIDs, Set(["codex-status-systemerror-offline"]))
        XCTAssertEqual(session?.previewText, "The Internet connection appears to be offline.")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testRuntimeCrashMarksSessionFailureBeforeEnding() async {
        let sessionId = "codex-runtime-crash-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: nil,
            preview: nil,
            cwd: "/tmp/project",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex")
        )

        await store.process(.runtimeSessionStopped(sessionId: sessionId, reason: .crashed))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .ended)
        XCTAssertEqual(session?.sessionFailureEventIDs, Set(["runtime-crashed"]))

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexAppServerIdleRefreshDoesNotClearExternalOnlyIntervention() async {
        let sessionId = "codex-external-\(UUID().uuidString)"
        let store = SessionStore.shared

        let intervention = SessionIntervention(
            id: "mcp-pending-omx_state-state_list_active",
            kind: .question,
            title: "MCP Tool Approval Needed",
            message: "Allow the omx_state MCP server to run tool \"state_list_active\"?",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [
                "responseMode": "external_only",
                "source": "rollout_pending_mcp",
                "server": "omx_state",
                "toolName": "state_list_active"
            ]
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: nil,
            preview: intervention.message,
            cwd: "/tmp/project",
            phase: .waitingForInput,
            intervention: intervention,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex")
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: nil,
            preview: "删除 LICENSE 文件",
            cwd: "/tmp/project",
            phase: .idle,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex")
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.intervention?.title, "MCP Tool Approval Needed")
        XCTAssertEqual(session?.phase, .waitingForInput)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexAppServerIdleRefreshDoesNotClearCodexAppMCPApproval() async {
        let sessionId = "codex-app-mcp-approval-\(UUID().uuidString)"
        let store = SessionStore.shared

        let intervention = SessionIntervention(
            id: "mcp-pending-computer_use-get_app_state",
            kind: .approval,
            title: "MCP Tool Approval Needed",
            message: "Allow the computer_use MCP server to run tool \"get_app_state\"?",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [
                "responseMode": "external_only",
                "source": "codex_app_pending_mcp",
                "server": "computer_use",
                "toolName": "get_app_state",
                "toolUseId": "call_computer_use_approval"
            ]
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: nil,
            preview: intervention.message,
            cwd: "/tmp/project",
            phase: .waitingForApproval(PermissionContext(
                toolUseId: "call_computer_use_approval",
                toolName: "get_app_state",
                toolInput: nil,
                receivedAt: Date()
            )),
            intervention: intervention,
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex"
            )
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: nil,
            preview: "checking Ping Island",
            cwd: "/tmp/project",
            phase: .idle,
            intervention: nil,
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex"
            )
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.intervention?.kind, .approval)
        XCTAssertEqual(session?.intervention?.metadata["source"], "codex_app_pending_mcp")
        XCTAssertEqual(session?.phase.isWaitingForApproval, true)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexAppServerQuestionSurvivesRolloutQuestionRefresh() async {
        let sessionId = "codex-app-question-\(UUID().uuidString)"
        let store = SessionStore.shared
        let appServerIntervention = SessionIntervention(
            id: "jsonrpc-request-1",
            kind: .question,
            title: "Codex Needs Input",
            message: "TodoList 示例的数据要怎么处理？",
            options: [],
            questions: [
                SessionInterventionQuestion(
                    id: "todo_data",
                    header: "Data",
                    prompt: "TodoList 示例的数据要怎么处理？",
                    detail: nil,
                    options: [],
                    allowsMultiple: false,
                    allowsOther: false,
                    isSecret: false
                )
            ],
            supportsSessionScope: false,
            metadata: [
                "turnId": "turn-1",
                "itemId": "item-1"
            ]
        )
        let rolloutIntervention = SessionIntervention(
            id: "call_question_1",
            kind: .question,
            title: "Codex Needs Input",
            message: "TodoList 示例的数据要怎么处理？",
            options: [],
            questions: appServerIntervention.resolvedQuestions,
            supportsSessionScope: false,
            metadata: [
                "source": "codex_rollout_request_user_input",
                "responseMode": "external_only",
                "toolUseId": "call_question_1"
            ]
        )
        let now = Date()

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: appServerIntervention.message,
            cwd: "/tmp/project",
            phase: .waitingForInput,
            intervention: appServerIntervention,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            activityAt: now
        )

        await store.syncCodexThreadSnapshot(
            CodexThreadSnapshot(
                threadId: sessionId,
                name: "Codex",
                preview: rolloutIntervention.message,
                cwd: "/tmp/project",
                clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
                intervention: rolloutIntervention,
                createdAt: now,
                updatedAt: now.addingTimeInterval(1),
                phase: .waitingForInput,
                historyItems: [],
                conversationInfo: ConversationInfo(
                    summary: "Codex",
                    lastMessage: rolloutIntervention.message,
                    lastMessageRole: "assistant",
                    lastToolName: nil,
                    firstUserMessage: "build a TodoList sample",
                    lastUserMessageDate: now
                ),
                latestTurnId: "turn-1",
                latestResponseText: nil,
                latestResponsePhase: nil,
                latestUserText: "build a TodoList sample"
            ),
            ingress: .hookBridge
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.intervention?.id, "jsonrpc-request-1")
        XCTAssertEqual(session?.intervention?.metadata["itemId"], "item-1")
        XCTAssertEqual(session?.phase, .waitingForInput)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexAppServerApprovalSurvivesProcessingRefresh() async {
        let sessionId = "codex-app-server-command-approval-\(UUID().uuidString)"
        let store = SessionStore.shared
        let now = Date()
        let intervention = SessionIntervention(
            id: "jsonrpc-approval-1",
            kind: .approval,
            title: "Approve Command",
            message: "Allow Codex to copy the rendered PNG into the target folder?",
            options: [],
            questions: [],
            supportsSessionScope: true,
            metadata: [
                "source": "codex_app_server_request_approval",
                "toolName": "exec_command"
            ]
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: intervention.message,
            cwd: "/tmp/project",
            phase: .waitingForApproval(PermissionContext(
                toolUseId: "call_cp_approval",
                toolName: "exec_command",
                toolInput: nil,
                receivedAt: now
            )),
            intervention: intervention,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            activityAt: now
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: "Running command",
            cwd: "/tmp/project",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            activityAt: now.addingTimeInterval(1)
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.intervention?.id, "jsonrpc-approval-1")
        XCTAssertEqual(session?.intervention?.kind, .approval)
        XCTAssertEqual(session?.phase.approvalToolName, "exec_command")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexAppServerStatusApprovalSurvivesRolloutProcessingRefresh() async {
        let sessionId = "codex-app-server-status-approval-\(UUID().uuidString)"
        let store = SessionStore.shared
        let now = Date()
        let intervention = SessionIntervention(
            id: "codex-status-approval-\(sessionId)",
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

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: intervention.message,
            cwd: "/tmp/project",
            phase: .waitingForApproval(PermissionContext(
                toolUseId: intervention.id,
                toolName: intervention.title,
                toolInput: nil,
                receivedAt: now
            )),
            intervention: intervention,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            activityAt: now
        )

        let snapshot = CodexThreadSnapshot(
            threadId: sessionId,
            name: "Codex",
            preview: "Running command",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            intervention: nil,
            createdAt: now,
            updatedAt: now.addingTimeInterval(1),
            phase: .processing,
            historyItems: [],
            conversationInfo: ConversationInfo(
                summary: "Codex",
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil
            ),
            latestTurnId: nil,
            latestResponseText: nil,
            latestResponsePhase: nil,
            latestUserText: nil
        )

        await store.syncCodexThreadSnapshot(snapshot, ingress: .hookBridge)

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.intervention?.id, intervention.id)
        XCTAssertEqual(session?.phase.approvalToolName, intervention.title)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexTurnAbortSnapshotClearsProcessingRunningToolState() async throws {
        let sessionId = "codex-turn-abort-\(UUID().uuidString)"
        let store = SessionStore.shared
        let now = Date()

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "open_Design",
            preview: "Running command",
            cwd: "/tmp/open_Design",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            activityAt: now
        )

        await store.syncCodexThreadSnapshot(
            CodexThreadSnapshot(
                threadId: sessionId,
                name: "open_Design",
                preview: "<turn_aborted> The user interrupted the request.",
                cwd: "/tmp/open_Design",
                clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
                intervention: nil,
                createdAt: now,
                updatedAt: now.addingTimeInterval(1),
                phase: .idle,
                historyItems: [
                    ChatHistoryItem(
                        id: "call_tail_log",
                        type: .toolCall(ToolCallItem(
                            name: "exec_command",
                            input: ["cmd": "tail -200 app.log"],
                            status: .interrupted,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: now
                    ),
                    ChatHistoryItem(
                        id: "abort-user-message",
                        type: .user("<turn_aborted> The user interrupted the request."),
                        timestamp: now.addingTimeInterval(1)
                    )
                ],
                conversationInfo: ConversationInfo(
                    summary: "open_Design",
                    lastMessage: "<turn_aborted> The user interrupted the request.",
                    lastMessageRole: "user",
                    lastToolName: nil,
                    firstUserMessage: "tail the app log",
                    lastUserMessageDate: now.addingTimeInterval(1)
                ),
                latestTurnId: nil,
                latestResponseText: nil,
                latestResponsePhase: nil,
                latestUserText: "<turn_aborted> The user interrupted the request."
            ),
            ingress: .hookBridge
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)

        let tool = try XCTUnwrap(session?.chatItems.compactMap { item -> ToolCallItem? in
            guard case .toolCall(let tool) = item.type else { return nil }
            return tool.name == "exec_command" ? tool : nil
        }.first)
        XCTAssertEqual(tool.status, .interrupted)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexTurnAbortSnapshotClearsProcessingEvenWhenSnapshotTimestampIsStale() async throws {
        let sessionId = "codex-turn-abort-stale-\(UUID().uuidString)"
        let store = SessionStore.shared
        let now = Date()

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "open_Design",
            preview: "Running command",
            cwd: "/tmp/open_Design",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            activityAt: now
        )

        await store.syncCodexThreadSnapshot(
            CodexThreadSnapshot(
                threadId: sessionId,
                name: "open_Design",
                preview: "<turn_aborted> The user interrupted the request.",
                cwd: "/tmp/open_Design",
                clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
                intervention: nil,
                createdAt: now.addingTimeInterval(-10),
                updatedAt: now.addingTimeInterval(-5),
                phase: .idle,
                historyItems: [
                    ChatHistoryItem(
                        id: "call_tail_log",
                        type: .toolCall(ToolCallItem(
                            name: "exec_command",
                            input: ["cmd": "tail -200 app.log"],
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: now.addingTimeInterval(-6)
                    ),
                    ChatHistoryItem(
                        id: "abort-user-message",
                        type: .user("<turn_aborted> The user interrupted the request."),
                        timestamp: now.addingTimeInterval(-5)
                    )
                ],
                conversationInfo: ConversationInfo(
                    summary: "open_Design",
                    lastMessage: "<turn_aborted> The user interrupted the request.",
                    lastMessageRole: "user",
                    lastToolName: nil,
                    firstUserMessage: "tail the app log",
                    lastUserMessageDate: now.addingTimeInterval(-5)
                ),
                latestTurnId: nil,
                latestResponseText: nil,
                latestResponsePhase: nil,
                latestUserText: "<turn_aborted> The user interrupted the request."
            ),
            ingress: .hookBridge
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)

        let tool = try XCTUnwrap(session?.chatItems.compactMap { item -> ToolCallItem? in
            guard case .toolCall(let tool) = item.type else { return nil }
            return tool.name == "exec_command" ? tool : nil
        }.first)
        XCTAssertEqual(tool.status, .interrupted)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexAppServerTurnAbortPreviewClearsProcessingState() async {
        let sessionId = "codex-app-server-turn-abort-\(UUID().uuidString)"
        let store = SessionStore.shared
        let now = Date()

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "open_Design",
            preview: "Running command",
            cwd: "/tmp/open_Design",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            activityAt: now
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "open_Design",
            preview: "<turn_aborted> The user interrupted the request.",
            cwd: "/tmp/open_Design",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            activityAt: now.addingTimeInterval(1)
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(session?.previewText, "<turn_aborted> The user interrupted the request.")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testStaleCodexIdleRefreshDoesNotDowngradeFreshProcessingState() async {
        let sessionId = "codex-stale-idle-\(UUID().uuidString)"
        let store = SessionStore.shared
        let freshActivityAt = Date()

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: "Following up",
            cwd: "/tmp/project",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
            activityAt: freshActivityAt
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: "Old snapshot",
            cwd: "/tmp/project",
            phase: .idle,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
            activityAt: freshActivityAt.addingTimeInterval(-300)
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertEqual(session?.lastActivity, freshActivityAt)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexIdleRefreshDoesNotDowngradeRunningToolThread() async {
        let sessionId = "codex-running-tool-\(UUID().uuidString)"
        let store = SessionStore.shared
        let startedAt = Date()

        await store.syncCodexThreadSnapshot(
            CodexThreadSnapshot(
                threadId: sessionId,
                name: "Codex",
                preview: "Running tool",
                cwd: "/tmp/project",
                clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
                intervention: nil,
                createdAt: startedAt,
                updatedAt: startedAt,
                phase: .processing,
                historyItems: [
                    ChatHistoryItem(
                        id: "tool-1",
                        type: .toolCall(ToolCallItem(
                            name: "shell",
                            input: ["command": "sleep 120"],
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: startedAt
                    )
                ],
                conversationInfo: ConversationInfo(
                    summary: "Codex",
                    lastMessage: nil,
                    lastMessageRole: nil,
                    lastToolName: nil,
                    firstUserMessage: "keep going",
                    lastUserMessageDate: startedAt
                ),
                latestTurnId: "turn-1",
                latestResponseText: nil,
                latestResponsePhase: nil,
                latestUserText: "keep going"
            )
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: "Idle heartbeat",
            cwd: "/tmp/project",
            phase: .idle,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
            activityAt: startedAt.addingTimeInterval(90)
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertEqual(session?.lastActivity, startedAt)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexHookPermissionRequestSurvivesAppServerRefresh() async {
        let sessionId = "codex-hook-approval-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("date"),
                "description": AnyCodable("Show the current time.")
            ],
            toolUseId: "call-date-1",
            notificationType: nil,
            message: nil
        )))

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: nil,
            preview: "Show the current time.",
            cwd: "/tmp/project",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            activityAt: Date().addingTimeInterval(5)
        )

        let session = await store.session(for: sessionId)
        XCTAssertTrue(session?.phase.isWaitingForApproval == true)
        XCTAssertEqual(session?.activePermission?.toolUseId, "call-date-1")
        XCTAssertEqual(session?.activePermission?.toolName, "Bash")
        XCTAssertEqual(session?.intervention?.kind, .approval)
        XCTAssertEqual(session?.intervention?.title, "Approve Command")
        XCTAssertEqual(session?.intervention?.message, "date")
        XCTAssertEqual(session?.intervention?.supportsSessionScope, false)
        XCTAssertEqual(session?.intervention?.metadata["source"], "codex_hook_permission")
        XCTAssertEqual(session?.ingress, .hookBridge)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexHookPermissionApprovalClearsInterventionImmediately() async {
        let sessionId = "codex-hook-approved-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI"),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("curl -I https://example.com"),
                "description": AnyCodable("Allow a test HEAD request.")
            ],
            toolUseId: "call-curl-1",
            notificationType: nil,
            message: nil
        )))

        var session = await store.session(for: sessionId)
        XCTAssertTrue(session?.needsApprovalResponse ?? false)
        XCTAssertEqual(session?.intervention?.metadata["source"], "codex_hook_permission")

        await store.process(.permissionApproved(sessionId: sessionId, toolUseId: "call-curl-1"))

        session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertNil(session?.intervention)
        XCTAssertFalse(session?.needsApprovalResponse ?? true)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexHookPermissionDenialClearsInterventionImmediately() async {
        let sessionId = "codex-hook-denied-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI"),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: ["command": AnyCodable("curl -I https://example.com")],
            toolUseId: "call-curl-deny",
            notificationType: nil,
            message: nil
        )))

        await store.process(
            .permissionDenied(sessionId: sessionId, toolUseId: "call-curl-deny", reason: "No network")
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertNil(session?.intervention)
        XCTAssertFalse(session?.needsApprovalResponse ?? true)

        await store.process(.sessionArchived(sessionId: sessionId))
    }
}
