import AllwardCore
import AllwardDesign
import AppKit
import Foundation
import SwiftUI

@MainActor
public struct DiagnosticsView: View {
    @Environment(\.allwardPalette) private var palette
    @FocusState private var copyFocused: Bool

    private let state: DiagnosticsViewState
    private let dismissAndRestoreInvocation: @MainActor () -> Void

    public init(
        state: DiagnosticsViewState,
        dismissAndRestoreInvocation: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.dismissAndRestoreInvocation = dismissAndRestoreInvocation
    }

    public var body: some View {
        SurfacePanel(
            title: "Diagnostics",
            presentation: state.presentation,
            subject: state.subject,
            onDismiss: dismissAndRestoreInvocation,
            focusTitleOnAppear: false
        ) {
            presentationContent
        }
        .accessibilityLabel("Diagnostics")
        .accessibilityValue(state.presentation.accessibilityValue(state.subject))
        .onKeyPress(.escape) {
            dismissAndRestoreInvocation()
            return .handled
        }
        .task { copyFocused = state.presentation.state == .live }
    }

    @ViewBuilder
    private var presentationContent: some View {
        switch state.presentation.state {
        case .loading:
            LoadingStateView(
                target: state.subject.target,
                step: state.subject.boundedStep ?? "Collecting diagnostic counters",
                cancel: dismissAndRestoreInvocation
            )
        case .empty:
            EmptyStateView(
                title: "No diagnostics available",
                reason: state.subject.reason ?? "No diagnostic snapshot has been published"
            )
        case .error:
            ErrorStateView(
                operation: state.subject.failedOperation ?? "Collect diagnostics",
                target: state.subject.target,
                cause: state.subject.reason ?? "The diagnostic snapshot failed",
                recovery: state.subject.recovery ?? "Close and reopen Diagnostics"
            )
        case .live:
            liveDiagnostics
        case .needsInput, .running, .finished, .stale, .degraded, .denied:
            VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
                StateBadge(presentation: state.presentation, subject: state.subject)
                Text(state.subject.reason ?? state.subject.target)
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textSecondary, palette)
            }
        }
    }

    private var liveDiagnostics: some View {
        VStack(alignment: .leading, spacing: SpaceToken.section.points) {
            HStack(spacing: SpaceToken.inlineStandard.points) {
                Text("Operational facts only. No terminal content is collected.")
                    .tokenFont(.uiBody, palette)
                    .tokenForeground(.textSecondary, palette)
                Spacer(minLength: SpaceToken.inlineStandard.points)
                Button(action: copyDiagnostics) {
                    Label("Copy plain text", systemImage: "doc.on.doc")
                }
                .tokenFont(.uiLabel, palette)
                .disabled(!state.exportEnabled)
                .focused($copyFocused)
                .modifier(KeyboardFocusRing(isFocused: copyFocused, palette: palette))
                .accessibilityHint("Copies only the pre-scrubbed fields listed in this view")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: SpaceToken.section.points) {
                    protocolSection
                    leaseSection
                    adapterSection
                    connectionSection
                    rendererSection
                    grantsSection
                    exportSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var protocolSection: some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            SectionHeader("Protocol frames")
            HStack(spacing: SpaceToken.section.points) {
                counter("Accepted", state.protocolCounters.accepted, state: .live)
                counter("Ignored", state.protocolCounters.ignored, state: .empty)
                counter("Rejected", state.protocolCounters.rejected, state: .error)
                counter("Superseded", state.protocolCounters.superseded, state: .stale)
            }
            reasonList("Ignored by reason", reasons: state.ignoredReasons, state: .empty)
            reasonList("Rejected by reason", reasons: state.rejectedReasons, state: .error)
        }
    }

    private var leaseSection: some View {
        diagnosticSection("Publisher lease", presentation: state.lease.presentation, subject: state.lease.subject) {
            fact("Publisher", state.lease.publisher)
            fact("Generation", String(state.lease.generation.rawValue))
            fact("Expires", duration(state.lease.expiresIn))
        }
    }

    private var adapterSection: some View {
        diagnosticSection("Adapter route", presentation: state.adapter.presentation, subject: state.adapter.subject) {
            fact("Adapter", state.adapter.name)
            fact("Route", state.adapter.route)
            fact("Reason", state.adapter.reason ?? "No route warning")
        }
    }

    private var connectionSection: some View {
        diagnosticSection(
            "Connection attempts",
            presentation: state.connection.presentation,
            subject: state.connection.subject
        ) {
            fact("Target", state.connection.target)
            fact("Attempt", "\(state.connection.attempt) of \(state.connection.maximumAttempts)")
            fact("Last typed cause", connectionCause(state.connection.lastCause))
        }
    }

    private var rendererSection: some View {
        diagnosticSection("Renderer", presentation: state.renderer.presentation, subject: state.renderer.subject) {
            fact("Frames submitted", String(state.renderer.framesSubmitted))
            fact("Atlas generation", String(state.renderer.atlasGeneration.rawValue))
            fact("Atlas occupancy", String(format: "%.1f%%", state.renderer.atlasOccupancyPercent))
        }
    }

    private var grantsSection: some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            SectionHeader("MCP grants", count: state.mcpGrants.count)
            if state.mcpGrants.isEmpty {
                EmptyStateView(
                    title: "No MCP grants",
                    reason: "No MCP client currently holds an Allward capability grant"
                )
            } else {
                ForEach(state.mcpGrants) { grant in
                    diagnosticSection(
                        grant.clientName,
                        presentation: grant.presentation,
                        subject: grant.subject
                    ) {
                        fact("Scope", grant.scope)
                        fact("Expires", duration(grant.expiresIn))
                    }
                }
            }
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            SectionHeader("Plain-text export", count: state.safeExportFields.count)
            Text(state.exportFileName)
                .tokenFont(.uiData, palette)
                .tokenForeground(.textPrimary, palette)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel("Export file \(state.exportFileName)")
            ForEach(state.safeExportFields) { field in
                fact(field.label, field.safeValue)
            }
            Text("Terminal content and secret material are excluded.")
                .tokenFont(.uiCaption, palette)
                .tokenForeground(.textSecondary, palette)
        }
    }

    private func diagnosticSection<Content: View>(
        _ title: String,
        presentation: ComposedPresentation,
        subject: PresentationSubject,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: SpaceToken.blockStandard.points) {
            HStack(spacing: SpaceToken.inlineStandard.points) {
                Text(title)
                    .tokenFont(.uiHeading, palette)
                    .tokenForeground(.textPrimary, palette)
                Spacer(minLength: SpaceToken.inlineStandard.points)
                StateBadge(presentation: presentation, subject: subject)
            }
            content()
        }
        .padding(.vertical, SpaceToken.blockCompact.points)
        .overlay(alignment: .bottom) {
            Divider().overlay(palette[.strokeDivider].swiftUIColor)
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(presentation.accessibilityValue(subject))
    }

    private func counter(_ label: String, _ value: UInt64, state: PresentationState) -> some View {
        let mark = StateMark.mark(for: state)
        return VStack(alignment: .leading, spacing: SpaceToken.inlineTight.points) {
            Label(label, systemImage: mark.symbolName)
                .tokenFont(.uiCaption, palette)
                .tokenForeground(mark.color, palette)
            Text(String(value))
                .tokenFont(.uiData, palette)
                .tokenForeground(.textPrimary, palette)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(String(value))
    }

    @ViewBuilder
    private func reasonList(_ title: String, reasons: [ReasonCount], state: PresentationState) -> some View {
        if !reasons.isEmpty {
            VStack(alignment: .leading, spacing: SpaceToken.inlineTight.points) {
                Text(title)
                    .tokenFont(.uiLabel, palette)
                    .tokenForeground(.textSecondary, palette)
                ForEach(reasons) { reason in
                    HStack(spacing: SpaceToken.inlineStandard.points) {
                        let mark = StateMark.mark(for: state)
                        Label(reason.reason, systemImage: mark.symbolName)
                            .tokenFont(.uiBody, palette)
                            .tokenForeground(mark.color, palette)
                        Spacer(minLength: SpaceToken.inlineStandard.points)
                        Text(String(reason.count))
                            .tokenFont(.uiData, palette)
                            .tokenForeground(.textPrimary, palette)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(reason.reason)
                    .accessibilityValue(String(reason.count))
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SpaceToken.inlineStandard.points) {
            Text(label)
                .tokenFont(.uiBody, palette)
                .tokenForeground(.textSecondary, palette)
            Spacer(minLength: SpaceToken.inlineStandard.points)
            Text(value)
                .tokenFont(.uiData, palette)
                .tokenForeground(.textPrimary, palette)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private func connectionCause(_ cause: ConnectionCause?) -> String {
        switch cause {
        case .resolvingFailure(let reason): "Resolving failure: \(reason)"
        case .authenticationDenied(let reason): "Authentication denied: \(reason)"
        case .retryable(let reason): "Retryable: \(reason)"
        case .nonretryable(let reason): "Nonretryable: \(reason)"
        case .userCancelled: "User cancelled"
        case nil: "No failed attempt"
        }
    }

    private func duration(_ value: TimeInterval?) -> String {
        guard let value else { return "No expiry" }
        return "\(Int(value.rounded()))s"
    }

    private func copyDiagnostics() {
        let report = (["Allward diagnostics"] + state.safeExportFields.map { "\($0.label): \($0.safeValue)" })
            .joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
    }
}

#Preview("Diagnostics") {
    DiagnosticsView(
        state: DiagnosticsViewState.fixture(),
        dismissAndRestoreInvocation: {}
    )
    .frame(width: 620)
    .padding(SpaceToken.section.points)
    .allwardPalette(DesignPalette(appearance: .dark))
}
