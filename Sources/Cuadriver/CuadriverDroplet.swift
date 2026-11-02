//
//  CuadriverDroplet.swift
//  Cuadriver
//
//  Shows when an agent is driving the Mac through cua-driver, and stops it.
//
//  The droplet asks the local cua-driver daemon which sessions it is running,
//  every couple of seconds while one is acting and less often when nothing
//  is. While a session is driving, a live activity sits beside the notch; the
//  shelf widget lists every session with a Stop button; a card on the notch
//  says when an agent starts; and a global shortcut stops every agent from
//  anywhere. Stopping only ever revokes: nothing here can start a session or
//  grant one anything.
//
//  The work is one short socket read per poll and nothing in between: no
//  timer runs while the loop sleeps, nothing animates on its own, and the
//  notch and the shelf redraw only when what they show changes.
//

import AppKit
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
public enum DriverStatus: Equatable, Sendable {
    case connecting
    case offline
    case online
}

/// Where a Stop came from, which decides how it is confirmed: the shelf
/// shows its own result, a shortcut or a URL gets a card on the notch.
enum StopOrigin {
    case shelf
    case settings
    case shortcut
    case url

    var confirmsOnNotch: Bool {
        switch self {
        case .shortcut, .url: return true
        case .shelf, .settings: return false
        }
    }
}

