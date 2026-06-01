import Foundation
import XCTest
@testable import Ping_Island

final class CodexRolloutParserTests: XCTestCase {
    func testRolloutParserPreservesTerminalHostedCodexCLIContext() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019d77a9-b7e4-76d3-996a-adadefcf7a56"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-10T13:51:51Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/github/claude-island","originator":"codex-tui","source":"cli"}}
        {"timestamp":"2026-04-10T13:51:52Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}
        {"timestamp":"2026-04-10T13:51:57Z","type":"event_msg","payload":{"type":"agent_message","phase":"final","message":"Hi. What do you need help with in this repo?"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/github/claude-island",
            clientInfo: SessionClientInfo(
                kind: .codexCLI,
                profileID: "codex-cli",
                name: "Codex",
                origin: "cli",
                threadSource: "cli",
                sessionFilePath: rolloutURL.path,
                terminalBundleIdentifier: "com.googlecode.iterm2",
                terminalProgram: "iTerm.app",
                terminalSessionIdentifier: "w0t0p0:82B6B83C-9817-47EB-B42B-EDC2AAB96556",
                iTermSessionIdentifier: "w0t0p0:82B6B83C-9817-47EB-B42B-EDC2AAB96556",
                processName: "/Users/ping-island/.nvm/versions/node/v22.21.1/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex"
            )
        )

        let clientInfo = try XCTUnwrap(snapshot?.clientInfo)
        XCTAssertEqual(clientInfo.kind, .codexCLI)
        XCTAssertEqual(clientInfo.origin, "cli")
        XCTAssertEqual(clientInfo.threadSource, "cli")
        XCTAssertEqual(clientInfo.terminalBundleIdentifier, "com.googlecode.iterm2")
        XCTAssertEqual(clientInfo.iTermSessionIdentifier, "w0t0p0:82B6B83C-9817-47EB-B42B-EDC2AAB96556")
        XCTAssertNil(clientInfo.bundleIdentifier)
        XCTAssertNil(clientInfo.launchURL)
    }

    func testRolloutParserInfersPendingMCPApprovalFromUnresolvedToolCall() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019d7874-9b7a-7533-a757-3fb452609c4d"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-10T17:41:27.371Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/github/CodeIsland","originator":"codex-tui","source":"cli"}}
        {"timestamp":"2026-04-10T17:41:27.371Z","type":"event_msg","payload":{"type":"user_message","message":"删除一下 README 文件"}}
        {"timestamp":"2026-04-10T17:41:40.139Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"仓库根目录里有 `README.md` 和 `README.zh-CN.md` 两个文件；按你的单数表述，我先删除主 README，也就是根目录的 `README.md`。先核对当前状态，再直接改。"}],"phase":"commentary"}}
        {"timestamp":"2026-04-10T17:41:40.151Z","type":"response_item","payload":{"type":"function_call","name":"mcp__omx_state__state_get_status","arguments":"{\\"workingDirectory\\":\\"/Users/ping-island/github/CodeIsland\\"}","call_id":"call_IvTKO1mWarOvCiIBwppVMmyt"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/github/CodeIsland",
            clientInfo: SessionClientInfo(
                kind: .codexCLI,
                profileID: "codex-cli",
                name: "Codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertEqual(snapshot?.phase, .waitingForInput)
        XCTAssertEqual(snapshot?.intervention?.title, "MCP Tool Approval Needed")
        XCTAssertEqual(snapshot?.intervention?.metadata["server"], "omx_state")
        XCTAssertEqual(snapshot?.intervention?.metadata["toolName"], "state_get_status")
    }

    func testRolloutParserDoesNotInferPendingMCPApprovalForCodexApp() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019d7874-9b7a-7533-a757-3fb452609c4d"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-10T17:41:27.371Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/github/CodeIsland","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-04-10T17:41:27.371Z","type":"event_msg","payload":{"type":"user_message","message":"删除一下 README 文件"}}
        {"timestamp":"2026-04-10T17:41:40.151Z","type":"response_item","payload":{"type":"function_call","name":"mcp__omx_state__state_get_status","arguments":"{\\"workingDirectory\\":\\"/Users/ping-island/github/CodeIsland\\"}","call_id":"call_IvTKO1mWarOvCiIBwppVMmyt"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/github/CodeIsland",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertNil(snapshot?.intervention)
        XCTAssertEqual(snapshot?.phase, .processing)
    }

    func testRolloutParserIgnoresDeveloperContextMessages() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019e4f1d-07b1-7890-a3e6-2d2f32fb5940"
        let startedAt = Date().addingTimeInterval(-30)
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"\(iso8601String(startedAt.addingTimeInterval(-3)))","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"\(iso8601String(startedAt.addingTimeInterval(-2)))","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions> internal context only"}]}}
        {"timestamp":"\(iso8601String(startedAt.addingTimeInterval(-1)))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"现在有任务在跑 但是灵动岛还是空闲状态"}]}}
        {"timestamp":"\(iso8601String(startedAt))","type":"event_msg","payload":{"type":"task_started"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let clientInfo = SessionClientInfo(
            kind: .codexApp,
            profileID: "codex-app",
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            sessionFilePath: rolloutURL.path
        )
        let fullSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: clientInfo,
            historyMode: .fullHistory
        )
        let summarySnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: clientInfo,
            historyMode: .summary
        )

        for snapshot in [fullSnapshot, summarySnapshot] {
            XCTAssertEqual(snapshot?.phase, .processing)
            XCTAssertEqual(snapshot?.conversationInfo.firstUserMessage, "现在有任务在跑 但是灵动岛还是空闲状态")
            XCTAssertFalse(snapshot?.latestResponseText?.contains("<permissions instructions>") ?? false)
        }
    }

    func testRolloutParserKeepsFreshUnfinishedTaskProcessingAfterOldStart() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019e4f1d-64b3-7339-8ce3-bc43f5ac141e"
        let startedAt = Date().addingTimeInterval(-12 * 60)
        let heartbeatAt = Date().addingTimeInterval(-30)
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"\(iso8601String(startedAt.addingTimeInterval(-1)))","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"\(iso8601String(startedAt))","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"\(iso8601String(heartbeatAt))","type":"event_msg","payload":{"type":"token_count","input_tokens":123,"output_tokens":456}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let clientInfo = SessionClientInfo(
            kind: .codexApp,
            profileID: "codex-app",
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            sessionFilePath: rolloutURL.path
        )
        let fullSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: clientInfo,
            historyMode: .fullHistory
        )
        let summarySnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: clientInfo,
            historyMode: .summary
        )

        XCTAssertEqual(fullSnapshot?.phase, .processing)
        XCTAssertEqual(summarySnapshot?.phase, .processing)
    }

    func testRolloutParserKeepsNewerOverlappingTaskProcessingWhenOlderTurnCompletes() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019e4f61-bab2-7f57-b801-8b893e7b10ef"
        let oldTurnId = "019e4f61-bab2-7f57-b801-old-turn"
        let newTurnId = "019e4f61-bab2-7f57-b801-new-turn"
        let startedAt = Date().addingTimeInterval(-8 * 60)
        let newerStartedAt = Date().addingTimeInterval(-2 * 60)
        let olderCompletedAt = Date().addingTimeInterval(-30)
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"\(iso8601String(startedAt.addingTimeInterval(-1)))","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"\(iso8601String(startedAt))","type":"event_msg","payload":{"type":"task_started","turn_id":"\(oldTurnId)"}}
        {"timestamp":"\(iso8601String(newerStartedAt))","type":"event_msg","payload":{"type":"task_started","turn_id":"\(newTurnId)"}}
        {"timestamp":"\(iso8601String(olderCompletedAt))","type":"event_msg","payload":{"type":"task_complete","turn_id":"\(oldTurnId)"}}
        {"timestamp":"\(iso8601String(olderCompletedAt.addingTimeInterval(1)))","type":"event_msg","payload":{"type":"token_count","input_tokens":123,"output_tokens":456}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let clientInfo = SessionClientInfo(
            kind: .codexApp,
            profileID: "codex-app",
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            sessionFilePath: rolloutURL.path
        )
        let fullSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: clientInfo,
            historyMode: .fullHistory
        )
        let summarySnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: clientInfo,
            historyMode: .summary
        )

        XCTAssertEqual(fullSnapshot?.phase, .processing)
        XCTAssertEqual(summarySnapshot?.phase, .processing)
    }

    func testRolloutParserDoesNotKeepIdleThreadProcessingForStaleOrphanedTurn() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019e4f7c-28a4-73b0-83e5-bfe39e82f9c2"
        let orphanTurnId = "019e4f7c-28a4-73b0-83e5-orphan"
        let completedTurnId = "019e4f7c-28a4-73b0-83e5-done"
        let orphanStartedAt = Date().addingTimeInterval(-20 * 60)
        let completedStartedAt = Date().addingTimeInterval(-2 * 60)
        let completedAt = Date().addingTimeInterval(-30)
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"\(iso8601String(orphanStartedAt.addingTimeInterval(-1)))","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"\(iso8601String(orphanStartedAt))","type":"event_msg","payload":{"type":"task_started","turn_id":"\(orphanTurnId)"}}
        {"timestamp":"\(iso8601String(completedStartedAt))","type":"event_msg","payload":{"type":"task_started","turn_id":"\(completedTurnId)"}}
        {"timestamp":"\(iso8601String(completedAt))","type":"event_msg","payload":{"type":"task_complete","turn_id":"\(completedTurnId)"}}
        {"timestamp":"\(iso8601String(completedAt.addingTimeInterval(1)))","type":"event_msg","payload":{"type":"token_count","input_tokens":123,"output_tokens":456}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let clientInfo = SessionClientInfo(
            kind: .codexApp,
            profileID: "codex-app",
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            sessionFilePath: rolloutURL.path
        )
        let fullSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: clientInfo,
            historyMode: .fullHistory
        )
        let summarySnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: clientInfo,
            historyMode: .summary
        )

        XCTAssertEqual(fullSnapshot?.phase, .idle)
        XCTAssertEqual(summarySnapshot?.phase, .idle)
    }

    func testRolloutParserClearsAbortedTurnFromRunningTasks() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019e4f7c-28a4-73b0-83e5-aborted-turn"
        let abortedTurnId = "019e4f7c-28a4-73b0-83e5-aborted"
        let completedTurnId = "019e4f7c-28a4-73b0-83e5-done"
        let abortedStartedAt = Date().addingTimeInterval(-4 * 60)
        let abortedAt = Date().addingTimeInterval(-3 * 60)
        let completedStartedAt = Date().addingTimeInterval(-2 * 60)
        let completedAt = Date().addingTimeInterval(-30)
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"\(iso8601String(abortedStartedAt.addingTimeInterval(-1)))","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"\(iso8601String(abortedStartedAt))","type":"event_msg","payload":{"type":"task_started","turn_id":"\(abortedTurnId)"}}
        {"timestamp":"\(iso8601String(abortedAt))","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"\(abortedTurnId)","reason":"interrupted"}}
        {"timestamp":"\(iso8601String(completedStartedAt))","type":"event_msg","payload":{"type":"task_started","turn_id":"\(completedTurnId)"}}
        {"timestamp":"\(iso8601String(completedAt.addingTimeInterval(-1)))","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"Done."}}
        {"timestamp":"\(iso8601String(completedAt))","type":"event_msg","payload":{"type":"task_complete","turn_id":"\(completedTurnId)","last_agent_message":"Done."}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let clientInfo = SessionClientInfo(
            kind: .codexApp,
            profileID: "codex-app",
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            sessionFilePath: rolloutURL.path
        )
        let fullSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: clientInfo,
            historyMode: .fullHistory
        )
        let summarySnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: clientInfo,
            historyMode: .summary
        )

        XCTAssertEqual(fullSnapshot?.phase, .waitingForInput)
        XCTAssertEqual(summarySnapshot?.phase, .waitingForInput)
    }

    func testRolloutParserDoesNotTreatNamespacedDesktopMCPCallAsApproval() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019e3b03-b1c5-70f9-a877-3f985f7e4011"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-05-18T08:53:52Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/github/CodeIsland","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-05-18T08:53:53Z","type":"response_item","payload":{"type":"function_call","name":"get_app_state","namespace":"mcp__computer_use__","arguments":"{\\"app\\":\\"Ping Island\\"}","call_id":"call_computer_use_approval"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let clientInfo = SessionClientInfo(
            kind: .codexApp,
            profileID: "codex-app",
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            sessionFilePath: rolloutURL.path
        )

        let fullSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/github/CodeIsland",
            clientInfo: clientInfo,
            historyMode: .fullHistory
        )
        let summarySnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/github/CodeIsland",
            clientInfo: clientInfo,
            historyMode: .summary
        )

        for snapshot in [fullSnapshot, summarySnapshot] {
            XCTAssertEqual(snapshot?.phase, .processing)
            XCTAssertNil(snapshot?.intervention)
        }
    }

    func testRolloutParserClosesDesktopMCPCallEndWithoutApproval() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019e3b03-computer-use-ended"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = #"""
        {"timestamp":"2026-05-18T09:21:50Z","type":"session_meta","payload":{"id":"\#(threadId)","cwd":"/Users/ping-island/github/CodeIsland","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-05-18T09:21:51Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-05-18T09:21:52Z","type":"response_item","payload":{"type":"function_call","name":"get_app_state","namespace":"mcp__computer_use__","arguments":"{\"app\":\"Ping Island\"}","call_id":"call_computer_use_allowed"}}
        {"timestamp":"2026-05-18T09:21:53Z","type":"event_msg","payload":{"type":"mcp_tool_call_end","call_id":"call_computer_use_allowed","duration":{"secs":1,"nanos":0},"invocation":{"server":"computer-use","tool":"get_app_state"},"result":{"Ok":{"content":[{"type":"text","text":"Ping Island window visible"}],"isError":false,"_meta":{"codex/telemetry.span.did_trigger_server_user_flow":false}}}}}
        {"timestamp":"2026-05-18T09:21:54Z","type":"event_msg","payload":{"type":"task_complete"}}
        """#
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let clientInfo = SessionClientInfo(
            kind: .codexApp,
            profileID: "codex-app",
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            sessionFilePath: rolloutURL.path
        )

        let fullSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/github/CodeIsland",
            clientInfo: clientInfo,
            historyMode: .fullHistory
        )
        let summarySnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/github/CodeIsland",
            clientInfo: clientInfo,
            historyMode: .summary
        )

        for snapshot in [fullSnapshot, summarySnapshot] {
            let snapshot = try XCTUnwrap(snapshot)
            XCTAssertEqual(snapshot.phase, .idle)
            XCTAssertNil(snapshot.intervention)
            let tool = try XCTUnwrap(snapshot.historyItems.compactMap { item -> ToolCallItem? in
                guard case .toolCall(let tool) = item.type else { return nil }
                return tool.name == "get_app_state" ? tool : nil
            }.first)
            XCTAssertEqual(tool.status, .success)
            XCTAssertEqual(tool.result, "Ping Island window visible")
        }
    }

    func testRolloutParserDoesNotTreatBrowserMCPCallAsApproval() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019e3a5e-browser-mcp-running"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-05-18T09:21:58Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/Desktop/codex","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-05-18T09:21:59Z","type":"response_item","payload":{"type":"function_call","name":"js","namespace":"mcp__node_repl__","arguments":"{\\"title\\":\\"Retest continuous brush after click guard\\"}","call_id":"call_browser_running"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let clientInfo = SessionClientInfo(
            kind: .codexApp,
            profileID: "codex-app",
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            sessionFilePath: rolloutURL.path
        )

        let fullSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Desktop/codex",
            clientInfo: clientInfo,
            historyMode: .fullHistory
        )
        let summarySnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Desktop/codex",
            clientInfo: clientInfo,
            historyMode: .summary
        )

        for snapshot in [fullSnapshot, summarySnapshot] {
            XCTAssertEqual(snapshot?.phase, .processing)
            XCTAssertNil(snapshot?.intervention)
        }
    }

    func testRolloutParserTreatsTurnAbortedAsIdleAndInterruptsRunningTools() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019dc0b1-turn-aborted"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-05-07T03:59:20Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/open_Design","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-05-07T03:59:21Z","type":"event_msg","payload":{"type":"user_message","message":"tail the app log"}}
        {"timestamp":"2026-05-07T03:59:22Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_tail_log","arguments":"{\\"cmd\\":\\"tail -200 /Users/ping-island/Library/Application Support/Codex/log.txt\\"}"}}
        {"timestamp":"2026-05-07T03:59:30Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<turn_aborted> The user interrupted the request."}]}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let clientInfo = SessionClientInfo(
            kind: .codexApp,
            profileID: "codex-app",
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            sessionFilePath: rolloutURL.path
        )

        let fullSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/open_Design",
            clientInfo: clientInfo,
            historyMode: .fullHistory
        )
        let summarySnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/open_Design",
            clientInfo: clientInfo,
            historyMode: .summary
        )

        XCTAssertEqual(fullSnapshot?.phase, .idle)
        XCTAssertEqual(summarySnapshot?.phase, .idle)

        let fullTool = try XCTUnwrap(fullSnapshot?.historyItems.compactMap { item -> ToolCallItem? in
            guard case .toolCall(let tool) = item.type else { return nil }
            return tool.name == "exec_command" ? tool : nil
        }.first)
        let summaryTool = try XCTUnwrap(summarySnapshot?.historyItems.compactMap { item -> ToolCallItem? in
            guard case .toolCall(let tool) = item.type else { return nil }
            return tool.name == "exec_command" ? tool : nil
        }.first)

        XCTAssertEqual(fullTool.status, .interrupted)
        XCTAssertEqual(summaryTool.status, .interrupted)
    }

    func testRolloutParserDoesNotInferCommandApprovalFromEscalatedExecCall() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019dc0b1-command-approval"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-05-04T02:41:20Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-05-04T02:41:21Z","type":"event_msg","payload":{"type":"user_message","message":"copy these files"}}
        {"timestamp":"2026-05-04T02:41:27Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_cp_approval","arguments":"{\\"cmd\\":\\"cp /tmp/source.png /tmp/dest.png\\",\\"sandbox_permissions\\":\\"require_escalated\\",\\"justification\\":\\"Allow Codex to copy the rendered PNG into the target folder?\\"}"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertEqual(snapshot?.phase, .processing)
        XCTAssertNil(snapshot?.intervention)
        XCTAssertEqual(snapshot?.historyItems.last?.id, "call_cp_approval")
        if case .toolCall(let tool) = snapshot?.historyItems.last?.type {
            XCTAssertEqual(tool.status, .running)
        } else {
            XCTFail("Expected command tool call")
        }
    }

    func testRolloutParserSurfacesPendingRequestUserInputCall() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019dc0b1-1b2c-73d8-9d3d-9833ecfc7fb0"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-24T17:59:20Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-04-24T17:59:21Z","type":"event_msg","payload":{"type":"user_message","message":"build a small TodoList sample"}}
        {"timestamp":"2026-04-24T17:59:27Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call_question_1","arguments":"{\\"questions\\":[{\\"header\\":\\"Data\\",\\"id\\":\\"todo_data\\",\\"question\\":\\"TodoList 示例的数据要怎么处理？\\",\\"options\\":[{\\"label\\":\\"内存状态（推荐）\\",\\"description\\":\\"最适合作为简洁示例，刷新或重启后数据丢失。\\"},{\\"label\\":\\"UserDefaults 持久化\\",\\"description\\":\\"更接近可用小功能，但会多出存储和测试细节。\\"}]}]}"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertEqual(snapshot?.phase, .waitingForInput)
        XCTAssertEqual(snapshot?.intervention?.kind, .question)
        XCTAssertEqual(snapshot?.intervention?.metadata["source"], "codex_rollout_request_user_input")
        XCTAssertEqual(snapshot?.intervention?.metadata["responseMode"], "external_only")
        XCTAssertEqual(snapshot?.intervention?.resolvedQuestions.first?.prompt, "TodoList 示例的数据要怎么处理？")
        XCTAssertEqual(snapshot?.intervention?.resolvedQuestions.first?.options.map(\.title), ["内存状态（推荐）", "UserDefaults 持久化"])
    }

    func testRolloutParserTreatsApprovalLikeRequestUserInputAsApproval() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019dc0b1-1b2c-73d8-9d3d-9833ecfc7fb3"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-05-05T17:59:20Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/Aidoku","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-05-05T17:59:21Z","type":"event_msg","payload":{"type":"user_message","message":"检查 Aidoku"}}
        {"timestamp":"2026-05-05T17:59:27Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call_kill_approval","arguments":"{\\"questions\\":[{\\"id\\":\\"approval\\",\\"question\\":\\"要关闭当前 Aidoku 进程，替换成最终编译后的筛选器修复版。\\\\n\\\\nkill 40409\\",\\"options\\":[{\\"label\\":\\"是\\"},{\\"label\\":\\"是，且对于以后续内容开头的命令不再询问 kill 40409\\"},{\\"label\\":\\"否，请告知 Codex 如何调整\\"}]}]}"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Aidoku",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertEqual(snapshot?.phase.isWaitingForApproval, true)
        XCTAssertEqual(snapshot?.intervention?.kind, .approval)
        XCTAssertEqual(snapshot?.intervention?.metadata["semanticRole"], "approval")
        XCTAssertEqual(snapshot?.intervention?.metadata["responseMode"], "external_only")
        XCTAssertEqual(snapshot?.intervention?.resolvedQuestions.first?.options.map(\.title), [
            "是",
            "是，且对于以后续内容开头的命令不再询问 kill 40409",
            "否，请告知 Codex 如何调整"
        ])
    }

    func testRolloutParserClearsRequestUserInputAfterOutput() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019dc0b1-1b2c-73d8-9d3d-9833ecfc7fb1"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-24T17:59:20Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-04-24T17:59:21Z","type":"event_msg","payload":{"type":"user_message","message":"build a small TodoList sample"}}
        {"timestamp":"2026-04-24T17:59:27Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call_question_1","arguments":"{\\"questions\\":[{\\"id\\":\\"todo_data\\",\\"question\\":\\"TodoList 示例的数据要怎么处理？\\",\\"options\\":[{\\"label\\":\\"内存状态（推荐)\\"}]}]}"}}
        {"timestamp":"2026-04-24T17:59:40Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_question_1","output":"{\\"answers\\":{\\"todo_data\\":[\\"内存状态（推荐)\\"]}}"}}
        {"timestamp":"2026-04-24T17:59:45Z","type":"event_msg","payload":{"type":"agent_message","phase":"final","message":"我会用内存状态实现这个示例。"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertNil(snapshot?.intervention)
        XCTAssertEqual(snapshot?.phase, .idle)
        XCTAssertEqual(snapshot?.latestResponseText, "我会用内存状态实现这个示例。")
    }

    func testRolloutParserSummaryModeCompactsResidentHistoryButKeepsActiveTool() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019dc0b1-1b2c-73d8-9d3d-9833ecfc7fb4"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        var lines = [
            """
            {"timestamp":"2026-04-24T17:59:20Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":"desktop"}}
            """,
            """
            {"timestamp":"2026-04-24T17:59:21Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_early_running","arguments":"{\\"cmd\\":\\"long-running-command\\"}"}}
            """
        ]
        for index in 0..<240 {
            lines.append(
                """
                {"timestamp":"2026-04-24T18:00:\(String(format: "%02d", index % 60))Z","type":"event_msg","payload":{"type":"agent_message","phase":"final","message":"message \(index)"}}
                """
            )
        }
        try lines.joined(separator: "\n").write(to: rolloutURL, atomically: true, encoding: .utf8)

        let compactSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            ),
            historyMode: .summary
        )
        let fullSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            ),
            historyMode: .fullHistory
        )

        XCTAssertEqual(compactSnapshot?.isHistoryCompact, true)
        XCTAssertEqual(fullSnapshot?.isHistoryCompact, false)
        XCTAssertEqual(fullSnapshot?.historyItems.count, 241)
        XCTAssertLessThan(compactSnapshot?.historyItems.count ?? 0, fullSnapshot?.historyItems.count ?? 0)
        XCTAssertTrue(compactSnapshot?.historyItems.contains(where: { $0.id == "call_early_running" }) == true)
    }

    func testRolloutParserExtractsCodexSubagentMetadataFromSessionMeta() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let parentThreadId = "019da119-db3a-7532-8355-5ba0ecf56640"
        let threadId = "019da11a-353a-79e3-8a52-5f051d2e00a9"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-18T14:59:02Z","type":"session_meta","payload":{"id":"\(threadId)","forked_from_id":"\(parentThreadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(parentThreadId)","depth":1,"agent_nickname":"Kierkegaard","agent_role":"explorer"}}},"agent_nickname":"Kierkegaard","agent_role":"explorer"}}
        {"timestamp":"2026-04-18T14:59:03Z","type":"event_msg","payload":{"type":"user_message","message":"inspect the repo"}}
        {"timestamp":"2026-04-18T14:59:05Z","type":"event_msg","payload":{"type":"agent_message","phase":"final","message":"I checked the repo entrypoints."}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertEqual(snapshot?.parentThreadId, parentThreadId)
        XCTAssertEqual(snapshot?.subagentDepth, 1)
        XCTAssertEqual(snapshot?.subagentNickname, "Kierkegaard")
        XCTAssertEqual(snapshot?.subagentRole, "explorer")
        XCTAssertEqual(snapshot?.isSubagent, true)
    }

    private func iso8601String(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
