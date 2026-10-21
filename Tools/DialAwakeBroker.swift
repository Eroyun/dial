import Foundation
import Security
import SystemConfiguration
import Darwin
import MachO

private typealias Info = DialAwakeBrokerInfo
private enum Refusal: Error { case unsafe, incompatible, unavailable }
private let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)

private func require(_ condition: @autoclosure () throws -> Bool) throws {
    if try !condition() { throw Refusal.unsafe }
}

private func executablePath() throws -> String {
    var count: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &count)
    var bytes = [CChar](repeating: 0, count: Int(count))
    try require(_NSGetExecutablePath(&bytes, &count) == 0)
    return String(cString: bytes)
}

private func record(_ path: String) throws -> stat {
    var value = stat()
    try require(lstat(path, &value) == 0)
    return value
}

private func absent(_ path: String) throws -> Bool {
    var value = stat()
    if lstat(path, &value) == 0 { return false }
    try require(errno == ENOENT)
    return true
}

private func trusted(_ path: String, directory: Bool = false, executable: Bool = false,
                     parent: Bool = false, snapshot: Bool = false) throws {
    let value = try record(path)
    guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { throw Refusal.unsafe }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    let entries = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
    if snapshot {
        try require(AwakeBrokerPolicy.protectedSnapshot(owner: value.st_uid, mode: value.st_mode,
            links: value.st_nlink, directory: directory, hasACL: entries != 0))
        return
    }
    // Executables have the same policy as data except for their three execute bits.
    let mode = executable ? value.st_mode & ~mode_t(0o111) : value.st_mode
    try require(!executable || value.st_mode == 0o100755)
    try require(AwakeBrokerPolicy.trusted(owner: value.st_uid, mode: mode,
        links: value.st_nlink, directory: directory, hasACL: entries != 0, parent: parent))
}

private func trustedParents() throws {
    for path in ["/Library", "/Library/PrivilegedHelperTools", "/Library/LaunchDaemons"] {
        try trusted(path, directory: true, parent: true)
    }
}

private func staticCode(_ path: String, requirement: SecRequirement? = nil) throws -> SecStaticCode {
    var code: SecStaticCode?
    try require(SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess)
    guard let code else { throw Refusal.unsafe }
    try require(SecStaticCodeCheckValidity(code, strict, requirement) == errSecSuccess)
    return code
}

private func designated(_ code: SecStaticCode) throws -> Data {
    var requirement: SecRequirement?
    var data: CFData?
    try require(SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess)
    guard let requirement else { throw Refusal.unsafe }
    try require(SecRequirementCopyData(requirement, [], &data) == errSecSuccess)
    guard let data else { throw Refusal.unsafe }
    return data as Data
}

private func requirement(_ data: Data) throws -> SecRequirement {
    var result: SecRequirement?
    try require(!data.isEmpty && data.count <= 65536)
    try require(SecRequirementCreateWithData(data as CFData, [], &result) == errSecSuccess)
    guard let result else { throw Refusal.unsafe }
    return result
}

private func signingHash(_ code: SecStaticCode) throws -> Data {
    var information: CFDictionary?
    try require(SecCodeCopySigningInformation(code, [], &information) == errSecSuccess)
    guard let values = information as? [String: Any],
          let hash = values[kSecCodeInfoUnique as String] as? Data else { throw Refusal.unsafe }
    return hash
}

private func readFile(_ path: String, maximum: Int) throws -> Data {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    try require(fd >= 0)
    defer { close(fd) }
    var value = stat()
    try require(fstat(fd, &value) == 0 && value.st_mode & S_IFMT == S_IFREG
        && value.st_size > 0 && value.st_size <= maximum && value.st_nlink == 1)
    var result = Data(count: Int(value.st_size))
    let expected = result.count
    let count = result.withUnsafeMutableBytes { pread(fd, $0.baseAddress, expected, 0) }
    try require(count == expected)
    return result
}

/// Never replaces an existing inode. Temporary files are created in the trusted root directory.
private func publish(_ data: Data, to path: String, mode: mode_t) throws {
    let temporary = URL(fileURLWithPath: path).deletingLastPathComponent().path + "/.install-" + UUID().uuidString
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    try require(fd >= 0)
    defer { close(fd); unlink(temporary) }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            try require(count > 0)
            offset += count
        }
    }
    try require(fchown(fd, 0, 0) == 0 && fchmod(fd, mode) == 0 && fsync(fd) == 0)
    try require(renamex_np(temporary, path, UInt32(RENAME_EXCL)) == 0)
}

private func launchctl(_ arguments: [String]) throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationReason == .exit && process.terminationStatus == 0
}

private func installedPayloadRequirement() throws -> Data {
    try trustedParents()
    try trusted(Info.helperDirectory, directory: true)
    try trusted(Info.broker, executable: true)
    try trusted(Info.worker, executable: true)
    try trusted(Info.requirement)
    let approved = try readFile(Info.requirement, maximum: 65536)
    _ = try requirement(approved)
    return approved
}

