//
//  CuadriverWidget.swift
//  Cuadriver
//
//  The shelf widget: every session the driver is running, and Stop.
//
//  Alone on the shelf it is a row per session (what it is, how long ago it
//  acted, its own Stop) with a line under them for the stop shortcut, how
//  many more there are, or what went wrong. Beside another widget the rows
//  are narrower: the name over how long ago it acted, and its Stop.
//
//  Laid out like Droppy's own widgets: straight on the shelf with no card
//  around it, the host's inset once at the root, the root filling its
//  rectangle, and a height that is exactly the rows it shows.
//

import AppKit
import DroppyKit
import SwiftUI

/// What the widget is showing, which is all its height depends on.
enum CuadriverWidgetLayout: Equatable {
    /// A headline and a line under it: connecting, offline, no agents.
    case message
    /// This many session rows.
    case rows(Int)
}

/// Every size the widget lays out with. Each part of the widget is framed to
/// these numbers, so the declared height is the sum of what is drawn: no row
/// pushed past the clip and no air under the last one.
enum CuadriverWidgetMetrics {
    static let soloWidth: CGFloat = 420
    static let pairedWidth: CGFloat = 220
    static let minimumWidth: CGFloat = 200
    static let maxRows = 4

    /// `contentInsets` takes 8 above and 8 below under the host's 18pt card
    /// corner. The descriptor gets no context, so the height budgets that,
    /// the larger case; alone on the island the inset is zero and the space
    /// falls between the rows and the footer line.
    static let insetBudget: CGFloat = DroppySpacing.sm * 2
    /// The header is as tall as the Stop disc at its trailing end.
    static let headerHeight: CGFloat = 20
    static let headerSpacing: CGFloat = DroppySpacing.sm
    static let stopButtonSize: CGFloat = 20

    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = DroppySpacing.xs
    static let footerSpacing: CGFloat = DroppySpacing.sm
    static let footerHeight: CGFloat = 14

    static let headlineHeight: CGFloat = 28
    static let detailHeight: CGFloat = 14
    static let messageSpacing: CGFloat = DroppySpacing.xs
    static var messageHeight: CGFloat { headlineHeight + messageSpacing + detailHeight }

    static func contentHeight(for layout: CuadriverWidgetLayout) -> CGFloat {
        let chrome = insetBudget + headerHeight + headerSpacing
        switch layout {
        case .message:
            return chrome + messageHeight
        case .rows(let count):
            let rows = CGFloat(max(1, count))
            return chrome + rows * rowHeight + (rows - 1) * rowSpacing + footerSpacing + footerHeight
        }
    }
}

struct CuadriverWidget: View {
    @ObservedObject var droplet: CuadriverDroplet
    let context: ShelfWidgetContext

    @Environment(\.dropletShelfWidgetTextColor) private var widgetTextColor

    private var primaryText: Color { widgetTextColor ?? AdaptiveColors.notchSurfacePrimaryText }

