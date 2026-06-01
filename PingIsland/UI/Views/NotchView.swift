//
//  NotchView.swift
//  PingIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

/// Keeps the compact center message slightly narrower than the full center slot
/// so the closed notch matches the tighter visual balance used elsewhere.
private let compactCenterContentInset: CGFloat = 14

struct OpenedPanelContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NotchView: View {
    private static let temporaryReminderMuteDuration: TimeInterval = 10 * 60
    private static let startupDetachmentHintDelay: TimeInterval = 1.8
    private static let detachmentHintRetryDelay: TimeInterval = 0.75
    private static let notificationSoundFreshnessWindow: TimeInterval = 90
    private static let closedProcessingFreshnessWindow: TimeInterval = 10 * 60

    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var sessionMonitor: SessionMonitor
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var shelfStore = ShelfStore.shared
    @ObservedObject private var musicStore = MusicNowPlayingStore.shared
    @ObservedObject private var obsidianTaskStore = ObsidianDailyTaskStore.shared
    @State private var manualAttentionTracker = SessionManualAttentionTracker()
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var hasPrimedSoundTransitions: Bool = false
    @State private var previousProcessingIds: Set<String> = []
    @State private var previousAttentionSoundIds: Set<String> = []
    @State private var previousCompletionSoundIds: Set<String> = []
    @State private var previousTaskErrorIds: Set<String> = []
    @State private var previousResourceLimitIds: Set<String> = []
    @State private var previousCompletionNotificationPhases: [String: SessionPhase] = [:]
    @State private var completionNotificationQueue: [SessionCompletionNotification] = []
    @State private var presentedCompletionNotificationKeys: Set<String> = []
    @State private var acknowledgedCompletionNotificationKeys: Set<String> = []
    @State private var activeCompletionNotification: SessionCompletionNotification?
    @State private var completionNotificationDismissWorkItem: DispatchWorkItem?
    @State private var shouldDismissCompletionNotificationOnHoverExit: Bool = false
    @State private var isShowingDetachmentHint: Bool = false
    @State private var isShelfDropTargeted: Bool = false
    @State private var detachmentHintDismissWorkItem: DispatchWorkItem?
    @State private var detachmentHintPresentationWorkItem: DispatchWorkItem?

    @Namespace private var activityNamespace

    private let petIconSize: CGFloat = 28

