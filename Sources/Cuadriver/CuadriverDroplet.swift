//
//  CuadriverDroplet.swift
//  Cuadriver
//
//  Shows when an agent is driving the Mac through cua-driver, and stops it.
//  A live activity beside the notch while any session is driving; a shelf
//  widget with every session and a Stop control.
//

import Combine
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(CuadriverPrincipal)
public final class CuadriverPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { CuadriverDroplet() }
}

/// Where the daemon stands, as the last poll saw it.
public enum DriverStatus: Equatable {
    case connecting
    case offline
    case online
}

@MainActor
public final class CuadriverDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "cuadriver"

    @Published public private(set) var status: DriverStatus = .connecting
    /// Sessions an agent opened. The implicit lease this droplet's own polls
    /// create is left out.
    @Published public private(set) var sessions: [AgentSession] = []
    @Published public private(set) var permissions: DriverPermissions?
    @Published public private(set) var stopping: Set<String> = []

    private var host: DropletHost?
    private let client: DriverClient
    private var poller: Task<Void, Never>?
    /// Sessions this droplet stopped, and when. The daemon keeps listing a
    /// revoked session as active until it expires, so a stopped row stays
    /// hidden until the session acts again or leaves the list.
    private var stoppedAt: [String: Date] = [:]
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)

    public init(client: DriverClient = DriverClient()) {
        self.client = client
        super.init()
    }

    public var drivingSessions: [AgentSession] { sessions.filter(\.isDriving) }

    // MARK: Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host
        host.log.info("Cua Driver watching \(client.socketPath)")
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // Quick while an agent drives so Stop and the notch keep up,
                // slower when nothing is happening, slowest with no daemon.
                let seconds: Double = switch self.status {
                case .online where !self.drivingSessions.isEmpty: 2
                case .online: 4
                case .offline, .connecting: 10
                }
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    public func deactivate() {
        poller?.cancel()
        poller = nil
        activitySubject.send(nil)
        host = nil
    }

    // MARK: Actions

    public func refresh() async {
        do {
            let all = try await client.sessions()
            let now = Date()
            stoppedAt = stoppedAt.filter { id, _ in all.contains { $0.id == id } }
            sessions = all
                .filter { !($0.isImplicit && $0.clientKind == "direct" && $0.label == nil) }
                .filter { session in
                    guard let stopped = stoppedAt[session.id] else { return true }
                    // Acted since it was stopped: a new session under the same label.
                    return Double(session.idleSeconds) < now.timeIntervalSince(stopped) - 1
                }
                .sorted { $0.idleSeconds < $1.idleSeconds }
            if status != .online {
                host?.log.info("cua-driver daemon reachable")
            }
            status = .online
        } catch {
            if status != .offline {
                host?.log.info("cua-driver daemon unreachable: \(error)")
            }
            status = .offline
            sessions = []
        }
        publishActivity()
    }

    public func refreshPermissions() async {
        guard status == .online else { return }
        permissions = try? await client.permissions()
    }

    /// Stop one session, or every session when it has no label to name it by.
    public func stop(_ session: AgentSession) {
        guard let label = session.label else { return stopAll() }
        stopping.insert(session.id)
        Task {
            do {
                try await client.revoke(session: label)
                stoppedAt[session.id] = Date()
                host?.log.info("Stopped session \(label)")
            } catch {
                host?.log.error("Stopping \(label) failed: \(error)")
            }
            stopping.remove(session.id)
            await refresh()
        }
    }

    public func stopAll() {
        let targets = sessions.map(\.id)
        stopping.formUnion(targets)
        Task {
            do {
                try await client.revokeAll()
                let now = Date()
                for id in targets { stoppedAt[id] = now }
                host?.log.info("Stopped every cua-driver session")
            } catch {
                host?.log.error("Stopping every session failed: \(error)")
            }
            stopping.removeAll()
            await refresh()
        }
    }

    // MARK: Live activity state

    private func publishActivity() {
        let driving = drivingSessions
        guard !driving.isEmpty else {
            activitySubject.send(nil)
            return
        }
        // One stable state while agents drive: priority and isInteractive never
        // change, only the title does.
        let title = driving.count == 1
            ? "\(driving[0].displayName) is driving your Mac"
            : "\(driving.count) agents are driving your Mac"
        activitySubject.send(
            LiveActivityState(
                priority: 150,
                accessibilityTitle: title,
                isInteractive: false,
                joinsPersistentActivitySet: true
            )
        )
    }

    /// The short text in the trailing wing: about six characters fit on a notch.
    fileprivate var compactLabel: String {
        let driving = drivingSessions
        switch driving.count {
        case 0: return "Idle"
        case 1:
            if let label = driving[0].label, label.count <= 6 { return label }
            return "Agent"
        default: return "×\(driving.count)"
        }
    }
}

// MARK: - Live activity