@MainActor
public final class CuadriverDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "cuadriver"

    static let widgetID: ShelfWidgetID = "sessions"
    static let stopShortcutID = "stop-all"
    /// Control-Option-Command-Escape: escape the agent. Only a suggestion;
    /// Droppy drops it when the chord is already taken.
    static let defaultStopShortcut = DropletKeyboardShortcut(
        keyCode: 53,
        modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue
    )
    static let documentationURL = URL(string: "https://github.com/trycua/cua/tree/main/libs/cua-driver")!
    /// A session that drove, stopped for this long and drives again is
    /// announced again; one that only paused to think is not.
    static let reannounceAfter: TimeInterval = 120

    @Published private(set) var settings = CuadriverSettings()
    @Published public private(set) var status: DriverStatus = .connecting
    /// Sessions an agent opened. The implicit lease this droplet's own
    /// permission check creates is left out, and so is a session the daemon
    /// is already ending or that this droplet stopped.
    @Published public private(set) var sessions: [AgentSession] = []
    @Published public private(set) var info: DriverInfo?
    @Published public private(set) var permissions: DriverPermissions?
    @Published public private(set) var stopping: Set<String> = []
    /// Every agent was stopped, and the daemon refuses every call until it
    /// restarts.
    @Published private(set) var isSuspended = false
    /// What went wrong with the last Stop, for a few seconds.
    @Published private(set) var stopFailure: String?

    private(set) var host: DropletHost?
    private var client: DriverClient
    private var loopTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var isRefreshing = false
    private var kickPending = false
    private var detailsFetchedAt: Date?
    private var stopFailureAt: Date?
    /// Sessions this droplet stopped, and when. The daemon keeps listing a
    /// revoked session as active until it expires, so a stopped row stays
    /// hidden until the session acts again or leaves the list.
    private var stoppedAt: [String: Date] = [:]
    /// When each session was last seen driving, for telling a new start
    /// from a pause.
    private var lastDrivingAt: [String: Date] = [:]
    /// The next read only learns what is already running: the first after
    /// Droppy starts, the Mac wakes or the daemon comes up. Sessions in it
    /// are announced only if they have just started.
    private var quietNextRead = true
    private var observers: [NSObjectProtocol] = []
    private var socketWatcher: DispatchSourceFileSystemObject?
    /// Stops under way, cancelled with the droplet.
    private var actionTasks: [UUID: Task<Void, Never>] = [:]
    private var visibleSurfaces = 0
    /// Sessions in the last read that are this droplet's own lease, which
    /// revoking everything also ends but which no one would call an agent.
    private var ownLeaseCount = 0
    private var declaredWidgetHeight: CGFloat?
    private var isHarnessDemo = false
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)

    public init(client: DriverClient = DriverClient()) {
        self.client = client
        super.init()
    }

    var drivingSessions: [AgentSession] {
        sessions.filter { $0.isDriving(within: settings.drivingWindow.seconds) }
    }

    func isDriving(_ session: AgentSession) -> Bool {
        session.isDriving(within: settings.drivingWindow.seconds)
    }

    // MARK: Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host
        settings = host.preferences.value(forKey: Keys.settings, as: CuadriverSettings.self) ?? CuadriverSettings()
        registerStopShortcut()

        if host.environment.isHarness {
            // The harness shows sample sessions, unless asked to run against
            // a real daemon: CUADRIVER_LIVE=1 for this Mac's, and
            // CUADRIVER_SOCKET for a throwaway one started just for testing.
            let environment = ProcessInfo.processInfo.environment
            if let path = environment["CUADRIVER_SOCKET"], !path.isEmpty {
                client = DriverClient(socketPath: path)
            } else if environment["CUADRIVER_LIVE"] != "1" {
                showHarnessDemo()
                return
            }
        }

        observeSystem()
        watchSocketDirectory()
        startLoop()
        host.log.info("Cua Driver watching \(client.socketPath)")
    }

    /// Safe after a partial activation: everything it stops may be nil.
    public func deactivate() {
        loopTask?.cancel()
        loopTask = nil
        sleepTask?.cancel()
        sleepTask = nil
        for task in actionTasks.values { task.cancel() }
        actionTasks.removeAll()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        socketWatcher?.cancel()
        socketWatcher = nil
        host?.hud.dismiss(id: CuadriverHUD.drivingID)
        host?.hud.dismiss(id: CuadriverHUD.stoppedID)
        activitySubject.send(nil)
        stopping.removeAll()
        kickPending = false
        isRefreshing = false
        quietNextRead = true
        visibleSurfaces = 0
        host = nil
    }

    private enum Keys {
        static let settings = "settings"
    }

    // MARK: Settings

    func update(_ change: (inout CuadriverSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let previous = settings
        settings = next
        host?.preferences.setValue(next, forKey: Keys.settings)
        if next.drivingWindow != previous.drivingWindow {
            sessions.sort(by: Self.listOrder(window: next.drivingWindow.seconds))
        }
        publishActivity()
    }

    func binding<Value>(_ keyPath: WritableKeyPath<CuadriverSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }

    // MARK: The read loop

    /// Reads, sleeps for as long as the daemon's state calls for, reads
    /// again. Started once; `kick()` only cuts a sleep short, it never
    /// cancels a read in flight.
    private func startLoop() {
        guard host != nil, !isHarnessDemo else { return }
        guard loopTask == nil else {
            kick()
            return
        }
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.tick() else { return }
                if Task.isCancelled { return }
                guard delay > 0 else { continue }
                let sleeper = Task<Void, Never> { try? await Task.sleep(for: .seconds(delay)) }
                self?.sleepTask = sleeper
                await withTaskCancellationHandler {
                    await sleeper.value
                } onCancel: {
                    sleeper.cancel()
                }
                self?.sleepTask = nil
            }
        }
    }

    /// One read, then how long to wait before the next.
    private func tick() async -> Double {
        await refresh()
        if kickPending {
            kickPending = false
            return 0
        }
        return nextDelay
    }

    /// Quick while an agent drives, so Stop and the notch keep up; slower
    /// while sessions sit idle; slowest with no daemon, when the socket
    /// folder's watcher says the moment one starts.
    private var nextDelay: Double {
        switch status {
        case .online where !drivingSessions.isEmpty: return 2
        case .online where !sessions.isEmpty: return 3
        case .online: return 5
        case .offline, .connecting: return socketWatcher == nil ? 10 : 30
        }
    }

    /// Reads as soon as the current read, if any, has finished.
    func kick() {
        guard loopTask != nil else { return }
        if isRefreshing {
            kickPending = true
        } else {
            sleepTask?.cancel()
        }
    }

    private func refresh() async {
        guard host != nil, !isHarnessDemo, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let all = try await client.sessions()
            guard host != nil, !Task.isCancelled else { return }
            let cameOnline = status != .online
            if cameOnline {
                host?.log.info("cua-driver daemon reachable")
                detailsFetchedAt = nil
            }
            status = .online
            apply(all)
            if let stopFailureAt, Date().timeIntervalSince(stopFailureAt) > 6 {
                stopFailure = nil
                self.stopFailureAt = nil
            }
            if detailsAreStale {
                await refreshDetails()
            }
        } catch {
            guard host != nil, !Task.isCancelled else { return }
            if status != .offline {
                host?.log.info("cua-driver daemon unreachable: \(error)")
            }
            status = .offline
            sessions = []
            info = nil
            permissions = nil
            isSuspended = false
            detailsFetchedAt = nil
            stoppedAt.removeAll()
            lastDrivingAt.removeAll()
            quietNextRead = true
            if socketWatcher == nil { watchSocketDirectory() }
        }
        publishActivity()
        updateWidgetLayout()
    }

    /// Takes in one read of the daemon's sessions: what to list, and which
    /// sessions just started driving.
    private func apply(_ all: [AgentSession]) {
        let now = Date()
        let ids = Set(all.map(\.id))
        stoppedAt = stoppedAt.filter { ids.contains($0.key) }
        lastDrivingAt = lastDrivingAt.filter { ids.contains($0.key) }

        let window = settings.drivingWindow.seconds
        ownLeaseCount = all.filter(Self.isOwnLease).count
        let visible = all
            .filter { !Self.isOwnLease($0) }
            .filter { !$0.isEnding }
            .filter { session in
                guard let stopped = stoppedAt[session.id] else { return true }
                // Acted since it was stopped: a new session under the same label.
                return Double(session.idleSeconds) < now.timeIntervalSince(stopped) - 1
            }
            .sorted(by: Self.listOrder(window: window))

        var started: [AgentSession] = []
        for session in visible where session.isDriving(within: window) {
            let isNew: Bool
            if quietNextRead {
                isNew = (session.startedSecondsAgo ?? .max) <= 15
            } else if let last = lastDrivingAt[session.id] {
                isNew = now.timeIntervalSince(last) > Self.reannounceAfter
            } else {
                isNew = true
            }
            if isNew { started.append(session) }
            lastDrivingAt[session.id] = now
        }
        quietNextRead = false

        if sessions != visible { sessions = visible }
        if !started.isEmpty { announce(started) }
    }

    /// The lease this droplet's own permission check takes: implicit,
    /// unlabelled, from a direct client.
    static func isOwnLease(_ session: AgentSession) -> Bool {
        session.isImplicit && session.clientKind == "direct" && session.label == nil
    }

    /// Driving sessions first, then the newest. Both orders hold still from
    /// one read to the next, so rows do not trade places as agents act.
    static func listOrder(window: Int) -> (AgentSession, AgentSession) -> Bool {
        { a, b in
            let aDriving = a.isDriving(within: window), bDriving = b.isDriving(within: window)
            if aDriving != bDriving { return aDriving }
            let aStarted = a.startedSecondsAgo ?? .max, bStarted = b.startedSecondsAgo ?? .max
            if aStarted != bStarted { return aStarted < bStarted }
            return a.id < b.id
        }
    }

    // MARK: Driver details

    /// The version, mode and permissions change rarely, and only the widget
    /// and Settings show them: read them when the daemon comes up, when one
    /// of those comes on screen, and every half minute while one is there.
    private var detailsAreStale: Bool {
        guard let detailsFetchedAt else { return true }
        return visibleSurfaces > 0 && Date().timeIntervalSince(detailsFetchedAt) > 30
    }

    private func refreshDetails() async {
        detailsFetchedAt = Date()
        let info = try? await client.info()
        var permissions: DriverPermissions?
        var suspended = false
        do {
            permissions = try await client.permissions()
        } catch DriverClientError.suspended {
            suspended = true
        } catch {
            host?.log.debug("Permission check failed: \(error)")
        }
        guard host != nil, status == .online else { return }
        if suspended != isSuspended {
            if suspended { host?.log.notice("cua-driver refuses every call until it restarts (stopped with Stop every agent)") }
            isSuspended = suspended
        }
        if let info, info != self.info {
            if self.info == nil {
                host?.log.info("cua-driver \(info.version ?? "unknown version"), \(info.permissionMode?.rawValue ?? "unknown") mode")
            }
            self.info = info
        }
        if let permissions, permissions != self.permissions { self.permissions = permissions }
    }

    /// A widget or the settings pane came on screen: bring it up to date.
    func surfaceDidAppear() {
        visibleSurfaces += 1
        if let detailsFetchedAt, Date().timeIntervalSince(detailsFetchedAt) > 10 {
            self.detailsFetchedAt = nil
        }
        kick()
    }

    func surfaceDidDisappear() {
        visibleSurfaces = max(0, visibleSurfaces - 1)
    }

    // MARK: System

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // What ran while the Mac slept is caught up, not announced.
                self?.quietNextRead = true
                self?.kick()
            }
        })
    }

    /// Watches the daemon's socket folder, so the widget notices the daemon
    /// starting or stopping at once instead of at the next slow poll.
    private func watchSocketDirectory() {
        guard socketWatcher == nil, host != nil, !isHarnessDemo else { return }
        let directory = (client.socketPath as NSString).deletingLastPathComponent
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.socketDirectoryChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        socketWatcher = source
        source.resume()
    }

    private func socketDirectoryChanged() {
        guard let watcher = socketWatcher else { return }
        // The pid file or the socket changed: the daemon may have restarted
        // between two reads, so read its details again too.
        detailsFetchedAt = nil
        if !watcher.data.isDisjoint(with: [.delete, .rename]) {
            // The folder itself went away: watch again once it is back.
            watcher.cancel()
            socketWatcher = nil
        }
        kick()
    }

    // MARK: Stopping

    /// Stop one session, or every session when it has no label to name it by.
    func stop(_ session: AgentSession, origin: StopOrigin = .shelf) {
        guard let label = session.label else { return stopAll(origin: origin) }
        guard !stopping.contains(session.id) else { return }
        if isHarnessDemo {
            withAnimation(DroppyAnimation.listChange) { sessions.removeAll { $0.id == session.id } }
            didStop(count: 1, origin: origin)
            return
        }
        stopping.insert(session.id)
        runAction { droplet in
            do {
                try await droplet.client.revoke(session: label)
                droplet.stoppedAt[session.id] = Date()
                withAnimation(DroppyAnimation.listChange) { droplet.sessions.removeAll { $0.id == session.id } }
                droplet.host?.log.info("Stopped session \(label)")
                droplet.didStop(count: 1, origin: origin)
            } catch {
                droplet.stopFailed(error, what: label, origin: origin)
            }
            droplet.stopping.remove(session.id)
        }
    }

    /// Stop and revoke every session the daemon is running.
    func stopAll(origin: StopOrigin) {
        if isHarnessDemo {
            let count = sessions.count
            withAnimation(DroppyAnimation.listChange) { sessions.removeAll() }
            isSuspended = true
            didStop(count: count, origin: origin)
            return
        }
        let targets = Set(sessions.map(\.id))
        stopping.formUnion(targets)
        runAction { droplet in
            do {
                let revoked = try await droplet.client.revokeAll()
                let now = Date()
                for id in targets { droplet.stoppedAt[id] = now }
                withAnimation(DroppyAnimation.listChange) { droplet.sessions.removeAll { targets.contains($0.id) } }
                droplet.isSuspended = true
                droplet.host?.log.info("Stopped every cua-driver session (\(revoked) revoked); new calls are refused until the driver restarts")
                // The daemon's count includes this droplet's own lease, and any
                // agent that started since the last read.
                droplet.didStop(count: max(targets.count, revoked - droplet.ownLeaseCount), origin: origin)
            } catch {
                droplet.stopFailed(error, what: nil, origin: origin)
            }
            droplet.stopping.subtract(targets)
        }
    }

    /// Runs a Stop on the main actor, kept so `deactivate()` can cancel it,
    /// then reads the daemon again.
    private func runAction(_ work: @escaping @MainActor (CuadriverDroplet) async -> Void) {
        let key = UUID()
        actionTasks[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            await work(self)
            self.actionTasks[key] = nil
            guard self.host != nil else { return }
            self.publishActivity()
            self.updateWidgetLayout()
            self.kick()
        }
    }

    private func didStop(count: Int, origin: StopOrigin) {
        stopFailure = nil
        stopFailureAt = nil
        host?.feedback.play(.success)
        publishActivity()
        updateWidgetLayout()
        guard origin.confirmsOnNotch, let host, host.isGranted(.hud) else { return }
        host.hud.dismiss(id: CuadriverHUD.drivingID)
        host.hud.present(CuadriverHUD.stopped(count: count))
    }

    private func stopFailed(_ error: Error, what label: String?, origin: StopOrigin) {
        let message: String
        if case DriverClientError.notRunning = error {
            message = String(localized: "Cua Driver is not running.")
        } else {
            message = String(localized: "Could not stop. Try again.")
        }
        stopFailure = message
        stopFailureAt = Date()
        host?.feedback.play(.failure)
        host?.log.error("Stopping \(label ?? "every session") failed: \(error)")
        guard origin.confirmsOnNotch, let host, host.isGranted(.hud) else { return }
        host.hud.present(CuadriverHUD.stopFailed())
    }

    // MARK: Shortcut

    private func registerStopShortcut() {
        guard let host, host.isGranted(.globalShortcuts) else { return }
        host.shortcuts.register(
            id: Self.stopShortcutID,
            title: String(localized: "Stop every Cua Driver agent"),
            defaultShortcut: Self.defaultStopShortcut
        ) { [weak self] in
            self?.stopAll(origin: .shortcut)
        }
    }

    /// The chord the stop shortcut is bound to right now, if any.
    var stopShortcut: DropletKeyboardShortcut? {
        host?.shortcuts.currentShortcut(id: Self.stopShortcutID)
    }

    var canUseShortcuts: Bool { host?.isGranted(.globalShortcuts) ?? false }

    func openShortcuts() {
        _ = host?.workspace.openShortcuts()
    }

    func openSettings() {
        _ = host?.workspace.openSettings()
    }

    func openDocumentation() {
        if host?.workspace.open(Self.documentationURL) != true {
            host?.log.notice("Opening the cua-driver documentation was refused")
        }
    }

    // MARK: Announcing

    /// A card on the notch for sessions that just started driving: one card
    /// however many started in the same read.
    private func announce(_ started: [AgentSession]) {
        guard settings.announcesAgents, let host, host.isGranted(.hud) else { return }
        if !host.hud.present(CuadriverHUD.driving(started)) {
            // Not an error: Droppy's own HUD or the open shelf has the notch,
            // and the live activity already says it.
            host.log.debug("Agent card not shown")
        }
    }

    // MARK: Live activity state

    private func publishActivity() {
        let driving = drivingSessions
        guard settings.showsInNotch, !driving.isEmpty else {
            if activitySubject.value != nil { activitySubject.send(nil) }
            return
        }
        // One stable state while agents drive: priority and isInteractive
        // never change, only the title does.
        let state = LiveActivityState(
            priority: 150,
            accessibilityTitle: Self.activityTitle(driving),
            isInteractive: false,
            joinsPersistentActivitySet: true,
            compactPresentation: nil,
            expandedWidgetID: Self.widgetID.rawValue
        )
        if activitySubject.value != state { activitySubject.send(state) }
    }

    static func activityTitle(_ driving: [AgentSession]) -> String {
        driving.count == 1
            ? String(localized: "\(driving[0].displayName) is driving your Mac")
            : String(localized: "\(driving.count) agents are driving your Mac")
    }

    /// The short text in the trailing wing.
    var compactLabel: String {
        let driving = drivingSessions
        switch driving.count {
        case 0: return ""
        case 1: return driving[0].compactName ?? String(localized: "Agent")
        default: return "\u{00D7}\(driving.count)"
        }
    }

    var isAnyDrivingSessionRecording: Bool {
        drivingSessions.contains(where: \.isRecording)
    }

    // MARK: Widget layout

    var widgetContentHeight: CGFloat {
        CuadriverWidgetMetrics.contentHeight(for: widgetLayout)
    }

    var widgetLayout: CuadriverWidgetLayout {
        switch status {
        case .online where !sessions.isEmpty:
            return .rows(min(sessions.count, CuadriverWidgetMetrics.maxRows))
        default:
            return .message
        }
    }

    /// Asks the shelf to measure the widget again when the number of rows
    /// changes, and only then.
    private func updateWidgetLayout() {
        let height = widgetContentHeight
        guard height != declaredWidgetHeight else { return }
        let first = declaredWidgetHeight == nil
        declaredWidgetHeight = height
        if !first { host?.shelf.invalidateLayout(for: Self.widgetID) }
    }

    // MARK: Harness

    /// In the development harness, sessions to look at instead of whatever
    /// the daemon on this Mac is doing. Never sent anywhere. Set
    /// `CUADRIVER_LIVE=1` to run the harness against the real daemon.
    func showHarnessDemo() {
        isHarnessDemo = true
        status = .online
        info = DriverInfo(version: "0.38.0", pid: 4242, permissionMode: .standard)
        permissions = DriverPermissions(accessibility: true, screenRecording: true)
        sessions = CuadriverDemo.sessions.sorted(by: Self.listOrder(window: settings.drivingWindow.seconds))
        declaredWidgetHeight = widgetContentHeight
        publishActivity()

        // And an agent starting, kept up for as long as the harness looks.
        if let host, host.isGranted(.hud), let first = drivingSessions.first {
            host.hud.present(CuadriverHUD.driving([first], duration: nil))
        }
    }
}