    /// Whether any tracked session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { isClosedThinkingSession($0) }
    }

    /// Whether any tracked session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.needsApprovalResponse }
    }

    /// Whether any session needs explicit human intervention (for example multi-choice questions).
    private var hasHumanIntervention: Bool {
        sessionMonitor.instances.contains {
            $0.phase == .waitingForInput && $0.intervention != nil
        }
    }

    /// Whether any session requires a user decision right now.
    private var hasManualAttentionIndicator: Bool {
        sessionMonitor.instances.contains {
            $0.needsApprovalResponse || $0.intervention != nil
        }
    }

    private var activeSessions: [SessionState] {
        sessionMonitor.instances.filter { isClosedThinkingSession($0) }
    }

    private var countedClosedSessions: [SessionState] {
        sessionMonitor.instances.filter(isClosedCountedSession(_:))
    }

    private var activeSessionCount: Int {
        Set(countedClosedSessions.map(closedCountIdentity(for:))).count
    }

    private var shouldShowClosedTaskProgress: Bool {
        viewModel.status != .opened
            && !hasManualAttentionIndicator
            && closedActivityState != .thinking
            && obsidianTaskStore.snapshot != nil
    }

    private var usageSummaryProviders: [UsageSummaryProvider] {
        UsageSummaryPresenter.providers(
            claudeSnapshot: sessionMonitor.claudeUsageSnapshot,
            codexSnapshot: sessionMonitor.codexUsageSnapshot,
            mode: openedHeaderUsageValueMode,
            locale: settings.locale
        )
    }

    private var openedHeaderUsageValueMode: UsageValueMode {
        isOnBuiltinDisplay ? .remaining : settings.usageValueMode
    }

    private var openedHeaderUsageDisplayStyle: UsageSummaryStripView.DisplayStyle {
        isOnBuiltinDisplay ? .preferredBattery : .numeric
    }

    private var isOnBuiltinDisplay: Bool {
        screenSelector.selectedScreen?.isBuiltinDisplay == true
    }

    private var shouldShowOpenedHeaderUsage: Bool {
        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: triggerForCurrentPresentation,
            contentType: viewModel.contentType,
            sessions: sessionMonitor.instances,
            activeCompletionNotification: activeCompletionNotification
        )

        return UsageSummaryPresenter.shouldShowSummary(
            for: route,
            showUsage: settings.showUsage,
            providers: usageSummaryProviders
        )
    }

    private var shouldHideForIdleState: Bool {
        settings.autoHideWhenIdle
            && activeSessions.isEmpty
            && !hasPendingPermission
            && !hasHumanIntervention
            && !hasCompletedReadyState
            && activeCompletionNotification == nil
    }

    /// Most recently active live session that has a hook message we can surface in the compact notch.
    private var latestHookMessageSession: SessionState? {
        latestHookMessageSession(from: sessionMonitor.instances)
    }

    private var closedCenterMessage: String? {
        guard settings.notchDisplayMode == .detailed else { return nil }
        return latestHookMessageSession?.compactHookMessage
    }

    /// Whether any tracked session completed and is ready for the user to continue.
    private var hasCompletedReadyState: Bool {
        guard !isAnyProcessing else { return false }

        let now = Date()
        let displayDuration: TimeInterval = 8

        return sessionMonitor.instances.contains { session in
            guard SessionCompletionStateEvaluator.isCompletedReadySession(session) else { return false }
            guard !hasAcknowledgedCompletionNotification(for: session, kind: .completed) else { return false }
            if let enteredAt = waitingForInputTimestamps[session.stableId] {
                return now.timeIntervalSince(enteredAt) < displayDuration
            }
            return now.timeIntervalSince(session.lastActivity) < displayDuration
        }
    }

    private var closedIndicatorTone: NotchIndicatorTone {
        if hasPendingPermission {
            return .warning
        }
        if hasHumanIntervention {
            return .intervention
        }
        return .normal
    }

    private var closedActivityState: ClosedNotchActivityState {
        if hasPendingPermission {
            return .approval
        }
        if hasHumanIntervention {
            return .question
        }
        if isAnyProcessing {
            return .thinking
        }
        if hasCompletedReadyState {
            return .finished
        }
        return .idle
    }

    private var representativeClosedSession: SessionState? {
        if let attention = sessionMonitor.instances
            .filter({ $0.needsManualAttention })
            .sorted(by: { ($0.attentionRequestedAt ?? $0.lastActivity) > ($1.attentionRequestedAt ?? $1.lastActivity) })
            .first {
            return attention
        }

        if let active = sessionMonitor.instances
            .filter({ isClosedThinkingSession($0) })
            .sorted(by: { $0.lastActivity > $1.lastActivity })
            .first {
            return active
        }

        return sessionMonitor.instances
            .sorted(by: { $0.lastActivity > $1.lastActivity })
            .first
    }

    private var preferredShortcutSession: SessionState? {
        representativeClosedSession ?? latestHookMessageSession
    }

    private var closedMascotKind: MascotKind {
        settings.mascotKind(for: latestMascotSourceSession(from: sessionMonitor.instances)?.mascotClient)
    }

    private var completionNotificationMascotKind: MascotKind {
        let client = activeCompletionNotification?.session.mascotClient
            ?? latestMascotSourceSession(from: sessionMonitor.instances)?.mascotClient
        return settings.mascotKind(for: client)
    }

    private var completionNotificationMascotStatus: MascotStatus {
        activeCompletionNotification?.kind.mascotStatus ?? .idle
    }

    private var areReminderNotificationsSuppressed: Bool {
        settings.areNotificationsMutedTemporarily
    }

    private var temporaryMuteButtonHelpText: String {
        guard let mutedUntil = settings.temporarilyMuteNotificationsUntil,
              AppSettings.isNotificationMuteActive(until: mutedUntil) else {
            return AppLocalization.string("10 分钟静音 Ping Island 通知和提示音")
        }

        return AppLocalization.format(
            "Ping Island 通知和提示音已静音至 %@，点击恢复",
            formattedTemporaryMuteTime(mutedUntil)
        )
    }

    private var closedMascotStatus: MascotStatus {
        if viewModel.isDetachmentGestureActive {
            return .dragging
        }

        switch closedActivityState {
        case .idle:
            break
        case .thinking:
            return .working
        case .finished:
            return .completed
        case .approval, .question:
            return .warning
        }

        return MascotStatus.closedNotchStatus(
            representativePhase: representativeClosedPhaseForMascot,
            hasPendingPermission: hasPendingPermission,
            hasHumanIntervention: hasHumanIntervention
        )
    }

    private var representativeClosedPhaseForMascot: SessionPhase? {
        guard let representativeClosedSession else { return nil }
        if isClosedThinkingSession(representativeClosedSession) {
            return representativeClosedSession.phase
        }
        if representativeClosedSession.needsManualAttention {
            return representativeClosedSession.phase
        }
        return nil
    }

    private func latestHookMessageSession(from instances: [SessionState]) -> SessionState? {
        instances
            .filter { $0.phase != .ended && $0.compactHookMessage != nil }
            .sorted { $0.lastActivity > $1.lastActivity }
            .first
    }

    private func latestMascotSourceSession(from instances: [SessionState]) -> SessionState? {
        IslandMascotResolver.sourceSession(from: instances)
    }

    private func formattedTemporaryMuteTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = settings.locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        viewModel.closedSize
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width
    }

    private var closedInnerWidth: CGFloat {
        max(0, closedContentWidth - (cornerRadiusInsets.closed.bottom * 2))
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // Animation springs
    private let openAnimation = Animation.smooth(duration: 0.34)
    private let closeAnimation = Animation.smooth(duration: 0.22)

    // MARK: - Body

    var body: some View {
        instrumentedBody
    }

    private var presentedBody: some View {
        bodyContent
            .offset(y: viewModel.closedPresentationOffsetY)
            .opacity(isVisible ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .preferredColorScheme(.dark)
    }

    private var lifecycleBody: some View {
        presentedBody
            .onAppear {
                if !SessionMonitor.isRunningUnderXCTest {
                    sessionMonitor.startMonitoring()
                }
                viewModel.updateIdleAutoHiddenState(hasVisibleSessionActivity: !shouldHideForIdleState)
                isVisible = !viewModel.shouldHideWindowPresentation
                viewModel.setManualAttentionActive(hasManualAttentionIndicator)
                handleProcessingChange()
                handleManualAttentionChange(sessionMonitor.instances)
                primeCompletionNotificationTracking(sessionMonitor.instances)
                scheduleDetachmentHintPresentationIfNeeded(delay: Self.startupDetachmentHintDelay)
            }
            .onDisappear {
                cancelScheduledDetachmentHintPresentation()
            }
            .onChange(of: viewModel.status) { oldStatus, newStatus in
                handleStatusChange(from: oldStatus, to: newStatus)
            }
    }

    private var settingsAwareBody: some View {
        lifecycleBody
            .onChange(of: settings.autoOpenCompletionPanel) { _, isEnabled in
                if !isEnabled {
                    removeCompletionNotifications(
                        matching: { $0 == .completed || $0 == .ended },
                        keepPanelOpen: true
                    )
                } else {
                    maybePresentNextCompletionNotification()
                }
            }
            .onChange(of: settings.autoOpenCompactedNotificationPanel) { _, isEnabled in
                if !isEnabled {
                    removeCompletionNotifications(
                        matching: { $0 == .compacted },
                        keepPanelOpen: true
                    )
                } else {
                    maybePresentNextCompletionNotification()
                }
            }
            .onChange(of: settings.temporarilyMuteNotificationsUntil) { _, mutedUntil in
                guard AppSettings.isNotificationMuteActive(until: mutedUntil) else { return }
                clearCompletionNotifications(keepPanelOpen: true)
                if viewModel.openReason == .notification {
                    viewModel.exitChat()
                }
            }
            .onChange(of: settings.autoHideWhenIdle) { _, _ in
                handleProcessingChange()
            }
    }

    private var contentTypeAwareBody: some View {
        settingsAwareBody
            .onChange(of: viewModel.contentType.id) { _, _ in
                acknowledgeCompletionNotificationsAlreadyInView(sessionMonitor.instances, includeSessionList: true)
                maybePresentNextCompletionNotification()
            }
            .onReceive(sessionMonitor.$instances) { instances in
                viewModel.setManualAttentionActive(
                    instances.contains { $0.needsApprovalResponse || $0.intervention != nil }
                )
                handleProcessingChange()
                handleSessionSoundTransitions(instances)
                handleManualAttentionChange(instances)
                handleWaitingForInputChange(instances)
                handleCompletionNotificationChange(instances)
            }
    }

    private var visibilityAwareBody: some View {
        contentTypeAwareBody
            .onChange(of: viewModel.isFullscreenEdgeRevealActive) { _, isActive in
                if isActive && viewModel.status != .opened {
                    isVisible = false
                } else {
                    handleProcessingChange()
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: viewModel.isFullscreenBrowserHiddenActive) { _, isActive in
                if isActive {
                    isVisible = false
                } else {
                    handleProcessingChange()
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: viewModel.isIdleAutoHiddenActive) { _, isHidden in
                if isHidden && viewModel.status != .opened {
                    isVisible = false
                } else {
                    handleProcessingChange()
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: viewModel.presentationMode) { _, _ in
                scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
            }
            .onChange(of: viewModel.isFullscreenPhysicalNotchCompactActive) { _, isActive in
                if !isActive {
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: settings.surfaceMode) { _, _ in
                scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
            }
            .onChange(of: settings.notchDetachmentHintPending) { _, isPending in
                if isPending {
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                } else {
                    cancelScheduledDetachmentHintPresentation()
                }
            }
    }

    private var shortcutAwareBody: some View {
        visibilityAwareBody
            .onReceive(NotificationCenter.default.publisher(for: .pingIslandOpenActiveSessionShortcut)) { _ in
                handleOpenActiveSessionShortcut()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pingIslandOpenSessionListShortcut)) { _ in
                handleOpenSessionListShortcut()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pingIslandPresentNotchDetachmentHint)) { _ in
                presentDetachmentHintIfNeeded(force: true)
            }
            .onPreferenceChange(OpenedPanelContentHeightPreferenceKey.self) { height in
                guard viewModel.status == .opened else {
                    viewModel.updateOpenedMeasuredHeight(nil)
                    return
                }

                switch viewModel.contentType {
                case .instances, .shelf, .music:
                    let effectiveHeight = activeCompletionNotification == nil
                        ? height
                        : max(height, SessionCompletionNotificationView.minimumContentHeight)
                    let measuredHeight = height > 0
                        ? closedNotchSize.height + effectiveHeight + 12
                        : nil
                    viewModel.updateOpenedMeasuredHeight(measuredHeight)
                case .chat:
                    viewModel.updateOpenedMeasuredHeight(nil)
                }
            }
    }

    private var instrumentedBody: some View {
        shortcutAwareBody
            .onAppear {
                musicStore.start()
                obsidianTaskStore.start()
            }
    }

    private var bodyContent: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                styledNotchLayout
            }

            if isShowingDetachmentHint {
                NotchDetachmentHintView()
                    .offset(x: -22, y: 28)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)),
                            removal: .opacity.animation(.easeOut(duration: 0.18))
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private var styledNotchLayout: some View {
        let isOpened = viewModel.status == .opened
        let horizontalInset = isOpened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.bottom
        let shadowColor = (isOpened || isHovering) ? Color.black.opacity(0.7) : .clear

        return notchLayout
            .frame(maxWidth: isOpened ? notchSize.width : nil, alignment: .top)
            .padding(.horizontal, horizontalInset)
            .padding([.horizontal, .bottom], isOpened ? 12 : 0)
            .background(.black)
            .clipShape(currentNotchShape)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.black)
                    .frame(height: 1)
                    .padding(.horizontal, topCornerRadius)
            }
            .overlay {
                if isShelfDropTargeted {
                    currentNotchShape
                        .stroke(Color.white.opacity(0.36), lineWidth: 1)
                        .padding(.horizontal, 1)
                }
            }
            .shadow(color: shadowColor, radius: 6)
            .frame(
                maxWidth: isOpened ? notchSize.width : nil,
                maxHeight: isOpened ? notchSize.height : nil,
                alignment: .top
            )
            .animation(isOpened ? openAnimation : closeAnimation, value: viewModel.status)
            .animation(viewModel.closedNotchResizeAnimation, value: notchSize)
            .animation(.smooth, value: activityCoordinator.expandingActivity)
            .animation(.smooth, value: hasPendingPermission)
            .animation(.smooth, value: hasHumanIntervention)
            .animation(.smooth, value: hasCompletedReadyState)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                    isHovering = hovering
                }
            }
            .onChange(of: isShelfDropTargeted) { _, isTargeted in
                if isTargeted {
                    viewModel.presentShelf(reason: .click)
                }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isShelfDropTargeted) { providers in
                viewModel.presentShelf(reason: .click)
                return shelfStore.addItemProviders(providers)
            }
            .onTapGesture {
                if !isOpened {
                    presentDefaultPanel(reason: .click)
                }
            }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .claude
    }

    /// Whether to show the expanded closed state (processing, pending permission, or waiting for input)
    private var showClosedActivity: Bool {
        isProcessing || closedActivityState != .idle
    }

    private var shouldShowClosedMusicNotes: Bool {
        viewModel.status != .opened
            && !viewModel.isDetachmentGestureActive
            && closedActivityState == .idle
            && musicStore.track?.isPlaying == true
    }

    /// Keep the closed notch footprint stable and always show the leading icon.
    private var showsClosedLeadingIcon: Bool {
        viewModel.status != .opened || showClosedActivity
    }

    /// In fullscreen on physical-notch displays, the closed state should visually
    /// collapse back to the native macOS notch with no Island content shown.
    private var shouldHideClosedContent: Bool {
        viewModel.usesPhysicalNotchClosedPresentation && viewModel.status != .opened
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains pet and spinner that persist across states
            headerRow
                .frame(
                    width: viewModel.status == .opened ? notchSize.width - 24 : nil,
                    height: max(24, closedNotchSize.height),
                    alignment: .leading
                )
                .zIndex(1)

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24) // Fixed width to prevent reflow
                    .zIndex(0)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        Group {
            if shouldHideClosedContent {
                Color.clear
                    // Preserve the native-notch footprint without letting the
                    // empty closed state expand across the whole window.
                    .frame(width: closedInnerWidth, height: closedNotchSize.height)
            } else {
                HStack(spacing: 0) {
                    // Left side - pet always visible while closed.
                    if viewModel.status != .opened && showsClosedLeadingIcon {
                        HStack(spacing: 7) {
                            ZStack(alignment: .leading) {
                                MascotView(
                                    kind: closedMascotKind,
                                    status: closedMascotStatus,
                                    size: petIconSize,
                                    showsIdleSleepOverlay: !shouldShowClosedMusicNotes,
                                    codexExpression: shouldShowClosedMusicNotes ? .music : .automatic
                                )
                                .matchedGeometryEffect(id: "pet", in: activityNamespace, isSource: showsClosedLeadingIcon)
                                .frame(width: sideWidth)
                                .offset(x: closedMascotHeadLeftShift)
                                .zIndex(1)

                                if shouldShowClosedMusicNotes {
                                    ClosedMusicNotesIndicator(size: petIconSize)
                                        .offset(
                                            x: closedMusicIndicatorOffset.width,
                                            y: closedMusicIndicatorOffset.height
                                        )
                                        .zIndex(2)
                                }

                                if closedActivityState != .idle {
                                    ClosedNotchStatusIndicator(state: closedActivityState, alignment: .leading)
                                        .frame(width: closedStatusIndicatorWidth, alignment: .leading)
                                        .offset(
                                            x: closedStatusIndicatorOverlayOffset.width,
                                            y: closedStatusIndicatorOverlayOffset.height
                                        )
                                        .allowsHitTesting(false)
                                        .zIndex(2)
                                }
                            }
                            .frame(
                                width: sideWidth + closedStatusIndicatorWidth + closedMusicIndicatorWidth,
                                height: petIconSize,
                                alignment: .leading
                            )
                            .offset(x: closedMascotStatusSeparationShift)
                        }
                        .frame(width: closedLeadingWidth, alignment: .leading)
                        .offset(x: closedLeadingContentLeftShift)
                    }

                    // Center content
                    if viewModel.status == .opened {
                        // Opened: show header content
                        openedHeaderContent
                    } else {
                        closedCenterContent
                    }

                    // Right side - in the closed state show session count by default.
                    // Attention is already represented by the main status indicator.
                    if viewModel.status != .opened {
                        ZStack {
                            if closedActivityState == .thinking, activeSessionCount > 0 {
                                SessionCountIndicator(
                                    count: activeSessionCount,
                                    rightShift: closedSessionCountRightShift
                                )
                            } else if let snapshot = obsidianTaskStore.snapshot {
                                ObsidianTaskProgressIndicator(
                                    snapshot: snapshot,
                                    rightShift: closedTaskProgressRightShift
                                )
                            }
                        }
                        .frame(width: closedTrailingWidth, alignment: .trailing)
                    }
                }
            }
        }
        .frame(height: closedNotchSize.height)
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 10
    }

    private var closedLeadingContentLeftShift: CGFloat {
        0
    }

    private var closedStatusIndicatorLeftShift: CGFloat {
        viewModel.hasPhysicalNotch ? -10 : 0
    }

    private var closedMascotHeadLeftShift: CGFloat {
        viewModel.hasPhysicalNotch ? -petIconSize * 0.34 : 0
    }

    private var closedStatusIndicatorOverlayOffset: CGSize {
        let notchAvoidanceShift: CGFloat = viewModel.hasPhysicalNotch ? -petIconSize * 0.34 : 0

        switch closedActivityState {
        case .thinking:
            return CGSize(width: petIconSize * 0.92 + notchAvoidanceShift, height: petIconSize * 0.02)
        case .finished:
            return CGSize(width: petIconSize * 0.86 + notchAvoidanceShift, height: -petIconSize * 0.10)
        case .approval, .question:
            return CGSize(width: petIconSize * 0.84 + notchAvoidanceShift, height: -petIconSize * 0.08)
        case .idle:
            return .zero
        }
    }

    private var closedMusicIndicatorOffset: CGSize {
        let notchAvoidanceShift: CGFloat = viewModel.hasPhysicalNotch ? -petIconSize * 0.26 : 0
        return CGSize(
            width: petIconSize * 0.58 + notchAvoidanceShift,
            height: -petIconSize * 0.18
        )
    }

    private var closedMascotStatusSeparationShift: CGFloat {
        0
    }

    private var closedLeadingWidth: CGFloat {
        sideWidth + closedStatusIndicatorWidth + closedMusicIndicatorWidth + closedMascotLeftReserve
    }

    private var closedMascotLeftReserve: CGFloat {
        viewModel.hasPhysicalNotch ? abs(closedMascotHeadLeftShift) : 0
    }

    private var closedMusicIndicatorWidth: CGFloat {
        shouldShowClosedMusicNotes ? petIconSize * 0.82 : 0
    }

    private var closedTrailingWidth: CGFloat {
        if shouldShowClosedTaskProgress {
            return max(34, sideWidth + 4)
        }

        guard viewModel.hasPhysicalNotch, viewModel.status != .opened else {
            return sideWidth
        }

        return max(18, sideWidth - 12)
    }

    private var closedSessionCountRightShift: CGFloat {
        viewModel.hasPhysicalNotch ? -18 : -8
    }

    private var closedTaskProgressRightShift: CGFloat {
        viewModel.hasPhysicalNotch ? -14 : -6
    }

    private var closedCenterWidth: CGFloat {
        max(0, closedInnerWidth - closedLeadingWidth - closedTrailingWidth)
    }

    private var compactCenterContentWidth: CGFloat {
        max(0, closedCenterWidth - compactCenterContentInset)
    }

    private var closedStatusIndicatorWidth: CGFloat {
        guard viewModel.status != .opened else { return 0 }

        switch closedActivityState {
        case .idle:
            return 0
        case .thinking:
            return 44
        case .finished:
            return 24
        case .approval, .question:
            return 24
        }
    }

    @ViewBuilder
    private var closedCenterContent: some View {
        HStack {
            if closedActivityState == .idle, let message = closedCenterMessage {
                Text(message)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(showClosedActivity ? 0.9 : 0.74))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 6)
                    .frame(width: compactCenterContentWidth, alignment: .center)
                    .allowsHitTesting(false)
                    .accessibilityLabel("最新 hooks 消息")
            } else {
                // Preserve the compact notch footprint when there is no hook text to show.
                Color.clear
                    .frame(width: compactCenterContentWidth)
            }
        }
        .frame(width: closedCenterWidth, alignment: .center)
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        ZStack(alignment: .trailing) {
            openedHeaderTabControls
                .frame(maxWidth: .infinity, alignment: .leading)

            openedHeaderUtilityControls
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .frame(width: max(0, notchSize.width - 24), alignment: .leading)
    }

    @ViewBuilder
    private var openedHeaderLeadingStatus: some View {
        HStack(spacing: 8) {
            if viewModel.openReason == .notification,
               activeCompletionNotification != nil {
                MascotView(
                    kind: completionNotificationMascotKind,
                    status: completionNotificationMascotStatus,
                    size: petIconSize
                )
            }

            openedHeaderContextAccessory

            if let snapshot = obsidianTaskStore.snapshot,
               shouldShowOpenedTaskProgressAccessory {
                OpenedObsidianTaskAccessory(snapshot: snapshot) {
                    obsidianTaskStore.openTodayNote()
                }
            }
        }
        .frame(minWidth: 0, alignment: .leading)
    }

    @ViewBuilder
    private var openedHeaderContextAccessory: some View {
        switch viewModel.contentType {
        case .instances, .chat:
            if shouldShowOpenedHeaderUsage {
                UsageSummaryStripView(
                    providers: usageSummaryProviders,
                    inline: true,
                    alignment: .trailing,
                    displayStyle: openedHeaderUsageDisplayStyle,
                    locale: settings.locale
                )
                .zIndex(200)
            }
        case .shelf:
            HeaderContextAccessory(
                items: shelfHeaderAccessoryItems
            )
            .help(shelfHeaderHelpText)
        case .music:
            HeaderContextAccessory(
                items: musicHeaderAccessoryItems
            )
            .help(musicHeaderHelpText)
        }
    }

    private var shelfHeaderAccessoryItems: [HeaderContextAccessory.Item] {
        [
            HeaderContextAccessory.Item(
                id: "shelf-count",
                icon: .system(
                    shelfStore.items.isEmpty ? "tray" : "doc.on.doc.fill",
                    badge: shelfStore.items.isEmpty ? nil : shelfStore.items.count
                ),
                helpText: shelfHeaderPrimaryText
            ),
            HeaderContextAccessory.Item(
                id: "shelf-clear",
                icon: .system("trash"),
                helpText: shelfHeaderClearHelpText,
                action: shelfStore.items.isEmpty ? nil : {
                    shelfStore.clear()
                }
            )
        ].filter { item in
            item.id != "shelf-clear" || !shelfStore.items.isEmpty
        }
    }

    private var musicHeaderAccessoryItems: [HeaderContextAccessory.Item] {
        [
            HeaderContextAccessory.Item(
                id: "music-source",
                icon: musicHeaderSourceIcon,
                helpText: musicHeaderPrimaryText,
                action: musicHeaderSourceAction
            )
        ]
    }

    private var shouldShowOpenedTaskProgressAccessory: Bool {
        obsidianTaskStore.snapshot != nil && (isShelfPanelSelected || isMusicPanelSelected)
    }

    private var musicHeaderSourceIcon: HeaderContextAccessory.Icon {
        guard let source = musicStore.track?.source.lowercased() else {
            return .system("music.note")
        }

        if source.contains("netease") || source.contains("网易") {
            return .templateAsset("NeteaseCloudMusicLine")
        }
        if source.contains("spotify") {
            return .system("music.note.list")
        }
        if source == "music" || source.contains("apple") {
            return .system("music.note")
        }
        return .system("music.note")
    }

    private var shelfHeaderPrimaryText: String {
        guard !shelfStore.items.isEmpty else { return "Shelf" }
        return "\(shelfStore.items.count) \(shelfStore.items.count == 1 ? "item" : "items")"
    }

    private var shelfHeaderSecondaryText: String {
        guard let totalSize = shelfHeaderTotalSize else { return "Ready" }
        return ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    private var shelfHeaderHelpText: String {
        guard !shelfStore.items.isEmpty else { return "Shelf is empty" }
        return "Shelf: \(shelfHeaderPrimaryText), \(shelfHeaderSecondaryText)"
    }

    private var shelfHeaderClearHelpText: String {
        guard !shelfStore.items.isEmpty else { return "Shelf is empty" }
        return "清空 Shelf · \(shelfHeaderPrimaryText), \(shelfHeaderSecondaryText)"
    }

    private var shelfHeaderTotalSize: Int64? {
        let sizes = shelfStore.items.compactMap(\.fileSize)
        guard !sizes.isEmpty else { return nil }
        return sizes.reduce(0, +)
    }

    private var musicHeaderPrimaryText: String {
        guard let source = musicStore.track?.source else { return "Music" }
        return musicSourceBundleIdentifier == nil ? source : "打开 \(source)"
    }

    private var musicHeaderSecondaryText: String {
        guard let track = musicStore.track else { return "Idle" }
        return track.isPlaying ? "Playing" : "Paused"
    }

    private var musicHeaderHelpText: String {
        guard let track = musicStore.track else { return "No music playing" }
        return "\(track.source): \(track.title) - \(track.artist), \(musicHeaderSecondaryText)"
    }

    private var musicHeaderSourceAction: (() -> Void)? {
        guard musicSourceBundleIdentifier != nil else { return nil }
        return {
            openCurrentMusicSource()
        }
    }

    private var musicSourceBundleIdentifier: String? {
        guard let source = musicStore.track?.source.lowercased() else { return nil }
        if source.contains("netease") || source.contains("网易") {
            return "com.netease.163music"
        }
        if source.contains("spotify") {
            return "com.spotify.client"
        }
        if source == "music" || source.contains("apple") {
            return "com.apple.Music"
        }
        return nil
    }

    private func openCurrentMusicSource() {
        guard let bundleIdentifier = musicSourceBundleIdentifier else { return }

        if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { runningApplication, _ in
                DispatchQueue.main.async {
                    let application = runningApplication ?? NSWorkspace.shared.runningApplications.first {
                        $0.bundleIdentifier == bundleIdentifier
                    }
                    activateMusicApplication(application)
                }
            }
            return
        }

        if let runningApplication = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) {
            activateMusicApplication(runningApplication)
        }
    }

    private func activateMusicApplication(_ runningApplication: NSRunningApplication?) {
        guard let runningApplication else { return }
        runningApplication.unhide()
        runningApplication.activate(options: [.activateAllWindows])
    }

    private var openedHeaderTabControls: some View {
        HStack(spacing: 8) {
            IslandPanelSwitchButton(
                systemName: "terminal.fill",
                isSelected: isCodingPanelSelected,
                helpText: "Coding"
            ) {
                acknowledgeActiveCompletionNotification()
                removeCompletionNotifications(
                    matching: { $0 == .completed || $0 == .ended },
                    keepPanelOpen: true,
                    acknowledge: true
                )
                viewModel.presentSessionList(reason: .click)
            }

            IslandPanelSwitchButton(
                systemName: "tray.full.fill",
                isSelected: isShelfPanelSelected,
                helpText: "Shelf"
            ) {
                acknowledgeActiveCompletionNotification()
                viewModel.presentShelf(reason: .click)
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isShelfDropTargeted) { providers in
                viewModel.presentShelf(reason: .click)
                return shelfStore.addItemProviders(providers)
            }

            IslandPanelSwitchButton(
                systemName: "music.note",
                isSelected: isMusicPanelSelected,
                helpText: "Music"
            ) {
                acknowledgeActiveCompletionNotification()
                viewModel.presentMusic(reason: .click)
            }
        }
    }

    private var openedHeaderUtilityControls: some View {
        HStack(spacing: 8) {
            openedHeaderLeadingStatus

            NotchTemporaryMuteButton(
                isActive: areReminderNotificationsSuppressed,
                action: activateTemporaryReminderMute,
                helpText: temporaryMuteButtonHelpText
            )

            NotchSettingsButton(
                hasUnseenUpdate: updateManager.hasUnseenUpdate,
                action: openSettingsWindow
            )
        }
    }

    private var openedHeaderNotchClearance: CGFloat {
        viewModel.hasPhysicalNotch ? 64 : 20
    }

    private var isCodingPanelSelected: Bool {
        switch viewModel.contentType {
        case .instances, .chat:
            return true
        case .shelf, .music:
            return false
        }
    }

    private var isShelfPanelSelected: Bool {
        if case .shelf = viewModel.contentType { return true }
        return false
    }

    private var isMusicPanelSelected: Bool {
        if case .music = viewModel.contentType { return true }
        return false
    }

    private func presentDefaultPanel(reason: NotchOpenReason) {
        if hasAttentionPriorityContent(in: sessionMonitor.instances) {
            viewModel.presentSessionList(reason: reason)
        } else if viewModel.presentLastManualPanel(reason: reason) {
            return
        } else if hasActiveCodingContent(in: sessionMonitor.instances) {
            viewModel.presentSessionList(reason: reason)
        } else if !shelfStore.items.isEmpty {
            viewModel.presentShelf(reason: reason)
        } else {
            viewModel.notchOpen(reason: reason)
        }
    }

    private func hasAttentionPriorityContent(in instances: [SessionState]) -> Bool {
        instances.contains { session in
            session.needsApprovalResponse || session.needsQuestionResponse
        }
    }

    private func hasActiveCodingContent(in instances: [SessionState]) -> Bool {
        instances.contains { session in
            isClosedThinkingSession(session)
        }
    }

    private func isClosedCountedSession(_ session: SessionState) -> Bool {
        isClosedThinkingSession(session) || session.needsApprovalResponse || session.needsQuestionResponse
    }

    private func isClosedThinkingSession(_ session: SessionState, now: Date = Date()) -> Bool {
        if isFreshProcessingSession(session, now: now) {
            return true
        }

        guard session.provider == .codex, session.phase != .ended else {
            return false
        }

        if session.phase.isActive {
            return true
        }

        guard let message = session.compactHookMessage?.lowercased() else {
            return false
        }

        return message.contains("正在思考")
            || message.contains("thinking")
    }

    private func isFreshProcessingSession(_ session: SessionState, now: Date = Date()) -> Bool {
        guard session.phase.isActive else { return false }
        return now.timeIntervalSince(session.lastActivity) <= Self.closedProcessingFreshnessWindow
    }

    private func closedCountIdentity(for session: SessionState) -> String {
        if let sessionFilePath = session.clientInfo.sessionFilePath,
           !sessionFilePath.isEmpty {
            return sessionFilePath
        }
        return session.sessionId
    }

    private var acknowledgedCompletedSessionStableIDs: Set<String> {
        Set(
            sessionMonitor.instances
                .filter { hasAcknowledgedCompletionNotification(for: $0, kind: .completed) }
                .map(\.stableId)
        )
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        IslandOpenedContentView(
            sessionMonitor: sessionMonitor,
            viewModel: viewModel,
            surface: .docked,
            trigger: triggerForCurrentPresentation,
            style: .docked,
            activeCompletionNotification: activeCompletionNotification,
            acknowledgedCompletedSessionStableIDs: acknowledgedCompletedSessionStableIDs,
            onAttentionActionCompleted: {},
            onAcknowledgeCompletedSession: acknowledgeCompletedSession,
            onCompletionNotificationHoverChanged: handleCompletionNotificationHover,
            onDismissCompletionNotification: {
                clearCompletionNotifications(keepPanelOpen: true, acknowledge: true)
            }
        )
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    private var triggerForCurrentPresentation: IslandExpandedTrigger {
        switch viewModel.openReason {
        case .hover:
            return .hover
        case .notification:
            return .notification
        case .click, .boot, .unknown:
            return .click
        }
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        viewModel.updateIdleAutoHiddenState(hasVisibleSessionActivity: !shouldHideForIdleState)

        if viewModel.shouldHideWindowPresentation {
            isVisible = false
            return
        }

        if isAnyProcessing || hasPendingPermission {
            // Show claude activity when processing or waiting for permission
            activityCoordinator.showActivity(type: .claude)
            isVisible = true
        } else if hasHumanIntervention || hasCompletedReadyState {
            // Keep visible for attention/completion states but stop the active processing animation.
            activityCoordinator.hideActivity()
            isVisible = true
        } else {
            // Hide activity when done
            activityCoordinator.hideActivity()
            isVisible = true
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            cancelScheduledDetachmentHintPresentation()
            dismissDetachmentHint()
            if viewModel.openReason == .click {
                waitingForInputTimestamps.removeAll()
                clearCompletionNotifications(keepPanelOpen: true, acknowledge: true)
                acknowledgeCompletionNotificationsAlreadyInView(sessionMonitor.instances, includeSessionList: true)
            }
        case .closed:
            isVisible = !viewModel.shouldHideWindowPresentation
            maybePresentNextCompletionNotification()
            scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
        }
    }

    private func scheduleDetachmentHintPresentationIfNeeded(force: Bool = false, delay: TimeInterval) {
        guard force || settings.notchDetachmentHintPending else {
            cancelScheduledDetachmentHintPresentation()
            return
        }

        detachmentHintPresentationWorkItem?.cancel()

        let workItem = DispatchWorkItem { [force] in
            detachmentHintPresentationWorkItem = nil
            presentDetachmentHintIfNeeded(force: force)
        }
        detachmentHintPresentationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelScheduledDetachmentHintPresentation() {
        detachmentHintPresentationWorkItem?.cancel()
        detachmentHintPresentationWorkItem = nil
    }

    private func presentDetachmentHintIfNeeded(force: Bool = false) {
        guard force || settings.notchDetachmentHintPending else { return }
        guard settings.surfaceMode == .notch else { return }
        guard viewModel.presentationMode == .docked else { return }
        guard viewModel.status == .closed else { return }
        guard !shouldHideClosedContent else { return }

        cancelScheduledDetachmentHintPresentation()
        settings.notchDetachmentHintPending = false
        detachmentHintDismissWorkItem?.cancel()

        if !isShowingDetachmentHint {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                isShowingDetachmentHint = true
            }
        }

        let workItem = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.18)) {
                isShowingDetachmentHint = false
            }
        }
        detachmentHintDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: workItem)
    }

    private func dismissDetachmentHint() {
        detachmentHintDismissWorkItem?.cancel()
        detachmentHintDismissWorkItem = nil
        guard isShowingDetachmentHint else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            isShowingDetachmentHint = false
        }
    }

    private func handleManualAttentionChange(_ instances: [SessionState]) {
        guard let targetSession = manualAttentionTracker.consumeNewAttentionSession(from: instances) else {
            return
        }

        if areReminderNotificationsSuppressed {
            return
        }

        clearCompletionNotifications(keepPanelOpen: true)

        guard viewModel.status == .opened else {
            return
        }

        if targetSession.needsApprovalResponse {
            viewModel.presentNotificationAttention()
            return
        }

        if targetSession.needsQuestionResponse {
            viewModel.presentNotificationChat(for: targetSession)
            return
        }

        viewModel.presentNotificationChat(for: targetSession)
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        let allWaitingIds = Set(
            instances
                .filter { $0.phase == .waitingForInput }
                .map(\.stableId)
        )
        let newWaitingIds = allWaitingIds.subtracting(previousWaitingForInputIds)

        // Only completed sessions without intervention should get the temporary green checkmark.
        let completedSessions = instances.filter { SessionCompletionStateEvaluator.isCompletedReadySession($0) }
        let completedIds = Set(completedSessions.map(\.stableId))

        // Track timestamps for newly waiting sessions
        let now = Date()
        for session in completedSessions where newWaitingIds.contains(session.stableId) {
            waitingForInputTimestamps[session.stableId] = now
        }
        for session in completedSessions
            where waitingForInputTimestamps[session.stableId] == nil
                && now.timeIntervalSince(session.lastActivity) < Self.notificationSoundFreshnessWindow {
            waitingForInputTimestamps[session.stableId] = session.lastActivity
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIds = Set(waitingForInputTimestamps.keys).subtracting(completedIds)
        for staleId in staleIds {
            waitingForInputTimestamps.removeValue(forKey: staleId)
        }

        if !newWaitingIds.isEmpty {
            // Schedule hiding the checkmark after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
                // Trigger a UI update to re-evaluate the temporary completion badge.
                handleProcessingChange()
            }
        }

        previousWaitingForInputIds = allWaitingIds
    }

    private func primeCompletionNotificationTracking(_ instances: [SessionState]) {
        previousCompletionNotificationPhases = Dictionary(
            uniqueKeysWithValues: instances.map { ($0.stableId, $0.phase) }
        )
        synchronizeCompletionNotifications(with: instances)
    }

    private func handleCompletionNotificationChange(_ instances: [SessionState]) {
        synchronizeCompletionNotifications(with: instances)

        if areReminderNotificationsSuppressed {
            if activeCompletionNotification != nil || !completionNotificationQueue.isEmpty {
                clearCompletionNotifications(keepPanelOpen: true, acknowledge: true)
            }

            previousCompletionNotificationPhases = Dictionary(
                uniqueKeysWithValues: instances.map { ($0.stableId, $0.phase) }
            )
            return
        }

        prunePresentedCompletionNotificationKeys(using: instances)
        acknowledgeCompletionNotificationsAlreadyInView(instances)

        let currentPhases = Dictionary(
            uniqueKeysWithValues: instances.map { ($0.stableId, $0.phase) }
        )

        // Ambient popups are one-shot notifications. If the notch is already expanded for
        // some other reason, drop new ones instead of queueing them to appear later on
        // top of the normal expanded UI.
        if viewModel.status == .opened && activeCompletionNotification == nil {
            acknowledgeCompletionNotificationsAlreadyInView(instances, includeSessionList: true)
            previousCompletionNotificationPhases = currentPhases
            completionNotificationQueue.removeAll()
            return
        }

        let newNotifications = instances
            .compactMap { session -> SessionCompletionNotification? in
                let previousPhase = previousCompletionNotificationPhases[session.stableId]

                if shouldQueueCompactedNotification(for: session, previousPhase: previousPhase) {
                    return SessionCompletionNotification(session: session, kind: .compacted)
                }

                if shouldQueueCompletedNotification(for: session, previousPhase: previousPhase) {
                    return SessionCompletionNotification(session: session, kind: .completed)
                }

                if shouldQueueEndedNotification(for: session, previousPhase: previousPhase) {
                    return SessionCompletionNotification(session: session, kind: .ended)
                }

                return nil
            }
            .sorted { $0.session.lastActivity < $1.session.lastActivity }

        for notification in newNotifications {
            enqueueCompletionNotification(notification)
        }

        previousCompletionNotificationPhases = currentPhases
        maybePresentNextCompletionNotification()
    }

    private func shouldQueueCompletedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?
    ) -> Bool {
        // The closed island already surfaces fresh completed sessions with the
        // green completion state. Auto-opening the completion preview duplicates
        // that signal and can visually compete with the closed completed badge.
        false
    }

    private func shouldQueueEndedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?
    ) -> Bool {
        guard settings.autoOpenCompletionPanel else { return false }
        guard session.phase == .ended else { return false }
        guard previousPhase != .ended else { return false }
        guard previousPhase != .waitingForInput else { return false }
        guard !hasPresentedCompletionNotification(for: session, kind: .ended) else { return false }
        return true
    }

    private func shouldQueueCompactedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?
    ) -> Bool {
        guard settings.autoOpenCompactedNotificationPanel else { return false }
        guard previousPhase == .compacting else { return false }
        guard session.phase != .compacting else { return false }
        guard !hasPresentedCompletionNotification(for: session, kind: .compacted) else { return false }
        return true
    }

    private func synchronizeCompletionNotifications(with instances: [SessionState]) {
        let sessionsById = Dictionary(uniqueKeysWithValues: instances.map { ($0.stableId, $0) })

        if let active = activeCompletionNotification {
            if let latest = sessionsById[active.session.stableId] {
                activeCompletionNotification?.session = latest
            } else {
                dismissActiveCompletionNotification(closePanel: false, advanceQueue: true)
            }
        }

        completionNotificationQueue = completionNotificationQueue.compactMap { notification in
            guard let latest = sessionsById[notification.session.stableId] else { return nil }
            var updated = notification
            updated.session = latest
            return updated
        }
    }

    private func enqueueCompletionNotification(_ notification: SessionCompletionNotification) {
        guard !hasPresentedCompletionNotification(
            for: notification.session,
            kind: notification.kind
        ) else { return }

        if let active = activeCompletionNotification,
           active.session.stableId == notification.session.stableId {
            activeCompletionNotification?.session = notification.session
            return
        }

        if let queuedIndex = completionNotificationQueue.firstIndex(where: {
            $0.session.stableId == notification.session.stableId
        }) {
            var updated = completionNotificationQueue[queuedIndex]
            updated.session = notification.session
            completionNotificationQueue[queuedIndex] = updated
            return
        }

        completionNotificationQueue.append(notification)
    }

    private func maybePresentNextCompletionNotification() {
        guard !areReminderNotificationsSuppressed else { return }
        guard activeCompletionNotification == nil else { return }
        guard viewModel.status == .opened else {
            completionNotificationQueue.removeAll()
            return
        }
        guard !hasPendingPermission && !hasHumanIntervention else { return }
        guard case .instances = viewModel.contentType else { return }

        if viewModel.openReason != .notification {
            acknowledgeCompletionNotificationsAlreadyInView(sessionMonitor.instances, includeSessionList: true)
            completionNotificationQueue.removeAll()
            return
        }

        while let first = completionNotificationQueue.first,
              hasPresentedCompletionNotification(for: first.session, kind: first.kind) {
            completionNotificationQueue.removeFirst()
        }

        guard !completionNotificationQueue.isEmpty else { return }

        let nextNotification = completionNotificationQueue.removeFirst()
        markCompletionNotificationPresented(nextNotification)
        activeCompletionNotification = nextNotification
        shouldDismissCompletionNotificationOnHoverExit = false

        scheduleCompletionNotificationDismissal(for: nextNotification.id)
    }

    private func scheduleCompletionNotificationDismissal(for notificationID: UUID) {
        completionNotificationDismissWorkItem?.cancel()

        let workItem = DispatchWorkItem { [self] in
            guard activeCompletionNotification?.id == notificationID else { return }
            dismissActiveCompletionNotification(closePanel: true, advanceQueue: true)
        }

        completionNotificationDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func clearCompletionNotifications(keepPanelOpen: Bool, acknowledge: Bool = false) {
        removeCompletionNotifications(
            matching: { _ in true },
            keepPanelOpen: keepPanelOpen,
            acknowledge: acknowledge
        )
    }

    private func removeCompletionNotifications(
        matching shouldRemove: (SessionCompletionNotification.Kind) -> Bool,
        keepPanelOpen: Bool,
        acknowledge: Bool = false
    ) {
        if acknowledge {
            for notification in completionNotificationQueue where shouldRemove(notification.kind) {
                markCompletionNotificationPresented(notification)
                markCompletionNotificationAcknowledged(notification)
            }
        }

        completionNotificationQueue.removeAll { shouldRemove($0.kind) }

        if let activeCompletionNotification, shouldRemove(activeCompletionNotification.kind) {
            if acknowledge {
                markCompletionNotificationPresented(activeCompletionNotification)
                markCompletionNotificationAcknowledged(activeCompletionNotification)
            }
            dismissActiveCompletionNotification(closePanel: !keepPanelOpen, advanceQueue: true)
        }
    }

    private func handleCompletionNotificationHover(_ isHovering: Bool) {
        guard activeCompletionNotification != nil else {
            shouldDismissCompletionNotificationOnHoverExit = false
            return
        }

        if isHovering {
            shouldDismissCompletionNotificationOnHoverExit = true
            completionNotificationDismissWorkItem?.cancel()
            completionNotificationDismissWorkItem = nil
            return
        }

        guard shouldDismissCompletionNotificationOnHoverExit else { return }
        shouldDismissCompletionNotificationOnHoverExit = false
        dismissActiveCompletionNotification(closePanel: true, advanceQueue: true)
    }

    private func dismissActiveCompletionNotification(
        closePanel: Bool,
        advanceQueue: Bool
    ) {
        completionNotificationDismissWorkItem?.cancel()
        completionNotificationDismissWorkItem = nil
        shouldDismissCompletionNotificationOnHoverExit = false

        guard activeCompletionNotification != nil else {
            if advanceQueue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    maybePresentNextCompletionNotification()
                }
            }
            return
        }

        activeCompletionNotification = nil

        if closePanel,
           viewModel.status == .opened,
           viewModel.openReason == .notification,
           !hasPendingPermission,
           !hasHumanIntervention {
            viewModel.notchClose()
        }

        if advanceQueue {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                maybePresentNextCompletionNotification()
            }
        }
    }

    private func completionNotificationKey(
        sessionId: String,
        kind: SessionCompletionNotification.Kind
    ) -> String {
        "\(sessionId)#\(kind.rawValue)"
    }

    private func completionNotificationKey(
        for session: SessionState,
        kind: SessionCompletionNotification.Kind
    ) -> String {
        completionNotificationKey(sessionId: session.stableId, kind: kind)
    }

    private func hasPresentedCompletionNotification(
        for session: SessionState,
        kind: SessionCompletionNotification.Kind
    ) -> Bool {
        presentedCompletionNotificationKeys.contains(
            completionNotificationKey(for: session, kind: kind)
        )
    }

    private func hasAcknowledgedCompletionNotification(
        for session: SessionState,
        kind: SessionCompletionNotification.Kind
    ) -> Bool {
        acknowledgedCompletionNotificationKeys.contains(
            completionNotificationKey(for: session, kind: kind)
        )
    }

    private func markCompletionNotificationPresented(_ notification: SessionCompletionNotification) {
        presentedCompletionNotificationKeys.insert(
            completionNotificationKey(for: notification.session, kind: notification.kind)
        )
    }

    private func markCompletionNotificationPresented(
        for session: SessionState,
        kind: SessionCompletionNotification.Kind
    ) {
        presentedCompletionNotificationKeys.insert(
            completionNotificationKey(for: session, kind: kind)
        )
    }

    private func markCompletionNotificationAcknowledged(_ notification: SessionCompletionNotification) {
        acknowledgedCompletionNotificationKeys.insert(
            completionNotificationKey(for: notification.session, kind: notification.kind)
        )
    }

    private func markCompletionNotificationAcknowledged(
        for session: SessionState,
        kind: SessionCompletionNotification.Kind
    ) {
        acknowledgedCompletionNotificationKeys.insert(
            completionNotificationKey(for: session, kind: kind)
        )
    }

    private func acknowledgeActiveCompletionNotification() {
        guard let activeCompletionNotification else { return }
        markCompletionNotificationPresented(activeCompletionNotification)
        markCompletionNotificationAcknowledged(activeCompletionNotification)
        dismissActiveCompletionNotification(closePanel: false, advanceQueue: false)
    }

    private func acknowledgeCompletedSession(_ session: SessionState) {
        let liveSession = sessionMonitor.instances.first {
            $0.stableId == session.stableId
        } ?? session

        guard SessionCompletionStateEvaluator.isCompletedReadySession(liveSession) else { return }

        waitingForInputTimestamps.removeValue(forKey: liveSession.stableId)
        markCompletionNotificationPresented(for: liveSession, kind: .completed)
        markCompletionNotificationAcknowledged(for: liveSession, kind: .completed)
        completionNotificationQueue.removeAll {
            $0.session.stableId == liveSession.stableId && $0.kind == .completed
        }

        if activeCompletionNotification?.session.stableId == liveSession.stableId,
           activeCompletionNotification?.kind == .completed {
            dismissActiveCompletionNotification(closePanel: false, advanceQueue: false)
        }
    }

    private func acknowledgeCompletionNotificationsAlreadyInView(
        _ instances: [SessionState],
        includeSessionList: Bool = false
    ) {
        guard viewModel.status == .opened else { return }

        switch viewModel.contentType {
        case .chat(let currentSession):
            guard let session = instances.first(where: { $0.stableId == currentSession.stableId }),
                  SessionCompletionStateEvaluator.isCompletedReadySession(session) else {
                return
            }
            markCompletionNotificationPresented(for: session, kind: .completed)
            markCompletionNotificationAcknowledged(for: session, kind: .completed)
            completionNotificationQueue.removeAll {
                $0.session.stableId == session.stableId && $0.kind == .completed
            }
            if activeCompletionNotification?.session.stableId == session.stableId,
               activeCompletionNotification?.kind == .completed {
                dismissActiveCompletionNotification(closePanel: false, advanceQueue: false)
            }
        case .instances:
            guard includeSessionList || viewModel.openReason != .notification else { return }
            for session in instances where SessionCompletionStateEvaluator.isCompletedReadySession(session) {
                markCompletionNotificationPresented(for: session, kind: .completed)
                markCompletionNotificationAcknowledged(for: session, kind: .completed)
            }
        case .shelf, .music:
            return
        }
    }

    private func isCompletionNotificationAlreadyVisibleContext(for session: SessionState) -> Bool {
        guard viewModel.status == .opened else { return false }

        switch viewModel.contentType {
        case .chat(let currentSession):
            return currentSession.stableId == session.stableId
        case .instances:
            return viewModel.openReason != .notification
        case .shelf, .music:
            return false
        }
    }

    private func prunePresentedCompletionNotificationKeys(using instances: [SessionState]) {
        let liveIds = Set(instances.map(\.stableId))
        presentedCompletionNotificationKeys = presentedCompletionNotificationKeys.filter { key in
            guard let separator = key.firstIndex(of: "#") else { return false }
            let sessionId = String(key[..<separator])
            guard liveIds.contains(sessionId) else { return false }

            guard let session = instances.first(where: { $0.stableId == sessionId }) else {
                return false
            }
            return !session.phase.isActive && session.intervention == nil
        }
        acknowledgedCompletionNotificationKeys = acknowledgedCompletionNotificationKeys.filter { key in
            guard let separator = key.firstIndex(of: "#") else { return false }
            let sessionId = String(key[..<separator])
            guard liveIds.contains(sessionId) else { return false }

            guard let session = instances.first(where: { $0.stableId == sessionId }) else {
                return false
            }
            return !session.phase.isActive && session.intervention == nil
        }
    }

    private func handleSessionSoundTransitions(_ instances: [SessionState]) {
        if !hasPrimedSoundTransitions {
            previousProcessingIds = Set(
                instances
                    .filter { $0.phase == .processing || $0.phase == .compacting }
                    .map(\.stableId)
            )
            previousAttentionSoundIds = Set(
                instances
                    .filter { $0.needsApprovalResponse || ($0.phase == .waitingForInput && $0.intervention != nil) }
                    .map(\.stableId)
            )
            previousCompletionSoundIds = Set(
                instances
                    .filter { $0.phase == .waitingForInput && $0.intervention == nil }
                    .map(\.stableId)
            )
            previousTaskErrorIds = Set(
                instances.flatMap { session in
                    session.completedErrorToolIDs.map { "\(session.sessionId):\($0)" }
                }
            )
            previousResourceLimitIds = Set(
                instances
                    .filter { $0.phase == .compacting }
                    .map(\.stableId)
            )
            hasPrimedSoundTransitions = true
            return
        }

        let processingSessions = instances.filter {
            $0.phase == .processing || $0.phase == .compacting
        }
        let attentionSessions = instances.filter {
            $0.needsApprovalResponse || ($0.phase == .waitingForInput && $0.intervention != nil)
        }
        let approvalSessions = attentionSessions.filter(\.needsApprovalResponse)
        let nonApprovalAttentionSessions = attentionSessions.filter { !$0.needsApprovalResponse }
        let completedSessions = instances.filter { SessionCompletionStateEvaluator.isCompletedReadySession($0) }
        let resourceLimitedSessions = instances.filter {
            $0.phase == .compacting
        }

        let newProcessingIds = Set(processingSessions.map(\.stableId))
        let newAttentionIds = Set(attentionSessions.map(\.stableId))
        let newCompletedIds = Set(completedSessions.map(\.stableId))
        let newTaskErrorIds = Set(
            instances.flatMap { session in
                session.completedErrorToolIDs.map { "\(session.sessionId):\($0)" }
            }
        )
        let newResourceLimitIds = Set(resourceLimitedSessions.map(\.stableId))
        let errorDeltaIds = newTaskErrorIds.subtracting(previousTaskErrorIds)
        let errorSessions = instances.filter { session in
            session.completedErrorToolIDs.contains { errorDeltaIds.contains("\(session.sessionId):\($0)") }
        }
        let completionDeltaIds = newCompletedIds.subtracting(previousCompletionSoundIds)
        let newlyCompletedSessions = completedSessions.filter { session in
            completionDeltaIds.contains(session.stableId)
        }
        let processingDeltaIds = newProcessingIds.subtracting(previousProcessingIds)
        let newlyProcessingSessions = processingSessions.filter { session in
            processingDeltaIds.contains(session.stableId)
        }
        let newlyApprovalSessions = approvalSessions.filter { session in
            newAttentionIds.subtracting(previousAttentionSoundIds).contains(session.stableId)
        }
        let newlyNonApprovalAttentionSessions = nonApprovalAttentionSessions.filter { session in
            newAttentionIds.subtracting(previousAttentionSoundIds).contains(session.stableId)
        }
        let newlyResourceLimitedSessions = resourceLimitedSessions.filter { session in
            newResourceLimitIds.subtracting(previousResourceLimitIds).contains(session.stableId)
        }

        let isNewApproval = hasFreshSoundCandidate(newlyApprovalSessions)
        let isNewAttention = hasFreshSoundCandidate(newlyNonApprovalAttentionSessions)
        let isNewCompletion = hasFreshSoundCandidate(newlyCompletedSessions)
        let isNewTaskError = hasFreshSoundCandidate(errorSessions)
        let isNewResourceLimit = hasFreshSoundCandidate(newlyResourceLimitedSessions)
        let isNewProcessing = hasFreshSoundCandidate(newlyProcessingSessions)

        if isNewTaskError {
            playEventSoundIfNeeded(.taskError, sessions: freshSoundCandidates(from: errorSessions))
        } else if isNewResourceLimit {
            playEventSoundIfNeeded(.resourceLimit, sessions: freshSoundCandidates(from: newlyResourceLimitedSessions))
        } else if isNewApproval {
            playEventSoundIfNeeded(.approvalRequired, sessions: freshSoundCandidates(from: newlyApprovalSessions))
        } else if isNewAttention {
            playEventSoundIfNeeded(.attentionRequired, sessions: freshSoundCandidates(from: newlyNonApprovalAttentionSessions))
        } else if isNewCompletion {
            playEventSoundIfNeeded(.taskCompleted, sessions: freshSoundCandidates(from: newlyCompletedSessions))
        } else if isNewProcessing {
            playEventSoundIfNeeded(.processingStarted, sessions: freshSoundCandidates(from: newlyProcessingSessions))
        }

        previousProcessingIds = newProcessingIds
        previousAttentionSoundIds = newAttentionIds
        previousCompletionSoundIds = newCompletedIds
        previousTaskErrorIds = newTaskErrorIds
        previousResourceLimitIds = newResourceLimitIds
    }

    private func hasFreshSoundCandidate(_ sessions: [SessionState]) -> Bool {
        !freshSoundCandidates(from: sessions).isEmpty
    }

    private func freshSoundCandidates(from sessions: [SessionState]) -> [SessionState] {
        let now = Date()
        return sessions.filter { session in
            now.timeIntervalSince(session.lastActivity) <= Self.notificationSoundFreshnessWindow
        }
    }

    private func playEventSoundIfNeeded(_ event: NotificationEvent, sessions: [SessionState]) {
        guard AppSettings.soundEnabled else { return }
        guard !sessions.isEmpty else { return }

        Task {
            let shouldPlaySound = await shouldPlayNotificationSound(for: sessions)
            if shouldPlaySound {
                _ = await MainActor.run {
                    if NotificationSoundPlaybackGate.shouldPlay(event: event, sessions: sessions) {
                        AppSettings.playSound(for: event)
                    }
                }
            }
        }
    }

    private func openSettingsWindow() {
        updateManager.markUpdateSeen()
        SettingsWindowController.shared.present()
    }

    private func handleOpenActiveSessionShortcut() {
        guard let session = preferredShortcutSession else { return }
        NSApp.activate(ignoringOtherApps: true)
        viewModel.toggleChat(for: session, reason: .click)
    }

    private func handleOpenSessionListShortcut() {
        NSApp.activate(ignoringOtherApps: true)
        viewModel.toggleSessionList(reason: .click)
    }

    private func activateTemporaryReminderMute() {
        if areReminderNotificationsSuppressed {
            AppSettings.clearReminderNotificationMute()
        } else {
            AppSettings.muteReminderNotifications(for: Self.temporaryReminderMuteDuration)
            clearCompletionNotifications(keepPanelOpen: true)

            if viewModel.openReason == .notification {
                viewModel.exitChat()
            }
        }
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}

