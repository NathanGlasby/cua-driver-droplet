//
//  CuadriverSettingsPane.swift
//  Cuadriver
//
//  Cua Driver's page in Droppy's Settings. Rooted in `DropletSettingsPane`,
//  so every row is the grouped Form's own: the driver at a glance first, then
//  what goes on the notch, then how to stop every agent at once.
//
//  Droppy draws the page's header (icon, name, summary) above this; the pane
//  starts with its first setting.
//

import DroppyKit
import SwiftUI

struct CuadriverSettingsPane: View {
    @ObservedObject var droplet: CuadriverDroplet

    private var settings: CuadriverSettings { droplet.settings }

    var body: some View {
        DropletSettingsPane {
            driverCard
            notchSection
            stopSection
            DropletSettingsSection {
                settingsSectionHeader("Help")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(
                        title: "Documentation",
                        infoTip: "Installing cua-driver, starting it and connecting an agent."
                    ) {
                        Button("Open") { droplet.openDocumentation() }
                    }
                }
            }
        }
        .onAppear { droplet.surfaceDidAppear() }
        .onDisappear { droplet.surfaceDidDisappear() }
    }

    // MARK: Driver

    private var driverCard: some View {
        DropletSettingsCard {
            DropletControlRow(title: "Driver") {
                DropletValuePill(text: driverText)
            }
            if droplet.status == .offline {
                DropletStackedRow(title: "Start it in Terminal") {
                    Text(verbatim: "cua-driver serve")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            if droplet.status == .online, droplet.isSuspended {
                DropletStackedRow(
                    title: "Agents are blocked",
                    infoTip: "Stop every agent also refuses every new call until Cua Driver restarts. Restart it in Terminal to let agents back in."
                ) {
                    Text(verbatim: "cua-driver stop && cua-driver serve")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            if droplet.status == .online {
                DropletControlRow(
                    title: "Permission mode",
                    infoTip: modeTip
                ) {
                    DropletValuePill(text: modeText)
                }
                if !droplet.isSuspended {
                    DropletControlRow(title: "Accessibility") {
                        DropletValuePill(text: permissionText(droplet.permissions?.accessibility))
                    }
                    DropletControlRow(title: "Screen Recording") {
                        DropletValuePill(text: permissionText(droplet.permissions?.screenRecording))
                    }
                }
                if let permissions = droplet.permissions, !permissions.isReady {
                    DropletStackedRow(
                        title: "Grant them in Terminal",
                        infoTip: "Cua Driver asks for each permission as itself, so macOS shows its own name in the prompts."
                    ) {
                        Text(verbatim: "cua-driver permissions grant")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
                DropletControlRow(
                    title: agentsTitle,
                    infoTip: "Stop all ends every session and blocks new ones until Cua Driver restarts."
                ) {
                    Button("Stop all") { droplet.stopAll(origin: .settings) }
                        .disabled(droplet.sessions.isEmpty || !droplet.stopping.isEmpty)
                }
            }
        }
    }

    private var driverText: String {
        switch droplet.status {
        case .connecting:
            return String(localized: "Connecting")
        case .offline:
            return String(localized: "Not running")
        case .online:
            let state = droplet.isSuspended ? String(localized: "Blocked") : String(localized: "Running")
            if let version = droplet.info?.version {
                return state + " \u{00B7} " + version
            }
            return state
        }
    }

    private var modeText: String {
        switch droplet.info?.permissionMode {
        case .standard: return String(localized: "Standard")
        case .bounded: return String(localized: "Bounded")
        case .unrestricted: return String(localized: "Unrestricted")
        case nil: return String(localized: "Unknown")
        }
    }

    private var modeTip: String {
        switch droplet.info?.permissionMode {
        case .unrestricted:
            return String(localized: "Agents act without asking. Restart the driver without --dangerously-bypass-approvals to turn this off.")
        case .bounded:
            return String(localized: "A capability manifest limits what agents can do.")
        default:
            return String(localized: "Risky actions need your approval first.")
        }
    }

    private func permissionText(_ granted: Bool?) -> String {
        switch granted {
        case true?: return String(localized: "Allowed")
        case false?: return String(localized: "Not allowed")
        case nil: return String(localized: "Checking")
        }
    }

    private var agentsTitle: String {
        let total = droplet.sessions.count
        let driving = droplet.drivingSessions.count
        switch (total, driving) {
        case (0, _): return String(localized: "No agents")
        case (1, 1): return String(localized: "1 agent, driving")
        case (1, _): return String(localized: "1 agent, idle")
        case (_, 0): return String(localized: "\(total) agents, all idle")
        default: return String(localized: "\(total) agents, \(driving) driving")
        }
    }

    // MARK: Notch

    private var notchSection: some View {
        DropletSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("Notch")
                Text("What shows on the notch while an agent drives your Mac.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } content: {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Show in the notch",
                    subtitle: "The agent's name beside the notch for as long as it drives.",
                    isOn: droplet.binding(\.showsInNotch)
                )
                DropletToggleRow(
                    title: "Announce new agents",
                    subtitle: "A card on the notch when an agent starts driving.",
                    isOn: droplet.binding(\.announcesAgents)
                )
                settingsUnifiedPickerRow(
                    title: "Driving lasts",
                    subtitle: "How long after its last action an agent still counts as driving. Agents often pause to think.",
                    options: DrivingWindow.allCases,
                    groupPosition: .bottom,
                    isSelected: { $0 == settings.drivingWindow },
                    action: { window in droplet.update { $0.drivingWindow = window } }
                ) { option, isSelected, isEnabled in
                    settingsUnifiedSegmentLabel(icon: "", title: option.title, isSelected: isSelected, isEnabled: isEnabled)
                }
            }
        }
    }

    // MARK: Stop

    private var stopSection: some View {
        DropletSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("Stop every agent")
                Text("Ends every session and blocks new ones until Cua Driver restarts. Stopping never grants an agent anything.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } content: {
            DropletSettingsCard {
                DropletControlRow(
                    title: "Keyboard shortcut",
                    infoTip: "Works from any app, even with the shelf closed. Set it on Droppy's Shortcuts page."
                ) {
                    HStack(spacing: DroppySpacing.sm) {
                        DropletValuePill(text: shortcutText)
                        Button("Change") { droplet.openShortcuts() }
                            .disabled(!droplet.canUseShortcuts)
                    }
                }
                DropletStackedRow(
                    title: "From a script or a Shortcut",
                    infoTip: "Opening this address stops every agent, the same as the shortcut."
                ) {
                    Text(verbatim: "droppy://droplet/cuadriver/stop")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var shortcutText: String {
        guard droplet.canUseShortcuts else { return String(localized: "Not allowed") }
        guard let shortcut = droplet.stopShortcut else { return String(localized: "None") }
        return CuadriverShortcutFormat.describe(shortcut)
    }
}
