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

import Darwin
import Foundation

/// One agent session the daemon is running, without any content.
public struct AgentSession: Identifiable, Equatable, Sendable {
    /// Public session label, or nil for an implicit session.
    public let label: String?
    public let ownerShortID: String
    /// `mcp`, `direct`, `cli`, `python_sdk`, ...
    public let clientKind: String
    /// `mcp_stdio`, `daemon`, ...
    public let transport: String
    public let state: String
    public let isImplicit: Bool
    public let idleSeconds: Int
    public let startedSecondsAgo: Int?
    public let isRecording: Bool

    public var id: String { "\(ownerShortID)/\(label ?? "implicit")/\(clientKind)" }

    /// The session made a call recently enough to count as driving right now.
    public var isDriving: Bool { idleSeconds <= AgentSession.drivingWindow }

    /// Seconds since the last call that still read as "driving".
    public static let drivingWindow = 15

    /// What to call the session in a row: its label, or what kind of client it is.
    public var displayName: String {
        if let label, !label.isEmpty { return label }
        switch clientKind {
        case "mcp": return "MCP agent"
        case "cli": return "CLI"
        case "python_sdk": return "Python SDK"
        case "typescript_sdk": return "TypeScript SDK"
        default: return clientKind.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// Accessibility and Screen Recording, as the daemon's own identity sees them.
public struct DriverPermissions: Equatable, Sendable {
    public let accessibility: Bool
    public let screenRecording: Bool
}

public enum DriverClientError: Error, CustomStringConvertible {
    case socketPathTooLong
    case notRunning(Int32)
    case io(Int32)
    case badResponse
    case daemon(String)

    public var description: String {
        switch self {
        case .socketPathTooLong: "socket path too long"
        case .notRunning(let code): "daemon not reachable (errno \(code))"
        case .io(let code): "socket I/O failed (errno \(code))"
        case .badResponse: "unreadable daemon response"
        case .daemon(let message): message
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

    /// `~/Library/Caches/cua-driver/cua-driver.sock` of the real user, even if
    /// the host process has a container home.
    public static var defaultSocketPath: String {
        var home = NSHomeDirectory()
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            home = String(cString: dir)
        }
        return home + "/Library/Caches/cua-driver/cua-driver.sock"
    }

    // MARK: Calls

    /// Every session the daemon owns, from every client.
    public func sessions() async throws -> [AgentSession] {
        let result = try await request(["method": "sessions_list"])
        guard let rows = result["sessions"] as? [[String: Any]] else { throw DriverClientError.badResponse }
        return rows.map { row in
            AgentSession(
                label: row["session"] as? String,
                ownerShortID: row["owner_short_id"] as? String ?? "",
                clientKind: row["client_kind"] as? String ?? "unknown",
                transport: row["transport"] as? String ?? "",
                state: row["state"] as? String ?? "",
                isImplicit: row["implicit"] as? Bool ?? false,
                idleSeconds: (row["idle_seconds"] as? NSNumber)?.intValue ?? .max,
                startedSecondsAgo: (row["started_seconds_ago"] as? NSNumber)?.intValue,
                isRecording: row["recording_active"] as? Bool ?? false
            )
        }
    }

    public func permissions() async throws -> DriverPermissions {
        let result = try await request(["method": "call", "name": "check_permissions", "args": [String: Any]()])
        guard let structured = result["structuredContent"] as? [String: Any] else { throw DriverClientError.badResponse }
        return DriverPermissions(
            accessibility: structured["accessibility"] as? Bool ?? false,
            screenRecording: structured["screen_recording"] as? Bool ?? false
        )
    }

    /// Stop and revoke one labelled session. Deny-only: it can never grant anything.
    public func revoke(session label: String) async throws {
        _ = try await request(["method": "revoke_authorization", "args": ["session": label]])
    }

    /// Stop and revoke every live session.
    public func revokeAll() async throws {
        _ = try await request(["method": "revoke_authorization", "args": ["all": true]])
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

        try body.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                guard n > 0 else { throw DriverClientError.io(errno) }
                sent += n
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let limit = 4 * 1024 * 1024
        while response.count < limit {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 { throw DriverClientError.io(errno) }
            if n == 0 { break }
            response.append(buffer, count: n)
            if let newline = response.firstIndex(of: 0x0A) {
                return response[..<newline]
            }
        }
        guard !response.isEmpty else { throw DriverClientError.badResponse }
        return response
    }
}