private struct NotchDetachmentHintView: View {
    @State private var isArrowNudging = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            StraightDetachHintArrow()
                .stroke(
                    Color.white.opacity(0.86),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 76, height: 40)
                .offset(
                    x: -36 + (isArrowNudging ? -4 : 4),
                    y: 2 + (isArrowNudging ? -3 : 3)
                )
                .onAppear {
                    isArrowNudging = false
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        isArrowNudging = true
                    }
                }
                .onDisappear {
                    isArrowNudging = false
                }

            Text(appLocalized: "拖动宠物，让宠物离岛工作")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.96))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.88))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        )
                )
                .offset(y: 62)
        }
        .frame(width: 242, height: 118, alignment: .topTrailing)
        .shadow(color: Color.black.opacity(0.22), radius: 14, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(AppLocalization.string("拖动宠物，让宠物离岛工作")))
    }
}

private struct StraightDetachHintArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.maxX - 14, y: rect.maxY - 14)
        let end = CGPoint(x: rect.minX + 14, y: rect.minY + 16)

        path.move(to: start)
        path.addQuadCurve(
            to: end,
            control: CGPoint(x: rect.midX + 4, y: rect.midY + 6)
        )

        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 12, y: end.y - 2))

        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 6, y: end.y + 11))

        return path
    }
}

