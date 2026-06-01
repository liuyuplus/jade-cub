import Foundation

enum ChatHistoryRetentionPolicy {
    nonisolated static let maxResidentItems = 180
    nonisolated static let maxResidentTextLength = 12_000
    nonisolated static let maxResidentToolResultLength = 8_000
    nonisolated static let maxResidentToolInputValueLength = 2_000

    nonisolated static func compactForResidentStorage(_ items: [ChatHistoryItem]) -> [ChatHistoryItem] {
        guard items.count > maxResidentItems else {
            return items.map(compactItem)
        }

        let alwaysKeepIDs = Set(items.compactMap { item -> String? in
            guard case .toolCall(let tool) = item.type else { return nil }
            return isActiveTool(tool) ? item.id : nil
        })

        let tailStart = max(0, items.count - maxResidentItems)
        let retained = items.enumerated().compactMap { index, item -> ChatHistoryItem? in
            if index >= tailStart || alwaysKeepIDs.contains(item.id) {
                return compactItem(item)
            }
            return nil
        }

        return retained.sorted { $0.timestamp < $1.timestamp }
    }

    nonisolated private static func compactItem(_ item: ChatHistoryItem) -> ChatHistoryItem {
        switch item.type {
        case .user(let text):
            return ChatHistoryItem(id: item.id, type: .user(truncated(text, limit: maxResidentTextLength)), timestamp: item.timestamp)
        case .assistant(let text):
            return ChatHistoryItem(id: item.id, type: .assistant(truncated(text, limit: maxResidentTextLength)), timestamp: item.timestamp)
        case .thinking(let text):
            return ChatHistoryItem(id: item.id, type: .thinking(truncated(text, limit: maxResidentTextLength)), timestamp: item.timestamp)
        case .toolCall(let tool):
            return ChatHistoryItem(id: item.id, type: .toolCall(compactTool(tool)), timestamp: item.timestamp)
        case .interrupted:
            return item
        }
    }

    nonisolated private static func compactTool(_ tool: ToolCallItem) -> ToolCallItem {
        ToolCallItem(
            name: tool.name,
            input: tool.input.mapValues { truncated($0, limit: maxResidentToolInputValueLength) },
            status: tool.status,
            result: tool.result.map { truncated($0, limit: maxResidentToolResultLength) },
            structuredResult: isActiveTool(tool) ? tool.structuredResult : nil,
            subagentTools: tool.subagentTools
        )
    }

    nonisolated private static func isActiveTool(_ tool: ToolCallItem) -> Bool {
        tool.status == .running || tool.status == .waitingForApproval
    }

    nonisolated private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n...[truncated]"
    }
}