/// Sessions for the harness: one agent driving and recording, one that
/// paused, and a script that finished a while ago.
enum CuadriverDemo {
    static let sessions: [AgentSession] = [
        AgentSession(
            label: "claude-code",
            ownerShortID: "a41f09c2",
            clientKind: "mcp",
            transport: "mcp_stdio",
            idleSeconds: 1,
            startedSecondsAgo: 734,
            expiresInSeconds: 299,
            isRecording: true,
            isCursorVisible: true
        ),
        AgentSession(
            label: "codex",
            ownerShortID: "7be3d118",
            clientKind: "mcp",
            transport: "mcp_stdio",
            idleSeconds: 95,
            startedSecondsAgo: 2_410,
            expiresInSeconds: 205
        ),
        AgentSession(
            label: "nightly-qa",
            ownerShortID: "c0ffee42",
            clientKind: "python_sdk",
            transport: "daemon",
            idleSeconds: 1_260,
            startedSecondsAgo: 5_400,
            expiresInSeconds: 40
        ),
    ]
}

// MARK: - Shelf widget

extension CuadriverDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: Self.widgetID,
                title: "Cua Driver",
                systemImage: "cursorarrow.rays",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: CuadriverWidgetMetrics.soloWidth,
                    preferredPairedWidth: CuadriverWidgetMetrics.pairedWidth,
                    minimumWidth: CuadriverWidgetMetrics.minimumWidth,
                    contentHeight: .fixed(widgetContentHeight)
                ),
                searchKeywords: ["agent", "cua", "computer use", "automation", "stop", "claude", "codex", "mcp"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(CuadriverWidget(droplet: self, context: context))
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
        AnyView(CuadriverCompactLeading(droplet: self))
    }

    public func makeCompactTrailing() -> AnyView {
        AnyView(CuadriverCompactTrailing(droplet: self))
    }

    /// Not mounted by Droppy: hovering or clicking the row opens the shelf,
    /// where the widget and its Stop buttons are.
    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        AnyView(EmptyView())
    }

    public func makeCompanionCompact(context: CompactLiveActivityContext) -> AnyView {
        AnyView(CuadriverCompanionMark(droplet: self, slot: context.slotSize))
    }

    public func makeCompanionDetail(context: LiveActivityContext) -> AnyView? { nil }
}