    var body: some View {
        VStack(alignment: .leading, spacing: CuadriverWidgetMetrics.headerSpacing) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if !context.isPreview { droplet.surfaceDidAppear() }
        }
        .onDisappear {
            if !context.isPreview { droplet.surfaceDidDisappear() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 12, weight: .medium))
            // The droplet's name, as Droppy shows it everywhere: never translated.
            Text(verbatim: "Cua Driver")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: DroppySpacing.md)
            if droplet.status == .online, droplet.info?.permissionMode == .unrestricted {
                CuadriverUnrestrictedBadge(compact: context.isCompact)
            }
            if !droplet.sessions.isEmpty {
                Button {
                    droplet.stopAll(origin: .shelf)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(CuadriverStopButtonStyle())
                .disabled(!droplet.stopping.isEmpty || context.isShelfTransitioning)
                .help("Stop every agent, and block new ones until Cua Driver restarts")
                .accessibilityLabel("Stop every agent")
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        .frame(height: CuadriverWidgetMetrics.headerHeight)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch droplet.status {
        case .connecting:
            CuadriverMessage(
                title: String(localized: "Connecting"),
                detail: String(localized: "Looking for Cua Driver"),
                color: primaryText
            )
        case .offline:
            CuadriverMessage(
                title: context.isCompact ? String(localized: "Offline") : String(localized: "Driver not running"),
                detail: context.isCompact ? String(localized: "Run cua-driver serve") : String(localized: "Start it with cua-driver serve"),
                color: primaryText
            )
        case .online where droplet.sessions.isEmpty && droplet.isSuspended:
            CuadriverMessage(
                title: context.isCompact ? String(localized: "Blocked") : String(localized: "Agents blocked"),
                detail: context.isCompact ? String(localized: "Restart the driver") : String(localized: "Restart Cua Driver to let agents back in"),
                detailIsWarning: true,
                color: primaryText
            )
        case .online where droplet.sessions.isEmpty:
            CuadriverMessage(
                title: String(localized: "No agents"),
                detail: readinessLine,
                detailIsWarning: !(droplet.permissions?.isReady ?? true),
                color: primaryText
            )
        case .online:
            sessionList
        }
    }

    /// Whether the driver could act if an agent connected now.
    private var readinessLine: String {
        guard let permissions = droplet.permissions else {
            return String(localized: "Waiting for an agent to connect")
        }
        if permissions.isReady {
            return context.isCompact ? String(localized: "Ready") : String(localized: "Ready when an agent connects")
        }
        if context.isCompact { return String(localized: "Needs permissions") }
        switch (permissions.accessibility, permissions.screenRecording) {
        case (false, false):
            return String(localized: "Needs Accessibility and Screen Recording: run cua-driver permissions grant")
        case (false, _):
            return String(localized: "Needs Accessibility: run cua-driver permissions grant")
        default:
            return String(localized: "Needs Screen Recording: run cua-driver permissions grant")
        }
    }

    // MARK: Solo

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: CuadriverWidgetMetrics.rowSpacing) {
                ForEach(droplet.sessions.prefix(CuadriverWidgetMetrics.maxRows)) { session in
                    CuadriverSessionRow(
                        session: session,
                        compact: context.isCompact,
                        isDriving: droplet.isDriving(session),
                        isStopping: droplet.stopping.contains(session.id),
                        isDisabled: context.isShelfTransitioning,
                        primaryText: primaryText,
                        stop: { droplet.stop(session) }
                    )
                    .frame(height: CuadriverWidgetMetrics.rowHeight)
                    .transition(DroppyTransition.element)
                }
            }
            .droppyFlatGlassControls()
            Spacer(minLength: CuadriverWidgetMetrics.footerSpacing)
            footer
                .frame(height: CuadriverWidgetMetrics.footerHeight, alignment: .leading)
        }
    }

    /// One line under the rows: what went wrong, how many more there are, or
    /// how to stop every agent without opening the shelf.
    @ViewBuilder
    private var footer: some View {
        let hidden = droplet.sessions.count - CuadriverWidgetMetrics.maxRows
        let compact = context.isCompact
        Group {
            if let failure = droplet.stopFailure {
                Label {
                    Text(verbatim: compact ? String(localized: "Not stopped") : failure)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .foregroundStyle(CuadriverStyle.warning)
            } else if droplet.isSuspended {
                Label {
                    Text(verbatim: compact ? String(localized: "Blocked") : String(localized: "New agents are blocked until Cua Driver restarts"))
                } icon: {
                    Image(systemName: "hand.raised.fill")
                }
                .foregroundStyle(CuadriverStyle.warning)
            } else if hidden > 0 {
                Text(verbatim: compact
                     ? String(localized: "\(hidden) more")
                     : (hidden == 1
                        ? String(localized: "1 more agent. Stop every agent stops it too.")
                        : String(localized: "\(hidden) more agents. Stop every agent stops them too.")))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            } else if let shortcut = droplet.stopShortcut {
                let chord = CuadriverShortcutFormat.describe(shortcut)
                Text(verbatim: compact
                     ? String(localized: "\(chord) stops all")
                     : String(localized: "\(chord) stops every agent from anywhere"))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            } else {
                Text(verbatim: compact
                     ? String(localized: "Stop ends a session")
                     : String(localized: "Stopping ends a session. It never grants access."))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
}

// MARK: - Rows

struct CuadriverSessionRow: View {
    let session: AgentSession
    /// Beside another widget: the activity moves under the name, in place of
    /// the details, and the row keeps only its Stop at the trailing edge.
    var compact = false
    let isDriving: Bool
    let isStopping: Bool
    let isDisabled: Bool
    let primaryText: Color
    let stop: () -> Void

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            indicator
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: session.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(primaryText)
                    .truncationMode(.middle)
                Text(verbatim: compact ? activity : subtitle)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: DroppySpacing.sm)
            if !compact {
                Text(verbatim: activity)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isDriving ? primaryText : AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button(action: stop) {
                ZStack {
                    Image(systemName: isStopping ? "hourglass" : "stop.fill")
                        .font(.system(size: 8, weight: .bold))
                        .id(isStopping)
                        .transition(DroppyTransition.element)
                }
                .animation(DroppyAnimation.state, value: isStopping)
            }
            .buttonStyle(CuadriverStopButtonStyle())
            .disabled(isStopping || isDisabled)
            .help(session.label == nil ? String(localized: "Stop every agent") : String(localized: "Stop \(session.displayName)"))
            .accessibilityLabel(session.label == nil ? String(localized: "Stop every agent") : String(localized: "Stop \(session.displayName)"))
        }
    }

    /// A filled dot while it drives, an outline while it waits, red while it
    /// records the screen.
    private var indicator: some View {
        ZStack {
            if isDriving {
                Circle().fill(session.isRecording ? CuadriverStyle.recording : primaryText)
            } else {
                Circle().strokeBorder(AdaptiveColors.notchSurfaceTertiaryText, lineWidth: 1)
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)
    }

    private var subtitle: String {
        var parts: [String] = []
        if session.label != nil { parts.append(session.clientName) }
        if let started = session.startedSecondsAgo {
            parts.append(String(localized: "started \(CuadriverDuration.short(started)) ago"))
        }
        if session.isRecording { parts.append(String(localized: "recording")) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var activity: String {
        if isStopping { return String(localized: "Stopping") }
        if isDriving { return String(localized: "Driving") }
        guard session.idleSeconds != .max else { return String(localized: "Idle") }
        return String(localized: "Idle \(CuadriverDuration.short(session.idleSeconds))")
    }
}

/// A headline and the line under it, for every state without rows.
struct CuadriverMessage: View {
    let title: String
    let detail: String?
    var detailIsWarning = false
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: CuadriverWidgetMetrics.messageSpacing) {
            Text(verbatim: title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: CuadriverWidgetMetrics.headlineHeight, alignment: .leading)
            if let detail {
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundStyle(detailIsWarning ? CuadriverStyle.warning : AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(height: CuadriverWidgetMetrics.detailHeight, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Said in the header while the daemon lets agents act without asking.
struct CuadriverUnrestrictedBadge: View {
    let compact: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
            if !compact { Text("Unrestricted") }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(CuadriverStyle.warning)
        .help("Cua Driver runs in unrestricted mode: agents act without asking")
        .accessibilityLabel("Unrestricted mode")
    }
}

/// Droppy's 20pt glass disc, in its destructive tint: every Stop.
struct CuadriverStopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DroppyCircleButtonStyle(
            size: CuadriverWidgetMetrics.stopButtonSize,
            destructive: true,
            solidFill: nil,
            foregroundColorOverride: nil
        )
        .makeBody(configuration: configuration)
    }
}

// MARK: - Style and formatting

enum CuadriverStyle {
    static let warning = Color(red: 1.00, green: 0.62, blue: 0.04)
    static let recording = Color(red: 1.00, green: 0.27, blue: 0.23)
}

enum CuadriverDuration {
    /// "45s", "12m", "3h": the one largest unit, in the Mac's language.
    static func short(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let units: Set<Duration.UnitsFormatStyle.Unit> = clamped < 60 ? [.seconds] : (clamped < 3600 ? [.minutes] : [.hours])
        return Duration.seconds(clamped).formatted(
            .units(allowed: units, width: .narrow, maximumUnitCount: 1, fractionalPart: .hide(rounded: .down))
        )
    }
}

/// A recorded chord in the symbols macOS menus use: "⌃⌥⌘⎋".
enum CuadriverShortcutFormat {
    static func describe(_ shortcut: DropletKeyboardShortcut) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifiers)
        var text = ""
        if flags.contains(.control) { text += "\u{2303}" }
        if flags.contains(.option) { text += "\u{2325}" }
        if flags.contains(.shift) { text += "\u{21E7}" }
        if flags.contains(.command) { text += "\u{2318}" }
        return text + key(shortcut.keyCode)
    }

    private static func key(_ code: UInt16) -> String {
        if let name = names[code] { return name }
        return "#\(code)"
    }

    /// Virtual key codes on an ANSI layout.
    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "\u{21A9}", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "\u{21E5}", 49: "Space", 50: "`",
        51: "\u{232B}", 53: "\u{238B}", 117: "\u{2326}",
        115: "\u{2196}", 119: "\u{2198}", 116: "\u{21DE}", 121: "\u{21DF}",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
