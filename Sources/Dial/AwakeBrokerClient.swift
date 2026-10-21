import Foundation
import Security

enum AwakeBrokerClient {
    private static func connection() -> NSXPCConnection? {
        let broker = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DialAwakeBroker")
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(broker as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        let connection = NSXPCConnection(machServiceName: DialAwakeBrokerInfo.serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: DialAwakeBrokerProtocol.self)
        connection.setCodeSigningRequirement(text as String)
        return connection
    }

    /// A bounded, read-only handshake. It does not install or authorize anything.
    static func isInstalled(_ completion: @escaping (Bool) -> Void) {
        guard let connection = connection() else { completion(false); return }
        let once = NSLock()
        var completed = false
        func finish(_ available: Bool) {
            once.lock()
            guard !completed else { once.unlock(); return }
            completed = true
            once.unlock()
            connection.invalidationHandler = nil
            connection.interruptionHandler = nil
            connection.invalidate()
            completion(available)
        }
        connection.invalidationHandler = { finish(false) }
        connection.interruptionHandler = { finish(false) }
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(false) }) as? DialAwakeBrokerProtocol else {
            finish(false); return
        }
        proxy.version { finish($0 == DialAwakeBrokerInfo.protocolVersion) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(false) }
    }

    /// The short-lived signed client is authenticated by launchd's XPC audit
    /// identity. The broker chooses its PID/UID; no owner is trusted from argv.
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        if arguments == ["--awake-helper-status"] {
            let done = DispatchSemaphore(value: 0)
            var available = false
            isInstalled { available = $0; done.signal() }
            _ = done.wait(timeout: .now() + 4)
            print(available ? "installed" : "unavailable")
            return available ? 0 : 1
        }
        guard arguments.first == "--awake-connect" else { return nil }
        guard arguments.count == 2, AwakeBrokerPolicy.socketPath(arguments[1]),
              let connection = connection() else { return 1 }
        let done = DispatchSemaphore(value: 0)
        let once = NSLock()
        var completed = false
        var status: Int32 = 1
        func finish(_ result: Int32) {
            once.lock(); defer { once.unlock() }
            guard !completed else { return }
            completed = true; status = result; done.signal()
        }
        connection.invalidationHandler = { finish(1) }
        connection.interruptionHandler = { finish(1) }
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(1) }) as? DialAwakeBrokerProtocol else {
            connection.invalidate(); return 1
        }
        proxy.beginSession(socketPath: arguments[1]) { finish($0) }
        done.wait()
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        return status
    }
}