// MARK: - HUD

/// An agent starting and a Stop from the keyboard are announced with
/// Droppy's own card (`host.hud`); the `hud` capability is what lets it.
extension CuadriverDroplet: HUDPresenting {}

// MARK: - Settings

extension CuadriverDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(CuadriverSettingsPane(droplet: self))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(title: "Cua Driver", keywords: ["agent", "computer use", "cua", "automation", "mcp"]),
            SettingsSearchEntry(title: "Show in the notch", keywords: ["live activity", "notch", "driving"]),
            SettingsSearchEntry(title: "Announce new agents", keywords: ["card", "notification", "alert", "hud"]),
            SettingsSearchEntry(title: "Driving lasts", keywords: ["idle", "timeout", "window", "pause"]),
            SettingsSearchEntry(title: "Stop every agent", keywords: ["shortcut", "hotkey", "panic", "revoke", "kill"]),
            SettingsSearchEntry(title: "Permissions", keywords: ["accessibility", "screen recording", "grant"]),
        ]
    }
}

// MARK: - URLs

/// `droppy://droplet/cuadriver/stop` stops every agent, for a script, a
/// Shortcut or a launcher. Stopping is the only thing a URL can do here: the
/// scheme is open to every app on the Mac, and revoking grants nothing.
extension CuadriverDroplet: DropletURLHandling {
    public func handle(_ request: DropletURLRequest) {
        switch request.path.lowercased() {
        case "stop", "stop-all":
            stopAll(origin: .url)
        default:
            host?.log.notice("Ignored a URL for an unknown path: \(request.path)")
        }
    }
}
