import Foundation
import Darwin

/// One authorized helper invocation. The socket carries only start, heartbeat and stop;
/// it never accepts a command or a filesystem destination from the privileged process.
final class AwakeSession {
    enum Event { case active, stopped, cancelled, failed(String) }
    private let lock = NSLock()
    private var stopping = false
    private let helper: URL
    private let report: (Event) -> Void
    private let helperUID: uid_t
    private let launch: ([String]) -> Process

    init(helper: URL, helperUID: uid_t = 0,
         launch: @escaping ([String]) -> Process = AwakeSession.brokerProcess,
         report: @escaping (Event) -> Void) {
        self.helper = helper
        self.helperUID = helperUID
        self.launch = launch
        self.report = report
    }

    func start() { DispatchQueue.global(qos: .utility).async { self.run() } }
    func stop() { lock.lock(); stopping = true; lock.unlock() }
    private var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopping }

    private func run() {
        var template = Array("/tmp/dial-awake-XXXXXXXX".utf8CString)
        guard let path = mkdtemp(&template) else { report(.failed("Could not prepare keep-awake session.")); return }
        let directory = String(cString: path)
        let socketPath = directory + "/s"
        defer { unlink(socketPath); rmdir(directory) }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { report(.failed("Could not open keep-awake session.")); return }
        defer { close(listener) }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: socketPath.utf8CString.map { UInt8(bitPattern: $0) })
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            report(.failed("Could not prepare keep-awake connection.")); return
        }

        let process = launch([helper.path, "--session", socketPath, String(getpid()), String(getuid())])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { report(.failed("Could not request administrator authorization.")); return }

        // Closing the listener prevents a queued helper from starting after the
        // user has cancelled or quit. Ordinary sessions require no authorization.
        while process.isRunning && !shouldStop {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            if poll(&poller, 1, 200) > 0 && poller.revents & Int16(POLLIN) != 0 { break }
        }
        guard process.isRunning, !shouldStop else {
            if process.isRunning { process.terminate() }
            report(shouldStop ? .cancelled : .failed("Keep-awake helper is unavailable.")); return
        }
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { report(.failed("Helper connection failed.")); return }
        defer { close(connection) }
        _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
        var noSignal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(connection, &peerUID, &peerGID) == 0, peerUID == helperUID else {
            report(.failed("Keep-awake helper identity could not be verified.")); return
        }

        var buffer = Data()
        var started = false
        var active = false
        var stopSent = false
        var lastPing = Date.distantPast
        var lastReply = Date()
        while true {
            if shouldStop && !stopSent {
                guard sendLine("stop", to: connection) else { break }
                stopSent = true
            }
            if started && !stopSent && Date().timeIntervalSince(lastPing) >= 2 {
                guard sendLine("ping", to: connection) else { break }
                lastPing = Date()
            }
            // A stalled/lost helper must never leave the UI claiming protection.
            if Date().timeIntervalSince(lastReply) > 15 { break }
            var poller = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
            let result = poll(&poller, 1, 200)
            if result < 0 && errno == EINTR { continue }
            if result < 0 { break }
            if result == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 256)
            let count = read(connection, &bytes, bytes.count)
            if count <= 0 { break }
            buffer.append(contentsOf: bytes.prefix(count))
            if buffer.count > 4096 { break }
            while let end = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<end], as: UTF8.self)
                buffer.removeSubrange(...end)
                lastReply = Date()
                switch line {
                case "ready" where !started && !stopSent:
                    guard sendLine("start", to: connection) else { report(.failed("Helper handshake failed.")); return }
                    started = true
                case "active" where started && !stopSent:
                    if !active { active = true; report(.active) }
                case "ready" where stopSent: break
                case "active" where stopSent: break
                case "pong": break
                case "stopped": report(.stopped); return
                default:
                    // Only fixed protocol messages are shown; root stderr and paths
                    // are deliberately excluded from the user-facing surface.
                    if line.hasPrefix("error") {
                        report(.failed("Keep-awake failed. Normal sleep restoration is unverified; run sudo pmset -a disablesleep 0 if needed.")); return
                    }
                    report(.failed("Unexpected helper response. Sleep state is unverified.")); return
                }
            }
        }
        report(.failed("Helper disconnected. Sleep restoration is unverified; run sudo pmset -a disablesleep 0 if needed."))
    }

    private func sendLine(_ text: String, to fd: Int32) -> Bool {
        let bytes = Array((text + "\n").utf8)
        return bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count }
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func brokerProcess(_ arguments: [String]) -> Process {
        let process = Process()
        let contents = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = contents.appendingPathComponent("MacOS/Dial")
        process.arguments = ["--awake-connect", arguments[2]]
        return process
    }
    static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
