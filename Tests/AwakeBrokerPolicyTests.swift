// Hardware-free: swiftc -swift-version 5 -warnings-as-errors
// Sources/Dial/AwakeBrokerProtocol.swift Tests/AwakeBrokerPolicyTests.swift -o /tmp/dial-broker-policy-tests
import Foundation

@main
struct AwakeBrokerPolicyTests {
    static func main() throws {
        let snapshot = DialAwakeBrokerInfo.stagingPrefix + "Ab12Cd34/Dial.app"
        let staged = snapshot + "/Contents/Helpers/DialAwakeBroker"
        precondition(AwakeBrokerPolicy.installerPath(staged, resolved: staged, snapshot: snapshot))
        for path in [DialAwakeBrokerInfo.packagedBroker, "/tmp/DialAwakeBroker", staged + "/", staged + "-other"] {
            precondition(!AwakeBrokerPolicy.installerPath(path, resolved: path, snapshot: snapshot))
        }
        for source in ["/tmp/dial-awake.Ab12Cd34/Dial.app", snapshot + "/..", snapshot + "/Other.app",
                       DialAwakeBrokerInfo.stagingPrefix + "../Dial.app",
                       DialAwakeBrokerInfo.stagingPrefix + "Ab12/C34/Dial.app"] {
            let path = source + "/Contents/Helpers/DialAwakeBroker"
            precondition(!AwakeBrokerPolicy.installerPath(path, resolved: path, snapshot: source))
        }
        precondition(!AwakeBrokerPolicy.installerPath(staged, resolved: "/tmp/broker", snapshot: snapshot))
        print("PASS private staged installer path and symlink/traversal refusal")

        let appHash = String(repeating: "a", count: 40)
        let brokerHash = String(repeating: "b", count: 40)
        guard let command = AwakeBrokerPolicy.installationCommand(applicationHash: appHash, brokerHash: brokerHash) else {
            preconditionFailure("Valid code hashes refused")
        }
        precondition(command.hasPrefix("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c '"))
        // Inspect and syntax-check the actual generated inner shell, without executing it.
        let script = String(command[command.range(of: "/bin/sh -c '")!.upperBound...].dropLast())
            .replacingOccurrences(of: "'\"'\"'", with: "'")
        let copy = script.range(of: "/usr/bin/ditto --norsrc --noextattr --noacl")!
        let ownership = script.range(of: "/usr/sbin/chown -R -P 0:0")!
        let permissions = script.range(of: "/bin/chmod -R -P 700")!
        let verifyApp = script.range(of: "/usr/bin/codesign --verify --deep --strict -R '=cdhash H\"\(appHash)\"'")!
        let verifyBroker = script.range(of: "/usr/bin/codesign --verify --strict -R '=cdhash H\"\(brokerHash)\"'")!
        let execute = script.range(of: "\"$snapshot/Contents/Helpers/DialAwakeBroker\" --install \"$snapshot\"")!
        precondition(copy.lowerBound < ownership.lowerBound && ownership.lowerBound < permissions.lowerBound)
        precondition(permissions.lowerBound < verifyApp.lowerBound && verifyApp.lowerBound < verifyBroker.lowerBound
                     && verifyBroker.lowerBound < execute.lowerBound)
        precondition(script.contains("set -eu") && script.contains("-links +1") && script.contains("! -type d ! -type f"))
        precondition(script.contains("test -z \"$invalid\"") && script.contains("trap '/bin/rm -r \"$stage\"' EXIT"))
        let syntax = Process()
        syntax.executableURL = URL(fileURLWithPath: "/bin/sh")
        syntax.arguments = ["-n", "-c", script]
        try syntax.run(); syntax.waitUntilExit()
        precondition(syntax.terminationReason == .exit && syntax.terminationStatus == 0)
        for hash in ["", "a", String(repeating: "z", count: 40), appHash + "'; /tmp/injected"] {
            precondition(AwakeBrokerPolicy.installationCommand(applicationHash: hash, brokerHash: brokerHash) == nil)
            precondition(AwakeBrokerPolicy.installationCommand(applicationHash: appHash, brokerHash: hash) == nil)
        }
        print("PASS pinned verification precedes staged execution; generated shell syntax only")

        precondition(AwakeBrokerPolicy.protectedSnapshot(owner: 0, mode: 0o40700, links: 3, directory: true, hasACL: false))
        precondition(AwakeBrokerPolicy.protectedSnapshot(owner: 0, mode: 0o100700, links: 1, directory: false, hasACL: false))
        for (owner, mode, links, acl) in [(UInt32(501), UInt16(0o100700), UInt16(1), false),
                                        (0, 0o100770, 1, false), (0, 0o120700, 1, false),
                                        (0, 0o100700, 2, false), (0, 0o100700, 1, true)] {
            precondition(!AwakeBrokerPolicy.protectedSnapshot(owner: owner, mode: mode, links: links, directory: false, hasACL: acl))
        }
        precondition(!AwakeBrokerPolicy.protectedSnapshot(owner: 0, mode: 0o40755, links: 3, directory: true, hasACL: false))
        let expected = Data([1, 2, 3])
        precondition(AwakeBrokerPolicy.resumable(existing: nil, expected: expected))
        precondition(AwakeBrokerPolicy.resumable(existing: expected, expected: expected))
        precondition(!AwakeBrokerPolicy.resumable(existing: Data([1, 2]), expected: expected))
        print("PASS private snapshot ownership/type policy and exact-file retry policy")

        precondition(AwakeBrokerPolicy.peer(uid: 501, pid: 42, consoleUID: 501))
        for (uid, pid, console) in [(UInt32(0), Int32(42), UInt32(0)),
                                    (501, 0, 501), (501, -1, 501), (501, 42, 502)] {
            precondition(!AwakeBrokerPolicy.peer(uid: uid, pid: pid, consoleUID: console))
        }
        precondition(!AwakeBrokerPolicy.peer(uid: 501, pid: 42, consoleUID: nil))
        print("PASS authenticated nonroot console identity policy")

        precondition(AwakeBrokerPolicy.socketPath("/tmp/dial-awake-123/s"))
        for path in ["", "relative", "/tmp/../socket", "/tmp/a\0socket", "/" + String(repeating: "a", count: 103)] {
            precondition(!AwakeBrokerPolicy.socketPath(path))
        }
        print("PASS socket argument refusal")

        precondition(AwakeBrokerPolicy.trusted(owner: 0, mode: 0o100644, links: 1, directory: false, hasACL: false))
        precondition(AwakeBrokerPolicy.trusted(owner: 0, mode: 0o40755, links: 3, directory: true, hasACL: false))
        precondition(AwakeBrokerPolicy.trusted(owner: 0, mode: 0o41755, links: 3, directory: true, hasACL: false, parent: true))
        precondition(!AwakeBrokerPolicy.trusted(owner: 0, mode: 0o41755, links: 3, directory: true, hasACL: false))
        for (owner, mode, links, acl) in [(UInt32(501), UInt16(0o100644), UInt16(1), false),
                                        (0, 0o100664, 1, false), (0, 0o100600, 1, false),
                                        (0, 0o120644, 1, false), (0, 0o104644, 1, false),
                                        (0, 0o100644, 2, false), (0, 0o100644, 1, true)] {
            precondition(!AwakeBrokerPolicy.trusted(owner: owner, mode: mode, links: links, directory: false, hasACL: acl))
        }
        precondition(!AwakeBrokerPolicy.trusted(owner: 0, mode: 0o40777, links: 2, directory: true, hasACL: false))
        precondition(!AwakeBrokerPolicy.trusted(owner: 501, mode: 0o40755, links: 2, directory: true, hasACL: false))
        print("PASS root ownership, modes, file types, hardlinks and ACL refusal")

        precondition(AwakeBrokerPolicy.compatible(DialAwakeBrokerInfo.launchConfiguration))
        for (key, value) in [("DialAwakeProtocolVersion", 2 as Any),
                             ("ProgramArguments", ["/tmp/worker", "--daemon"] as Any),
                             ("KeepAlive", true as Any)] {
            var changed = DialAwakeBrokerInfo.launchConfiguration
            changed[key] = value
            precondition(!AwakeBrokerPolicy.compatible(changed))
        }
        let root = ProcessInfo.processInfo.environment["DIAL_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath
        let data = try Data(contentsOf: URL(fileURLWithPath: root)
            .appendingPathComponent("Resources/io.github.eroyun.dial.awake.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = plist as? [String: Any] else { preconditionFailure("Invalid launch plist") }
        precondition(NSDictionary(dictionary: dictionary).isEqual(to: DialAwakeBrokerInfo.launchConfiguration))
        precondition(dictionary["RunAtLoad"] == nil && dictionary["KeepAlive"] == nil)
        print("PASS protocol compatibility and exact on-demand launch configuration")
    }
}
