import Foundation
import XCTest
@testable import Ping_Island

final class CodexAppServerMonitorTests: XCTestCase {
    func testWebSocketPayloadsEncodeAsTextJSON() throws {
        let message = try CodexAppServerMonitor.webSocketTextMessage(from: [
            "jsonrpc": "2.0",
            "id": "1",
            "method": "initialize",
            "params": [
                "capabilities": [
                    "experimentalApi": true
                ],
                "clientInfo": [
                    "name": "Island",
                    "title": "Island",
                    "version": "0.0.4"
                ]
            ]
        ])

        let data = try XCTUnwrap(message.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["id"] as? String, "1")
        XCTAssertEqual(json["method"] as? String, "initialize")

        let params = try XCTUnwrap(json["params"] as? [String: Any])
        let clientInfo = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(clientInfo["name"] as? String, "Island")
    }

    func testStdioRequestPayloadOmitsJSONRPCVersion() throws {
        let payload = CodexAppServerMonitor.appServerRequestPayload(
            id: "1",
            method: "initialize",
            params: [
                "capabilities": [
                    "experimentalApi": true
                ]
            ],
            includeJSONRPCVersion: false
        )

        XCTAssertNil(payload["jsonrpc"])
        XCTAssertEqual(payload["id"] as? String, "1")
        XCTAssertEqual(payload["method"] as? String, "initialize")
    }

    func testPrefersRolloutSnapshotForNotLoadedDesktopThread() throws {
        let clientInfo = SessionClientInfo(
            kind: .codexApp,
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            sessionFilePath: "/tmp/rollout-thread.jsonl"
        )

        XCTAssertTrue(CodexAppServerMonitor.shouldPreferRolloutSnapshot(
            appServerPhase: .idle,
            intervention: nil,
            status: ["type": "notLoaded"],
            clientInfo: clientInfo
        ))
    }

    func testDoesNotPreferRolloutSnapshotOverActiveAppServerStatus() throws {
        let clientInfo = SessionClientInfo(
            kind: .codexApp,
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            sessionFilePath: "/tmp/rollout-thread.jsonl"
        )

        XCTAssertFalse(CodexAppServerMonitor.shouldPreferRolloutSnapshot(
            appServerPhase: .processing,
            intervention: nil,
            status: ["type": "active"],
            clientInfo: clientInfo
        ))
    }

    func testDoesNotPreferRolloutSnapshotOverFailureStatus() throws {
        let clientInfo = SessionClientInfo(
            kind: .codexApp,
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            sessionFilePath: "/tmp/rollout-thread.jsonl"
        )

        XCTAssertFalse(CodexAppServerMonitor.shouldPreferRolloutSnapshot(
            appServerPhase: .idle,
            intervention: nil,
            status: [
                "type": "systemError",
                "message": "The Internet connection appears to be offline."
            ],
            clientInfo: clientInfo
        ))
    }

    func testCodexStatusRecognizesSystemErrorAsFailure() throws {
        let failure = try XCTUnwrap(CodexAppServerMonitor.failureStatusInfo(from: [
            "type": "systemError",
            "message": "The Internet connection appears to be offline."
        ]))

        XCTAssertTrue(failure.eventID.hasPrefix("codex-status-systemerror-"))
        XCTAssertEqual(failure.reason, "The Internet connection appears to be offline.")
    }

    func testExtractsThreadIdFromRolloutFileName() throws {
        XCTAssertEqual(
            CodexAppServerMonitor.threadIdFromRolloutFileName(
                "rollout-2026-05-18T14-02-48-019e39ae-0d1c-70c3-a7af-feef6265735f.jsonl"
            ),
            "019e39ae-0d1c-70c3-a7af-feef6265735f"
        )
        XCTAssertNil(CodexAppServerMonitor.threadIdFromRolloutFileName("session.jsonl"))
    }

    func testGuardianReviewInterventionMapsMcpToolApprovalToExternalReminder() throws {
        let intervention = try XCTUnwrap(
            CodexAppServerMonitor.guardianReviewIntervention(from: [
                "threadId": "thread-1",
                "targetItemId": "item-1",
                "review": [
                    "status": "inProgress"
                ],
                "action": [
                    "type": "mcpToolCall",
                    "server": "omx_state",
                    "toolName": "state_list_active"
                ]
            ])
        )

        XCTAssertEqual(intervention.kind, .question)
        XCTAssertEqual(intervention.title, "MCP Tool Approval Needed")
        XCTAssertEqual(
            intervention.message,
            "Allow the omx_state MCP server to run tool \"state_list_active\"?"
        )
        XCTAssertEqual(intervention.metadata["responseMode"], "external_only")
        XCTAssertEqual(intervention.metadata["source"], "guardian_review")
    }
}