private func validatePlist() throws {
    try trusted(Info.plist)
    let data = try readFile(Info.plist, maximum: 65536)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    guard let dictionary = plist as? [String: Any],
          dictionary["DialAwakeProtocolVersion"] as? Int == Info.protocolVersion else { throw Refusal.incompatible }
    try require(AwakeBrokerPolicy.compatible(dictionary))
}

private func installedRequirement() throws -> Data {
    let approved = try installedPayloadRequirement()
    try validatePlist()
    return approved
}

private func install(snapshot: String) throws {
    try require(geteuid() == 0)
    let executable = try executablePath()
    try require(AwakeBrokerPolicy.installerPath(executable,
        resolved: URL(fileURLWithPath: executable).resolvingSymlinksInPath().path, snapshot: snapshot))
    // The system-tool bootstrap has already pinned both signatures before executing
    // this broker. Consume that private snapshot only; never reopen /Applications.
    for path in ["/private", "/private/var", "/private/var/root"] {
        let value = try record(path)
        try require(value.st_uid == 0 && value.st_mode & S_IFMT == S_IFDIR && value.st_mode & 0o022 == 0)
    }
    try trusted(URL(fileURLWithPath: snapshot).deletingLastPathComponent().path, directory: true, snapshot: true)
    try trusted(snapshot, directory: true, snapshot: true)
    let contents = try FileManager.default.subpathsOfDirectory(atPath: snapshot)
    for relative in contents {
        let path = snapshot + "/" + relative
        try trusted(path, directory: record(path).st_mode & S_IFMT == S_IFDIR, snapshot: true)
    }
    try trustedParents()
    let application = try staticCode(snapshot)
    var information: CFDictionary?
    try require(SecCodeCopySigningInformation(application, [], &information) == errSecSuccess)
    try require((information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String == "io.github.eroyun.dial")
    guard let flags = (information as? [String: Any])?[kSecCodeInfoFlags as String] as? NSNumber else { throw Refusal.unsafe }
    try require(flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue == 0)
    let approved = try designated(application)
    let helpers = snapshot + "/Contents/Helpers/"
    let brokerHash = try signingHash(staticCode(helpers + "DialAwakeBroker"))
    let workerHash = try signingHash(staticCode(helpers + "DialAwakeHelper"))
    let payload: [(name: String, data: Data, mode: mode_t)] = [
        ("DialAwakeBroker", try readFile(helpers + "DialAwakeBroker", maximum: 32 * 1024 * 1024), 0o755),
        ("DialAwakeHelper", try readFile(helpers + "DialAwakeHelper", maximum: 32 * 1024 * 1024), 0o755),
        ("app.requirement", approved, 0o644)
    ]
    let plistMissing = try absent(Info.plist)
    if !plistMissing { try validatePlist() }

    if try absent(Info.helperDirectory) {
        // Publish the entire payload in one exclusive rename. A crash before that
        // cannot leave a partly installed live directory.
        let staging = "/Library/PrivilegedHelperTools/.dial-awake-" + UUID().uuidString
        try require(mkdir(staging, 0o700) == 0)
        defer { try? FileManager.default.removeItem(atPath: staging) }
        try require(chown(staging, 0, 0) == 0 && chmod(staging, 0o700) == 0)
        for item in payload { try publish(item.data, to: staging + "/" + item.name, mode: item.mode) }
        try require(signingHash(staticCode(staging + "/DialAwakeBroker")) == brokerHash)
        try require(signingHash(staticCode(staging + "/DialAwakeHelper")) == workerHash)
        try require(chmod(staging, 0o755) == 0)
        if renamex_np(staging, Info.helperDirectory, UInt32(RENAME_EXCL)) != 0 {
            // Another installer may have won. Validate it below; never replace it.
            try require(errno == EEXIST || errno == ENOTEMPTY)
        }
    }
    try trusted(Info.helperDirectory, directory: true)
    let missing = try payload.filter { try absent(Info.helperDirectory + "/" + $0.name) }
    if !missing.isEmpty {
        // Recover legacy partial installations only when every existing member is
        // exactly the approved payload. No differing or unexpected file is touched.
        let names = try FileManager.default.contentsOfDirectory(atPath: Info.helperDirectory)
        try require(Set(names).isSubset(of: Set(payload.map(\.name))))
        for item in payload {
            let path = Info.helperDirectory + "/" + item.name
            if try !absent(path) {
                try trusted(path, executable: item.mode == 0o755)
                try require(AwakeBrokerPolicy.resumable(existing: readFile(path, maximum: 32 * 1024 * 1024),
                                                        expected: item.data))
            }
        }
        for item in missing {
            let path = Info.helperDirectory + "/" + item.name
            do { try publish(item.data, to: path, mode: item.mode) }
            catch {
                // Revalidate an exclusive-publication winner before accepting it.
                try trusted(path, executable: item.mode == 0o755)
                try require(readFile(path, maximum: 32 * 1024 * 1024) == item.data)
            }
        }
        try require(signingHash(staticCode(Info.broker)) == brokerHash)
        try require(signingHash(staticCode(Info.worker)) == workerHash)
    }
    let old = try installedPayloadRequirement()
    _ = try staticCode(snapshot, requirement: requirement(old))
    // A complete compatible installation, including active code, is reused.
    if plistMissing {
        let plist = try PropertyListSerialization.data(fromPropertyList: Info.launchConfiguration, format: .xml, options: 0)
        do { try publish(plist, to: Info.plist, mode: 0o644) }
        catch { try validatePlist() }
    }
    _ = try installedRequirement()
    if try !launchctl(["print", "system/" + Info.serviceName]) {
        _ = try launchctl(["bootstrap", "system", Info.plist])
    }
    try require(launchctl(["print", "system/" + Info.serviceName]))
}

private func consoleUID() -> uid_t? {
    var uid: uid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
          name != "loginwindow", uid != 0 else { return nil }
    return uid
}

@available(macOS 13.0, *)
private final class Broker: NSObject, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: "io.github.eroyun.dial.awake.state")
    let signingRequirement: String
    var active: Session?
    var pending: (session: Session, socket: String, reply: (Int32) -> Void)?
    init(approved: Data) throws {
        var text: CFString?
        try require(SecRequirementCopyString(requirement(approved), [], &text) == errSecSuccess)
        guard let text else { throw Refusal.unsafe }
        signingRequirement = text as String
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard AwakeBrokerPolicy.peer(uid: connection.effectiveUserIdentifier,
            pid: connection.processIdentifier, consoleUID: consoleUID()) else { return false }
        // Foundation checks the peer's actual audit identity, including on every new message.
        // No private auditToken accessor or PID-only SecCode guest lookup is used.
        connection.setCodeSigningRequirement(signingRequirement)
        let session = Session(connection: connection, broker: self)
        connection.exportedInterface = NSXPCInterface(with: DialAwakeBrokerProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { session.cancel() }
        connection.interruptionHandler = { session.cancel() }
        connection.resume()
        return true
    }
}

