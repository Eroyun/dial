import Foundation

@objc(DialAwakeBrokerProtocol) protocol DialAwakeBrokerProtocol {
    func version(withReply reply: @escaping (Int) -> Void)
    func beginSession(socketPath: String, withReply reply: @escaping (Int32) -> Void)
}

enum DialAwakeBrokerInfo {
    static let serviceName = "io.github.eroyun.dial.awake"
    static let protocolVersion = 1
    static let application = "/Applications/Dial.app"
    static let helperDirectory = "/Library/PrivilegedHelperTools/" + serviceName
    static let broker = helperDirectory + "/DialAwakeBroker"
    static let worker = helperDirectory + "/DialAwakeHelper"
    static let requirement = helperDirectory + "/app.requirement"
    static let plist = "/Library/LaunchDaemons/" + serviceName + ".plist"
    static let packagedBroker = application + "/Contents/Helpers/DialAwakeBroker"
    static let packagedWorker = application + "/Contents/Helpers/DialAwakeHelper"
    static let stagingPrefix = "/private/var/root/dial-awake."
    static let launchConfiguration: [String: Any] = [
        "Label": serviceName, "ProgramArguments": [broker, "--daemon"],
        "MachServices": [serviceName: true], "DialAwakeProtocolVersion": protocolVersion,
        "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"
    ]
}

/// Pure refusal policy; neither the tests nor these decisions register a daemon.
enum AwakeBrokerPolicy {
    static func installerPath(_ executable: String, resolved: String, snapshot: String) -> Bool {
        let prefix = DialAwakeBrokerInfo.stagingPrefix
        guard snapshot.hasPrefix(prefix), snapshot.hasSuffix("/Dial.app") else { return false }
        let suffix = snapshot.dropFirst(prefix.count).dropLast("/Dial.app".count)
        return suffix.utf8.count == 8 && suffix.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        } && executable == snapshot + "/Contents/Helpers/DialAwakeBroker" && resolved == executable
    }
    /// Only trusted system code runs as root until both pinned signatures pass.
    static func installationCommand(applicationHash: String, brokerHash: String) -> String? {
        guard [applicationHash, brokerHash].allSatisfy({ hash in
            hash.utf8.count == 40 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }) else { return nil }
        let script = """
        set -eu
        umask 077
        stage=$(/usr/bin/mktemp -d \(DialAwakeBrokerInfo.stagingPrefix)XXXXXXXX)
        trap '/bin/rm -r "$stage"' EXIT
        /bin/chmod -N "$stage"
        snapshot="$stage/Dial.app"
        /usr/bin/ditto --norsrc --noextattr --noacl \(DialAwakeBrokerInfo.application) "$snapshot"
        invalid=$(/usr/bin/find -P "$snapshot" \\( ! -type d ! -type f \\) -o \\( -type f -links +1 \\))
        test -z "$invalid"
        /usr/sbin/chown -R -P 0:0 "$snapshot"
        /bin/chmod -R -P -N "$snapshot"
        /bin/chmod -R -P 700 "$snapshot"
        /usr/bin/codesign --verify --deep --strict -R '=cdhash H"\(applicationHash)"' "$snapshot"
        /usr/bin/codesign --verify --strict -R '=cdhash H"\(brokerHash)"' "$snapshot/Contents/Helpers/DialAwakeBroker"
        "$snapshot/Contents/Helpers/DialAwakeBroker" --install "$snapshot"
        """
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c " + quoted
    }
    static func protectedSnapshot(owner: UInt32, mode: UInt16, links: UInt16,
                                  directory: Bool, hasACL: Bool) -> Bool {
        owner == 0 && !hasACL && (directory || links == 1)
            && mode == (directory ? 0o40700 : 0o100700)
    }
    static func resumable(existing: Data?, expected: Data) -> Bool {
        existing == nil || existing == expected
    }
    static func peer(uid: UInt32, pid: Int32, consoleUID: UInt32?) -> Bool {
        uid != 0 && pid > 0 && consoleUID == uid
    }
    static func socketPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count < 104 && !path.utf8.contains(0)
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
    static func trusted(owner: UInt32, mode: UInt16, links: UInt16,
                        directory: Bool, hasACL: Bool, parent: Bool = false) -> Bool {
        let permissions = directory && parent ? mode & ~UInt16(0o1000) : mode
        return owner == 0 && !hasACL && (directory || links == 1)
            && permissions == (directory ? 0o40755 : 0o100644)
    }
    static func compatible(_ configuration: [String: Any]) -> Bool {
        NSDictionary(dictionary: configuration).isEqual(to: DialAwakeBrokerInfo.launchConfiguration)
    }
}