private struct NotchSettingsButton: View {
    let hasUnseenUpdate: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovering ? .black : .white.opacity(0.92))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isHovering ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
                    )

                if hasUnseenUpdate {
                    Circle()
                        .fill(TerminalColors.green)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .stroke(Color.black, lineWidth: 1.5)
                        )
                        .offset(x: 1, y: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("设置")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

private struct IslandPanelSwitchButton: View {
    let systemName: String
    let isSelected: Bool
    let helpText: String
    var showsActivityBadge: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(backgroundColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(isSelected ? 0.18 : 0), lineWidth: 1)
                    )

                if showsActivityBadge {
                    Circle()
                        .fill(TerminalColors.green)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color.black.opacity(0.72), lineWidth: 1))
                        .offset(x: 1, y: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var iconColor: Color {
        if isHovering && !isSelected {
            return .black
        }
        return .white.opacity(isSelected ? 0.96 : 0.68)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.white.opacity(isHovering ? 0.18 : 0.13)
        }
        return isHovering ? Color.white.opacity(0.95) : Color.white.opacity(0.07)
    }
}

private enum ClosedNotchActivityState: Equatable {
    case idle
    case thinking
    case finished
    case approval
    case question

    var tint: Color {
        switch self {
        case .idle:
            return .white.opacity(0.24)
        case .thinking:
            return TerminalColors.blue
        case .finished:
            return TerminalColors.green
        case .approval:
            return TerminalColors.amber
        case .question:
            return TerminalColors.prompt
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle:
            return "空闲"
        case .thinking:
            return "正在思考"
        case .finished:
            return "思考结束"
        case .approval:
            return "需要审批"
        case .question:
            return "需要回答"
        }
    }
}

