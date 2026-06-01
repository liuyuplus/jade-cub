//
//  SessionPhaseHelpers.swift
//  PingIsland
//
//  Helper functions for session phase display
//

import SwiftUI

struct SessionPhaseHelpers {
    /// Get color for session phase
    static func phaseColor(for phase: SessionPhase) -> Color {
        switch phase {
        case .waitingForApproval:
            return TerminalColors.amber
        case .waitingForInput:
            return TerminalColors.green
        case .processing:
            return TerminalColors.cyan
        case .compacting:
            return TerminalColors.magenta
        case .idle, .ended:
            return TerminalColors.dim
        }
    }

    /// Get description for session phase
    static func phaseDescription(for phase: SessionPhase) -> String {
        switch phase {
        case .waitingForApproval(let ctx):
            return "Waiting for approval: \(ctx.toolName)"
        case .waitingForInput:
            return "Ready for input"
        case .processing:
            return "Processing..."
        case .compacting:
            return "Compacting context..."
        case .idle:
            return "Idle"
        case .ended:
            return "Ended"
        }
    }

    /// Format time ago string
    static func timeAgo(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    static func timeBadgeLabel(for date: Date, now: Date = Date()) -> String {
        let value = timeAgo(date, now: now)
        return value == "now" ? "<1m" : value
    }

    static func elapsedBadgeLabel(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 {
            let minutes = seconds / 60
            let remainder = seconds % 60
            return "\(minutes)m\(remainder)s"
        }
        return "\(seconds / 3600)h"
    }

    static func activityBadgeLabel(for session: SessionState, now: Date = Date()) -> String {
        switch session.phase {
        case .processing, .compacting:
            if let lastUserMessageDate = session.lastUserMessageDate {
                return elapsedBadgeLabel(since: lastUserMessageDate, now: now)
            }
            return elapsedBadgeLabel(since: session.lastActivity, now: now)
        case .waitingForApproval:
            return timeBadgeLabel(for: session.attentionRequestedAt ?? session.lastActivity, now: now)
        case .waitingForInput, .idle, .ended:
            return timeBadgeLabel(for: session.lastActivity, now: now)
        }
    }
}
