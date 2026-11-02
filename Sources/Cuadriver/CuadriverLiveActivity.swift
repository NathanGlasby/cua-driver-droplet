//
//  CuadriverLiveActivity.swift
//  Cuadriver
//
//  Beside the notch while an agent drives: the cursor glyph in the leading
//  wing, a record mark instead while that agent records the screen, and in
//  the trailing wing the agent's name or how many are driving. Droppy places
//  both wings and runs every motion around them; these views only change what
//  they show, with Droppy's own transition.
//

import DroppyKit
import SwiftUI

struct CuadriverCompactLeading: View {
    @ObservedObject var droplet: CuadriverDroplet

    var body: some View {
        let recording = droplet.isAnyDrivingSessionRecording
        ZStack {
            Image(systemName: recording ? "record.circle" : "cursorarrow.rays")
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .id(recording)
                .transition(DroppyTransition.compactContent)
        }
        .animation(DroppyAnimation.state, value: recording)
        .accessibilityHidden(true)
    }
}

struct CuadriverCompactTrailing: View {
    @ObservedObject var droplet: CuadriverDroplet

    var body: some View {
        let label = droplet.compactLabel
        ZStack {
            Text(verbatim: label)
                // Droppy's compact value face: the 12pt its own statuses print in.
                .font(.system(size: DroppyLiveActivityMetrics.labelFontSize))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .id(label)
                .transition(DroppyTransition.compactContent)
        }
        .animation(DroppyAnimation.state, value: label)
        .accessibilityHidden(true)
    }
}

/// The round bubble beside the notch, for when another activity holds it.
/// Drawn for the square Droppy hands it, with a count badge when more than
/// one agent drives.
struct CuadriverCompanionMark: View {
    @ObservedObject var droplet: CuadriverDroplet
    let slot: CGSize

    var body: some View {
        let side = min(slot.width, slot.height)
        let count = droplet.drivingSessions.count
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: droplet.isAnyDrivingSessionRecording ? "record.circle" : "cursorarrow.rays")
                .font(.system(size: side * 0.62, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .frame(width: side, height: side)
            if count > 1 {
                Text(verbatim: "\(count)")
                    .font(.system(size: max(8, side * 0.36), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