private struct ClosedNotchStatusIndicator: View {
    let state: ClosedNotchActivityState
    var alignment: Alignment = .center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                statusContent(time: 0)
            } else {
                TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { context in
                    statusContent(time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
    }

    private func statusContent(time: TimeInterval) -> some View {
        Group {
            switch state {
            case .thinking:
                thinkingBubble(time: time)
            case .finished:
                checkBadge(time: time)
            case .approval:
                exclamationBadge(time: time)
            case .question:
                questionBadge(time: time)
            case .idle:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityLabel(state.accessibilityLabel)
    }

    private func thinkingBubble(time: TimeInterval) -> some View {
        let lift = reduceMotion ? CGFloat.zero : CGFloat(sin(time * 2.0) * 0.8)

        return HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                let phase = time * 2.4 + Double(index) * 0.62
                Circle()
                    .fill(Color.black.opacity(0.50 + (sin(phase) + 1) * 0.16))
                    .frame(width: 3.8, height: 3.8)
                    .scaleEffect(reduceMotion ? 1 : 0.90 + (sin(phase) + 1) * 0.08)
            }
        }
        .frame(width: 34, height: 20)
        .background(
            ClosedHandDrawnBubbleShape()
                .fill(Color.white)
        )
        .overlay(
            ClosedHandDrawnBubbleShape()
                .stroke(Color(red: 0.12, green: 0.08, blue: 0.14), lineWidth: 2.2)
        )
        .overlay(
            ClosedHandDrawnBubbleShape()
                .stroke(Color(red: 0.12, green: 0.08, blue: 0.14).opacity(0.38), lineWidth: 1.1)
                .rotationEffect(.degrees(-1.6))
        )
        .offset(y: lift)
    }

    private func exclamationBadge(time: TimeInterval) -> some View {
        let lift = reduceMotion ? CGFloat.zero : CGFloat(sin(time * 2.2) * 0.7)

        return Text("!")
            .font(.system(size: 12, weight: .black, design: .rounded))
            .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.10))
            .frame(width: 19, height: 19)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 1.0, green: 0.76, blue: 0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color(red: 0.13, green: 0.08, blue: 0.13), lineWidth: 2.2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color(red: 0.13, green: 0.08, blue: 0.13).opacity(0.32), lineWidth: 1.0)
                    .rotationEffect(.degrees(1.8))
            )
            .offset(y: lift)
    }

    private func checkBadge(time: TimeInterval) -> some View {
        let scale = reduceMotion ? CGFloat(1) : CGFloat(0.98 + pulse(time, speed: 1.7) * 0.04)

        return Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(Color.white)
            .frame(width: 20, height: 20)
            .background(
                Circle()
                    .fill(Color(red: 0.25, green: 0.86, blue: 0.48))
            )
            .overlay(
                Circle()
                    .stroke(Color(red: 0.12, green: 0.08, blue: 0.13), lineWidth: 2.2)
            )
            .overlay(
                Circle()
                    .stroke(Color(red: 0.12, green: 0.08, blue: 0.13).opacity(0.30), lineWidth: 1.0)
                    .rotationEffect(.degrees(-2))
            )
            .scaleEffect(scale)
    }

    private func questionBadge(time: TimeInterval) -> some View {
        let lift = reduceMotion ? CGFloat.zero : CGFloat(sin(time * 2.0) * 0.7)

        return Text("?")
            .font(.system(size: 11, weight: .black, design: .rounded))
            .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.10))
            .frame(width: 19, height: 19)
            .background(
                Circle()
                    .fill(Color.white)
            )
            .overlay(
                Circle()
                    .stroke(Color(red: 0.13, green: 0.08, blue: 0.13), lineWidth: 2.2)
            )
            .offset(y: lift)
    }

    private func pulse(_ time: TimeInterval, speed: Double) -> Double {
        (sin(time * speed) + 1) / 2
    }
}