extension CuadriverDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    public func liveActivitySeatDidChange(_ seat: DropletLiveActivitySeat) {
        host?.log.debug("live activity seat is now \(seat)")
    }

    public func makeCompactLeading() -> AnyView {
        AnyView(DrivingGlyph())
    }

    public func makeCompactTrailing() -> AnyView {
        AnyView(CompactLabel(droplet: self))
    }

    /// Droppy does not mount this card: hovering the row opens the shelf,
    /// where the widget and its Stop control are.
    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        AnyView(EmptyView())
    }

    public func makeCompanionCompact(context: CompactLiveActivityContext) -> AnyView {
        AnyView(DrivingGlyph())
    }

    public func makeCompanionDetail(context: LiveActivityContext) -> AnyView? { nil }
}

private struct DrivingGlyph: View {
    var body: some View {
        Image(systemName: "cursorarrow.rays")
            .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }
}

private struct CompactLabel: View {
    @ObservedObject var droplet: CuadriverDroplet

    var body: some View {
        Text(droplet.compactLabel)
            .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .medium, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }
}

// MARK: - Shelf widget

extension CuadriverDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "sessions",
                title: "Cua Driver",
                systemImage: "cursorarrow.rays",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(150)
                )
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(SessionsWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

/// Solo: a row per session with its own Stop. Paired: the count and Stop all.
private struct SessionsWidget: View {
    @ObservedObject var droplet: CuadriverDroplet
    let context: ShelfWidgetContext

    private var maxRows: Int { 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            if context.isCompact {
                compactBody
            } else {
                soloBody
            }
            Spacer(minLength: 0)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await droplet.refreshPermissions() }
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 12, weight: .medium))
            Text("Cua Driver")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            if !droplet.sessions.isEmpty {
                Button {
                    droplet.stopAll()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .disabled(!droplet.stopping.isEmpty)
                .help("Stop every agent")
                .accessibilityLabel("Stop every agent")
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    // MARK: Solo

    @ViewBuilder
    private var soloBody: some View {
        switch droplet.status {
        case .connecting:
            headline("Connecting", detail: nil)
        case .offline:
            headline("Driver not running", detail: "Start it with cua-driver serve")
        case .online where droplet.sessions.isEmpty:
            headline("No agents", detail: permissionsLine)
        case .online:
            VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
                ForEach(droplet.sessions.prefix(maxRows)) { session in
                    SessionRow(
                        session: session,
                        isStopping: droplet.stopping.contains(session.id),
                        stop: { droplet.stop(session) }
                    )
                }
                if droplet.sessions.count > maxRows {
                    Text("\(droplet.sessions.count - maxRows) more")
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
            }
            .droppyFlatGlassControls()
        }
    }

    // MARK: Paired

    @ViewBuilder
    private var compactBody: some View {
        switch droplet.status {
        case .connecting:
            headline("Connecting", detail: nil)
        case .offline:
            headline("Offline", detail: "Driver not running")
        case .online:
            let driving = droplet.drivingSessions.count
            headline(
                driving > 0 ? (driving == 1 ? "1 driving" : "\(driving) driving") : "Idle",
                detail: droplet.sessions.isEmpty
                    ? "No agents"
                    : (droplet.sessions.count == 1 ? "1 session" : "\(droplet.sessions.count) sessions")
            )
        }
    }

    private func headline(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            Text(title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
            }
        }
    }

    private var permissionsLine: String? {
        guard let permissions = droplet.permissions else { return "Waiting for an agent to connect" }
        if permissions.accessibility && permissions.screenRecording {
            return "Ready: Accessibility and Screen Recording granted"
        }
        var missing: [String] = []
        if !permissions.accessibility { missing.append("Accessibility") }
        if !permissions.screenRecording { missing.append("Screen Recording") }
        return "Needs \(missing.joined(separator: " and ")): run cua-driver permissions grant"
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let isStopping: Bool
    let stop: () -> Void

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            Circle()
                .fill(session.isDriving
                      ? AdaptiveColors.notchSurfacePrimaryText
                      : AdaptiveColors.notchSurfaceTertiaryText.opacity(0.5))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: DroppySpacing.sm)
            Text(activity)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Button(action: stop) {
                Image(systemName: isStopping ? "hourglass" : "stop.fill")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 20))
            .disabled(isStopping)
            .help(session.label == nil ? "Stop every agent" : "Stop \(session.displayName)")
            .accessibilityLabel("Stop \(session.displayName)")
        }
    }

    private var subtitle: String {
        var parts = [session.clientKind == "mcp" ? "MCP" : session.clientKind]
        if session.isRecording { parts.append("recording") }
        return parts.joined(separator: " · ")
    }

    private var activity: String {
        session.isDriving ? "Driving" : "Idle \(Self.duration(session.idleSeconds))"
    }

    static func duration(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "\(seconds)s"
        case ..<3600: "\(seconds / 60)m"
        default: "\(seconds / 3600)h"
        }
    }
}
