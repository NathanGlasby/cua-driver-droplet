//
//  DriverClient.swift
//  Cuadriver
//
//  Talks to the local cua-driver daemon over its Unix socket. The daemon
//  speaks one JSON object per line: `{"method": ..., ...}` in, and
//  `{"ok": true, "result": ...}` or `{"ok": false, "error": ...}` out.
//
//  Every call blocks a thread on the socket, so it runs on a private serial
//  queue with short send and receive timeouts, never on the main actor.
//
//  Only the methods below are ever sent. They read what the daemon is doing,
//  or revoke sessions; nothing here can start a session, grant a permission
//  or act on the desktop.
//

import Darwin
import Foundation

/// One agent session the daemon is running, without any content.
public struct AgentSession: Identifiable, Equatable, Sendable {
    /// Public session label, or nil for a session that never named itself.
    public let label: String?
    public let ownerShortID: String
    /// `mcp`, `direct`, `cli`, `python_sdk`, `typescript_sdk`.
    public let clientKind: String
    /// `mcp_stdio`, `mcp_http`, `daemon`, `cli`.
    public let transport: String
    /// `active`, or `ending` once the daemon is tearing it down.
    public let state: String
    public let isImplicit: Bool
    public let idleSeconds: Int
    public let startedSecondsAgo: Int?
    public let expiresInSeconds: Int?
    public let isRecording: Bool
    public let isCursorVisible: Bool

    public init(
        label: String?,
        ownerShortID: String,
        clientKind: String,
        transport: String = "",
        state: String = "active",
        isImplicit: Bool = false,
        idleSeconds: Int,
        startedSecondsAgo: Int? = nil,
        expiresInSeconds: Int? = nil,
        isRecording: Bool = false,
        isCursorVisible: Bool = false
    ) {
        self.label = label
        self.ownerShortID = ownerShortID
        self.clientKind = clientKind
        self.transport = transport
        self.state = state
        self.isImplicit = isImplicit
        self.idleSeconds = idleSeconds
        self.startedSecondsAgo = startedSecondsAgo
        self.expiresInSeconds = expiresInSeconds
        self.isRecording = isRecording
        self.isCursorVisible = isCursorVisible
    }

    public var id: String { "\(ownerShortID)/\(label ?? "implicit")/\(clientKind)" }

    /// The daemon is already ending it: Stop has nothing left to do.
    public var isEnding: Bool { state == "ending" }

    /// The session acted within the last `window` seconds.
    public func isDriving(within window: Int) -> Bool { idleSeconds <= window }

    /// What to call the session in a row: its label, or what kind of client it is.
    public var displayName: String {
        if let label, !label.isEmpty { return label }
        return clientName
    }

