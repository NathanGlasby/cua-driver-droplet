//
//  CuadriverSettings.swift
//  Cuadriver
//
//  What the user chose, saved through Droppy's preferences for this droplet.
//  Decoded field by field, so a setting added in a later version never resets
//  the ones already saved.
//

import Foundation

struct CuadriverSettings: Codable, Equatable, Sendable {
    /// The live activity beside the notch while an agent drives.
    var showsInNotch = true
    /// A card on the notch when an agent starts driving.
    var announcesAgents = true
    /// How long after its last action a session still counts as driving.
    var drivingWindow = DrivingWindow.thirtySeconds

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CuadriverSettings()
        showsInNotch = (try? container.decode(Bool.self, forKey: .showsInNotch)) ?? defaults.showsInNotch
        announcesAgents = (try? container.decode(Bool.self, forKey: .announcesAgents)) ?? defaults.announcesAgents
        drivingWindow = (try? container.decode(DrivingWindow.self, forKey: .drivingWindow)) ?? defaults.drivingWindow
    }

    private enum CodingKeys: String, CodingKey {
        case showsInNotch, announcesAgents, drivingWindow
    }
}

/// How long an agent that paused, usually to think, still counts as driving.
/// Long enough that the notch does not flicker between two actions, short
/// enough that it clears soon after the agent is done.
enum DrivingWindow: Int, CaseIterable, Codable, Sendable {
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120

    var seconds: Int { rawValue }

    var title: String {
        switch self {
        case .fifteenSeconds: return String(localized: "15 seconds")
        case .thirtySeconds: return String(localized: "30 seconds")
        case .oneMinute: return String(localized: "1 minute")
        case .twoMinutes: return String(localized: "2 minutes")
        }
    }
}
