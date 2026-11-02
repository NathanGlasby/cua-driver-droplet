//
//  CuadriverHUD.swift
//  Cuadriver
//
//  The cards Cua Driver puts on the notch: an agent starting to drive the
//  Mac, and the answer to a Stop pressed from the keyboard. Droppy grows the
//  card out of the notch, sizes it and folds it away; these views only say
//  what is on it.
//

import DroppyKit
import SwiftUI

enum CuadriverHUD {
    static let drivingID = "cuadriver.driving"
    static let stoppedID = "cuadriver.stopped"

    /// Long enough to look up and read a name, the way Droppy's own
    /// connection cards stay.
    static let drivingDuration: TimeInterval = 5
    static let stoppedDuration: TimeInterval = 2.5

    /// One card for every session that started in the same read.
    static func driving(_ sessions: [AgentSession], duration: TimeInterval? = drivingDuration) -> DropletHUDRequest {
        let notice = DrivingNotice(sessions: sessions)
        return DropletHUDRequest(
            id: drivingID,
            duration: duration,
            priority: .normal,
            accessibilityLabel: notice.accessibilityLabel,
            isExpanded: true,
            expandedContentHeight: CuadriverHUDMetrics.cardContentHeight
        ) {
            CuadriverStrip(symbol: "cursorarrow.rays", text: notice.shortTitle)
        } expanded: {
            DrivingCard(notice: notice)
        }
    }

    /// The answer to a Stop from the shortcut or a URL, where nothing else
    /// on screen shows it.
    static func stopped(count: Int) -> DropletHUDRequest {
        let text: String
        switch count {
        case 0: text = String(localized: "None running")
        case 1: text = String(localized: "Stopped")
        default: text = String(localized: "Stopped \(count)")
        }
        let stopped = count == 0
            ? String(localized: "No agents were running")
            : (count == 1 ? String(localized: "Stopped 1 agent") : String(localized: "Stopped \(count) agents"))
        let label = stopped + ". " + String(localized: "New agents are blocked until Cua Driver restarts.")
        return DropletHUDRequest(id: stoppedID, duration: stoppedDuration, priority: .high, accessibilityLabel: label) {
            CuadriverStrip(symbol: "stop.circle.fill", text: text)
        }
    }

    static func stopFailed() -> DropletHUDRequest {
        DropletHUDRequest(
            id: stoppedID,
            duration: stoppedDuration,
            priority: .high,
            accessibilityLabel: String(localized: "Could not stop the agents")
        ) {
            CuadriverStrip(symbol: "exclamationmark.triangle.fill", text: String(localized: "Not stopped"))
        }
    }
}

/// What the card says about the sessions that just started.
struct DrivingNotice: Equatable {
    var names: [String]
    var shortNames: [String?]

    init(sessions: [AgentSession]) {
        names = sessions.map(\.displayName)
        shortNames = sessions.map(\.compactName)
    }

    /// The bold line.
    var title: String {
        names.count == 1 ? names[0] : String(localized: "\(names.count) agents")
    }

    /// The strip's text, for a host that shows the at-rest shape: the same
    /// short name the live activity uses.
    var shortTitle: String {
        guard names.count == 1 else { return "\u{00D7}\(names.count)" }
        return shortNames[0] ?? String(localized: "Agent")
    }

    /// The line over it, short enough for the island's narrower card.
    var subtitle: String {
        String(localized: "Now driving your Mac")
    }

    var accessibilityLabel: String {
        names.count == 1
            ? String(localized: "\(names[0]) started driving your Mac")
            : String(localized: "\(names.formatted(.list(type: .and))) started driving your Mac")
    }
}

/// The card's numbers: a 44pt tile, 16 to the text, a 12pt line over a 14pt
/// bold one, 44 tall, the row Droppy reserves for an icon on its own cards.
enum CuadriverHUDMetrics {
    static let cardContentHeight: CGFloat = 44
    static let tileSize: CGFloat = 44
    static let innerSpacing: CGFloat = DroppySpacing.lg
    static let lineSpacing: CGFloat = 2
}

private struct DrivingCard: View {
    let notice: DrivingNotice

    var body: some View {
        HStack(spacing: CuadriverHUDMetrics.innerSpacing) {
            CuadriverTile(symbol: "cursorarrow.rays", side: CuadriverHUDMetrics.tileSize)
            VStack(alignment: .leading, spacing: CuadriverHUDMetrics.lineSpacing) {
                Text(verbatim: notice.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                Text(verbatim: notice.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: notice.accessibilityLabel))
    }
}

/// A round tile with the droplet's glyph, raised off the card.
struct CuadriverTile: View {
    let symbol: String
    let side: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(AdaptiveColors.notchSurfaceCardFill)
            Image(systemName: symbol)
                .font(.system(size: side * 0.42, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// The strip: a glyph at the far left, a word at the far right, nothing over
/// the camera between them.
struct CuadriverStrip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
            Spacer(minLength: 0)
            Text(verbatim: text)
                .font(.system(size: DroppyLiveActivityMetrics.labelFontSize))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