    /// The kind of client, in words.
    public var clientName: String {
        switch clientKind {
        case "mcp": return String(localized: "MCP agent")
        case "cli": return String(localized: "Command line")
        case "direct": return String(localized: "Direct client")
        case "python_sdk": return String(localized: "Python SDK")
        case "typescript_sdk": return String(localized: "TypeScript SDK")
        default: return clientKind.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// A name short enough for the notch's trailing wing, which holds about
    /// eight characters: the label, or its first word ("claude" for
    /// "claude-code"), or nil when neither fits.
    public var compactName: String? {
        guard let label, !label.isEmpty else { return nil }
        if label.count <= Self.compactNameLimit { return label }
        let first = label.split(whereSeparator: { "-_ .:/".contains($0) }).first.map(String.init) ?? ""
        return (2...Self.compactNameLimit).contains(first.count) ? first : nil
    }

    static let compactNameLimit = 8
}

/// Accessibility and Screen Recording, as the daemon's own identity sees them.
public struct DriverPermissions: Equatable, Sendable {
    public let accessibility: Bool
    public let screenRecording: Bool

    public init(accessibility: Bool, screenRecording: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    public var isReady: Bool { accessibility && screenRecording }
}

/// How much an agent may do without asking, as the daemon was started.
public enum DriverPermissionMode: String, Sendable {
    /// Risky actions need a grant.
    case standard
    /// A capability manifest caps what agents may call.
    case bounded
    /// Everything is allowed without asking.
    case unrestricted
}

/// The daemon itself: its version, and the mode it was started in.
public struct DriverInfo: Equatable, Sendable {
    public let version: String?
    public let pid: Int?
    public let permissionMode: DriverPermissionMode?

    public init(version: String?, pid: Int?, permissionMode: DriverPermissionMode?) {
        self.version = version
        self.pid = pid
        self.permissionMode = permissionMode
    }
}

public enum DriverClientError: Error, CustomStringConvertible, Equatable {
    case socketPathTooLong
    case notRunning(Int32)
    case io(Int32)
    case timedOut
    case badResponse
    case daemon(String)
    /// Every call is refused until the daemon restarts: someone stopped
    /// every agent.
    case suspended
    /// The daemon's rules refused the call, with its refusal code.
    case refused(String)

    public var description: String {
        switch self {
        case .socketPathTooLong: "socket path too long"
        case .notRunning(let code): "daemon not reachable (errno \(code))"
        case .io(let code): "socket I/O failed (errno \(code))"
        case .timedOut: "daemon did not answer in time"
        case .badResponse: "unreadable daemon response"
        case .daemon(let message): message
        case .suspended: "authorization suspended until the daemon restarts"
        case .refused(let code): "refused (\(code))"
        }
    }
}

public final class DriverClient: @unchecked Sendable {
    public let socketPath: String
    private let queue = DispatchQueue(label: "cuadriver.socket", qos: .utility)
    private let timeout: TimeInterval

    public init(socketPath: String = DriverClient.defaultSocketPath, timeout: TimeInterval = 1.5) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    /// The real user's home, even if the host process has a container home.
    public static var realHomeDirectory: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// The folder the daemon keeps its socket and pid file in.
    public static var defaultSocketDirectory: String {
        realHomeDirectory + "/Library/Caches/cua-driver"
    }

    /// `~/Library/Caches/cua-driver/cua-driver.sock`.
    public static var defaultSocketPath: String {
        defaultSocketDirectory + "/cua-driver.sock"
    }

    // MARK: Calls

    /// Every session the daemon owns, from every client.
    public func sessions() async throws -> [AgentSession] {
        let result = try await request(["method": "sessions_list"])
        guard let rows = result["sessions"] as? [[String: Any]] else { throw DriverClientError.badResponse }
        return rows.map(Self.session(from:))
    }

    /// The daemon's version and pid. Cheap: no tool runs.
    public func info() async throws -> DriverInfo {
        let metadata = try await request(["method": "metadata"])
        // Older daemons may not answer this one; the version is enough.
        let authorization = try? await request(["method": "authorization_status"])
        return DriverInfo(
            version: metadata["driver_version"] as? String,
            pid: (metadata["pid"] as? NSNumber)?.intValue,
            permissionMode: (authorization?["permission_mode"] as? String).flatMap(DriverPermissionMode.init(rawValue:))
        )
    }

    /// Accessibility and Screen Recording for the daemon's own identity.
    public func permissions() async throws -> DriverPermissions {
        let result = try await request(["method": "call", "name": "check_permissions", "args": [String: Any]()])
        guard let structured = result["structuredContent"] as? [String: Any] else { throw DriverClientError.badResponse }
        if let refusal = structured["refusal"] as? [String: Any] {
            let code = refusal["code"] as? String ?? ""
            throw code == "authorization_suspended" ? DriverClientError.suspended : DriverClientError.refused(code)
        }
        return DriverPermissions(
            accessibility: structured["accessibility"] as? Bool ?? false,
            screenRecording: structured["screen_recording"] as? Bool ?? false
        )
    }

    /// Stop and revoke one labelled session. Deny-only: it can never grant anything.
    public func revoke(session label: String) async throws {
        _ = try await request(["method": "revoke_authorization", "args": ["session": label]])
    }

    /// Stop and revoke every live session, and refuse every later call until
    /// the daemon restarts: a kill switch, not a one-off. Returns how many
    /// sessions the daemon ended.
    @discardableResult
    public func revokeAll() async throws -> Int {
        let result = try await request(["method": "revoke_authorization", "args": ["all": true]])
        return (result["revoked"] as? NSNumber)?.intValue ?? 0
    }

    // MARK: Parsing

    static func session(from row: [String: Any]) -> AgentSession {
        func int(_ key: String) -> Int? { (row[key] as? NSNumber)?.intValue }
        let label = (row["session"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AgentSession(
            label: label,
            ownerShortID: row["owner_short_id"] as? String ?? "",
            clientKind: row["client_kind"] as? String ?? "unknown",
            transport: row["transport"] as? String ?? "",
            state: row["state"] as? String ?? "active",
            isImplicit: row["implicit"] as? Bool ?? false,
            // A row without an idle time has never been seen acting.
            idleSeconds: int("idle_seconds") ?? .max,
            startedSecondsAgo: int("started_seconds_ago"),
            expiresInSeconds: int("expires_in_seconds"),
            isRecording: row["recording_active"] as? Bool ?? false,
            isCursorVisible: row["cursor_visible"] as? Bool ?? false
        )
    }

    // MARK: Wire

    private func request(_ payload: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: payload) + Data([0x0A])
        let path = socketPath
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let line = try Self.roundTrip(body, path: path, timeout: timeout)
                    guard
                        let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                    else { throw DriverClientError.badResponse }
                    if object["ok"] as? Bool == true {
                        continuation.resume(returning: object["result"] as? [String: Any] ?? [:])
                    } else {
                        throw DriverClientError.daemon(object["error"] as? String ?? "daemon refused the call")
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// One blocking request: connect, write the line, read one line back.
    /// The whole exchange is bounded by `timeout`, not each read.
    private static func roundTrip(_ body: Data, path: String, timeout: TimeInterval) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DriverClientError.io(errno) }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { throw DriverClientError.socketPathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw DriverClientError.notRunning(errno) }

        let deadline = Date().addingTimeInterval(timeout)
        try body.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                if n > 0 {
                    sent += n
                } else if n < 0, errno == EINTR, Date() < deadline {
                    continue
                } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    throw DriverClientError.timedOut
                } else {
                    throw DriverClientError.io(errno)
                }
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let limit = 4 * 1024 * 1024
        while response.count < limit {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 {
                if errno == EINTR, Date() < deadline { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw DriverClientError.timedOut }
                throw DriverClientError.io(errno)
            }
            if n == 0 { break }
            response.append(buffer, count: n)
            if let newline = response.firstIndex(of: 0x0A) {
                return response[..<newline]
            }
            if Date() >= deadline { throw DriverClientError.timedOut }
        }
        guard !response.isEmpty else { throw DriverClientError.badResponse }
        return response
    }
}