private struct ClosedHandDrawnBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.16))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.13, y: rect.minY + rect.height * 0.18),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.06)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.04, y: rect.midY),
            control: CGPoint(x: rect.maxX + rect.width * 0.03, y: rect.minY + rect.height * 0.24)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.maxY - rect.height * 0.13),
            control: CGPoint(x: rect.maxX + rect.width * 0.03, y: rect.maxY - rect.height * 0.18)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.maxY - rect.height * 0.12),
            control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.06)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.04, y: rect.midY),
            control: CGPoint(x: rect.minX - rect.width * 0.03, y: rect.maxY - rect.height * 0.22)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.16),
            control: CGPoint(x: rect.minX - rect.width * 0.02, y: rect.minY + rect.height * 0.20)
        )
        path.closeSubpath()
        return path
    }
}

private struct ClosedMusicNotesIndicator: View {
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                staticNotes
            } else {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                    animatedNotes(time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: size * 1.55, height: size * 1.35, alignment: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var staticNotes: some View {
        ZStack {
            note(symbol: "music.note", color: Self.warmOrange, opacity: 0.72, fontScale: 0.20)
                .rotationEffect(.degrees(-10))
                .offset(x: -size * 0.31, y: -size * 0.30)

            note(symbol: "music.note", color: Self.neonGreen, opacity: 0.78, fontScale: 0.22)
                .rotationEffect(.degrees(10))
                .offset(x: size * 0.30, y: -size * 0.34)
        }
    }

    private func animatedNotes(time: TimeInterval) -> some View {
        ZStack {
            ForEach(Self.configs.indices, id: \.self) { index in
                let config = Self.configs[index]
                let progress = progress(time: time, cycle: config.cycle, phase: config.phase)
                let eased = 1 - pow(1 - progress, 2.35)
                let fade = max(0, sin(progress * .pi)) * config.opacity
                let wobble = sin(time * config.wobbleSpeed + config.phase * .pi * 2) * config.wobble

                note(
                    symbol: config.symbol,
                    color: config.color,
                    opacity: fade,
                    fontScale: config.fontScale
                )
                .scaleEffect(0.72 + eased * 0.30)
                .rotationEffect(.degrees(config.rotation + wobble * 15))
                .offset(
                    x: size * (config.startX + config.travelX * eased + wobble),
                    y: -size * (config.startY + config.travelY * eased)
                )
            }
        }
    }

    private func note(symbol: String, color: Color, opacity: Double, fontScale: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: max(5.5, size * fontScale), weight: .bold))
            .foregroundStyle(color.opacity(opacity))
            .shadow(color: color.opacity(opacity * 0.72), radius: 2.4, y: 0)
    }

    private func progress(time: TimeInterval, cycle: TimeInterval, phase: Double) -> Double {
        let raw = (time / cycle + phase).truncatingRemainder(dividingBy: 1)
        return raw < 0 ? raw + 1 : raw
    }

    private static let neonGreen = Color(red: 0.28, green: 1.0, blue: 0.48)
    private static let warmOrange = Color(red: 1.0, green: 0.48, blue: 0.12)
    private static let acidLime = Color(red: 0.76, green: 1.0, blue: 0.24)

    private static let configs: [NoteConfig] = [
        NoteConfig(
            symbol: "music.note",
            color: warmOrange,
            phase: 0.00,
            cycle: 1.72,
            startX: -0.13,
            startY: 0.10,
            travelX: -0.26,
            travelY: 0.46,
            wobble: 0.035,
            wobbleSpeed: 4.2,
            fontScale: 0.22,
            opacity: 0.86,
            rotation: -12
        ),
        NoteConfig(
            symbol: "music.note",
            color: neonGreen,
            phase: 0.25,
            cycle: 1.82,
            startX: 0.15,
            startY: 0.08,
            travelX: 0.28,
            travelY: 0.50,
            wobble: 0.035,
            wobbleSpeed: 4.7,
            fontScale: 0.24,
            opacity: 0.88,
            rotation: 10
        ),
        NoteConfig(
            symbol: "music.note",
            color: acidLime,
            phase: 0.58,
            cycle: 1.94,
            startX: -0.03,
            startY: 0.06,
            travelX: -0.18,
            travelY: 0.56,
            wobble: 0.026,
            wobbleSpeed: 5.1,
            fontScale: 0.18,
            opacity: 0.68,
            rotation: 6
        )
    ]

    private struct NoteConfig {
        let symbol: String
        let color: Color
        let phase: Double
        let cycle: TimeInterval
        let startX: Double
        let startY: Double
        let travelX: Double
        let travelY: Double
        let wobble: Double
        let wobbleSpeed: Double
        let fontScale: CGFloat
        let opacity: Double
        let rotation: Double
    }
}