@available(macOS 13.0, *)
private final class Session: NSObject, DialAwakeBrokerProtocol {
    var connection: NSXPCConnection?
    unowned let broker: Broker
    var process: Process?
    var cancelled = false
    init(connection: NSXPCConnection, broker: Broker) { self.connection = connection; self.broker = broker }
    func version(withReply reply: @escaping (Int) -> Void) { reply(Info.protocolVersion) }
    func beginSession(socketPath: String, withReply reply: @escaping (Int32) -> Void) {
        broker.queue.async {
            guard self.valid, AwakeBrokerPolicy.socketPath(socketPath) else { reply(1); return }
            if self.broker.active != nil {
                guard self.broker.active !== self, self.broker.pending == nil else { reply(2); return }
                self.broker.pending = (self, socketPath, reply)
                return
            }
            self.start(socketPath, reply: reply)
        }
    }
    private var valid: Bool {
        guard !cancelled, let connection else { return false }
        return AwakeBrokerPolicy.peer(uid: connection.effectiveUserIdentifier,
            pid: connection.processIdentifier, consoleUID: consoleUID())
    }
    private func start(_ socketPath: String, reply: @escaping (Int32) -> Void) {
        guard valid, let connection else { reply(1); return }
        do {
            try trusted(Info.worker, executable: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Info.worker)
            process.arguments = ["--session", socketPath, String(connection.processIdentifier),
                                 String(connection.effectiveUserIdentifier)]
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { child in
                self.broker.queue.async {
                    self.process = nil
                    self.broker.active = nil
                    reply(child.terminationReason == .exit ? child.terminationStatus : 1)
                    if let pending = self.broker.pending {
                        self.broker.pending = nil
                        pending.session.start(pending.socket, reply: pending.reply)
                    }
                }
            }
            self.process = process
            self.broker.active = self
            do { try process.run() }
            catch { self.process = nil; self.broker.active = nil; reply(1) }
        } catch { reply(1) }
    }
    func cancel() {
        broker.queue.async {
            self.cancelled = true
            self.connection = nil
            if let pending = self.broker.pending, pending.session === self {
                self.broker.pending = nil
                pending.reply(1)
            }
            if let process = self.process, process.isRunning { process.terminate() }
        }
    }
}

@main
private struct DialAwakeBroker {
    static func main() {
        do {
            try require(CommandLine.arguments.count >= 2 && geteuid() == 0)
            switch CommandLine.arguments[1] {
            case "--install":
                try require(CommandLine.arguments.count == 3)
                try install(snapshot: CommandLine.arguments[2])
            case "--daemon":
                try require(CommandLine.arguments.count == 2)
                guard #available(macOS 13.0, *) else { throw Refusal.unavailable }
                let path = try executablePath()
                try require(path == Info.broker && URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path)
                let broker = try Broker(approved: installedRequirement())
                let listener = NSXPCListener(machServiceName: Info.serviceName)
                listener.setConnectionCodeSigningRequirement(broker.signingRequirement)
                listener.delegate = broker
                listener.resume()
                withExtendedLifetime((listener, broker)) { RunLoop.current.run() }
            default: throw Refusal.unsafe
            }
        } catch Refusal.incompatible { exit(78) }
        catch { exit(1) }
    }
}