private struct HeaderContextAccessory: View {
    struct Item: Identifiable {
        let id: String
        let icon: Icon
        let helpText: String
        let action: (() -> Void)?

        init(id: String, icon: Icon, helpText: String, action: (() -> Void)? = nil) {
            self.id = id
            self.icon = icon
            self.helpText = helpText
            self.action = action
        }
    }

    enum Icon {
        case system(String, badge: Int? = nil)
        case templateAsset(String)
    }

    let items: [Item]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                HeaderContextAccessoryTile(item: item)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

private struct HeaderContextAccessoryTile: View {
    let item: HeaderContextAccessory.Item

    @State private var isHovering = false

    var body: some View {
        Group {
            if let action = item.action {
                Button(action: action) {
                    tileContent
                }
                .buttonStyle(.plain)
            } else {
                tileContent
            }
        }
        .help(item.helpText)
        .accessibilityLabel(item.helpText)
        .onHover { hovering in
            guard isInteractive else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var tileContent: some View {
        ZStack {
            iconView(item.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconForegroundColor)
                .frame(width: 28, height: 28)

            if case .system(_, let badge?) = item.icon {
                Text(badgeText(for: badge))
                    .font(.system(size: 7, weight: .black, design: .rounded))
                    .foregroundStyle(badgeForegroundColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 11, minHeight: 11)
                    .background(
                        Capsule(style: .continuous)
                            .fill(badgeBackgroundColor)
                    )
                    .offset(x: 9, y: -9)
            }
        }
        .frame(width: 28, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func iconView(_ icon: HeaderContextAccessory.Icon) -> some View {
        switch icon {
        case .system(let systemName, _):
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
        case .templateAsset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
        }
    }

    private func badgeText(for count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    private var isInteractive: Bool {
        item.action != nil
    }

    private var isHighlighted: Bool {
        isInteractive && isHovering
    }

    private var iconForegroundColor: Color {
        isHighlighted ? .black : Color.white.opacity(0.88)
    }

    private var backgroundFillColor: Color {
        isHighlighted ? Color.white.opacity(0.95) : Color.white.opacity(0.1)
    }

    private var borderColor: Color {
        isHighlighted ? Color.clear : Color.white.opacity(0.08)
    }

    private var badgeForegroundColor: Color {
        isHighlighted ? Color.white.opacity(0.96) : Color.black.opacity(0.82)
    }

    private var badgeBackgroundColor: Color {
        isHighlighted ? Color.black.opacity(0.88) : Color.white.opacity(0.92)
    }
}

private struct NotchTemporaryMuteButton: View {
    let isActive: Bool
    let action: () -> Void
    let helpText: String

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isActive ? "bell.slash.fill" : "bell.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconForegroundStyle)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundFillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(borderColor, lineWidth: isActive ? 1 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var iconForegroundStyle: AnyShapeStyle {
        if isActive {
            return AnyShapeStyle(Color.white.opacity(isHovering ? 0.8 : 0.6))
        }
        return AnyShapeStyle(isHovering ? Color.black : Color.white.opacity(0.92))
    }

    private var backgroundFillColor: Color {
        if isActive {
            return Color.white.opacity(isHovering ? 0.12 : 0.06)
        }
        return isHovering ? Color.white.opacity(0.95) : Color.white.opacity(0.1)
    }

    private var borderColor: Color {
        if isActive {
            return Color.white.opacity(isHovering ? 0.22 : 0.12)
        }
        return .clear
    }
}

private struct SessionCountIndicator: View {
    let count: Int
    let rightShift: CGFloat

    var body: some View {
        PixelNumberView(
            value: count,
            color: .white.opacity(0.92),
            fontSize: count >= 10 ? 8.8 : 9.6,
            weight: .semibold,
            tracking: count >= 10 ? -0.15 : -0.05
        )
        .frame(minWidth: count >= 10 ? 16 : 12)
        .offset(x: rightShift)
    }
}

private struct ObsidianTaskProgressIndicator: View {
    let snapshot: ObsidianDailyTaskSnapshot
    let rightShift: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(verbatim: "\(snapshot.completed)")
                .foregroundStyle(TerminalColors.green.opacity(0.94))

            Text(verbatim: "/")
                .foregroundStyle(Color.white.opacity(0.38))

            Text(verbatim: "\(snapshot.total)")
                .foregroundStyle(Color.white.opacity(0.92))
        }
        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .monospacedDigit()
        .frame(minWidth: minWidth, alignment: .trailing)
        .offset(x: rightShift)
        .accessibilityLabel("今日 Obsidian 任务，完成 \(snapshot.completed)，总计 \(snapshot.total)")
    }

    private var fontSize: CGFloat {
        snapshot.completed >= 10 || snapshot.total >= 10 ? 8.5 : 9.4
    }

    private var minWidth: CGFloat {
        snapshot.completed >= 10 || snapshot.total >= 10 ? 32 : 25
    }
}

private struct OpenedObsidianTaskAccessory: View {
    let snapshot: ObsidianDailyTaskSnapshot
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(iconColor)

                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(verbatim: "\(snapshot.completed)")
                        .foregroundStyle(completedColor)

                    Text(verbatim: "/")
                        .foregroundStyle(separatorColor)

                    Text(verbatim: "\(snapshot.total)")
                        .foregroundStyle(totalColor)
                }
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            }
            .frame(minWidth: minWidth)
            .frame(height: 28)
            .padding(.horizontal, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundFillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开 Obsidian 今日任务 · \(snapshot.displayText)")
        .accessibilityLabel("打开 Obsidian 今日任务，完成 \(snapshot.completed)，总计 \(snapshot.total)")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var fontSize: CGFloat {
        snapshot.completed >= 10 || snapshot.total >= 10 ? 9.2 : 10
    }

    private var minWidth: CGFloat {
        snapshot.completed >= 10 || snapshot.total >= 10 ? 42 : 37
    }

    private var iconColor: Color {
        isHovering ? .black : Color.white.opacity(0.88)
    }

    private var completedColor: Color {
        isHovering ? .black : TerminalColors.green.opacity(0.94)
    }

    private var separatorColor: Color {
        isHovering ? Color.black.opacity(0.46) : Color.white.opacity(0.38)
    }

    private var totalColor: Color {
        isHovering ? .black : Color.white.opacity(0.92)
    }

    private var backgroundFillColor: Color {
        isHovering ? Color.white.opacity(0.95) : Color.white.opacity(0.1)
    }

    private var borderColor: Color {
        isHovering ? Color.clear : Color.white.opacity(0.08)
    }
}
