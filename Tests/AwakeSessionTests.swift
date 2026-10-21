// Hardware-free integration: real Unix sockets and child processes, no authorization or pmset.
// swiftc Sources/Dial/AwakeSession.swift Tests/AwakeSessionTests.swift -o /tmp/dial-awake-session-tests
import Foundation
import Darwin

@main
struct AwakeSessionTests {
    static func main() throws {
        let script = """
        import socket,sys,time
        mode,path=sys.argv[1:3]
        s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(path)
        f=s.makefile('rwb',buffering=0)
        def send(v): f.write((v+'\\n').encode())
        if mode=='early': send('active'); sys.exit(0)
        send('ready')
        assert f.readline()==b'start\\n'
        send('active')
        if mode=='eof': sys.exit(0)
        while True:
            line=f.readline()
            if line==b'ping\\n': send('pong')
            elif line==b'stop\\n': send('stopped'); break
            else: break
        """
        for mode in ["normal", "eof", "early", "identity"] {
            let done = DispatchSemaphore(value: 0)
            let mutex = NSLock()
            var events: [String] = []
            let session = AwakeSession(helper: URL(fileURLWithPath: "/unused"),
                helperUID: mode == "identity" ? getuid() + 1 : getuid(),
                launch: { args in
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    p.arguments = ["-c", script, mode, args[2]]
                    return p
                }, report: { event in
                    mutex.lock(); defer { mutex.unlock() }
                    switch event {
                    case .active: events.append("active")
                    case .stopped: events.append("stopped"); done.signal()
                    case .cancelled: events.append("cancelled"); done.signal()
                    case .failed: events.append("failed"); done.signal()
                    }
                })
            session.start()
            if mode == "normal" {
                // Exercise heartbeats beyond one round trip before requesting stop.
                Thread.sleep(forTimeInterval: 2.5)
                session.stop()
            }
            precondition(done.wait(timeout: .now() + 8) == .success, "\(mode) did not finish")
            mutex.lock(); let actual = events; mutex.unlock()
            switch mode {
            case "normal": precondition(actual == ["active", "stopped"], "\(actual)")
            case "eof": precondition(actual == ["active", "failed"], "\(actual)")
            default: precondition(actual == ["failed"], "\(actual)")
            }
            print("PASS \(mode)")
        }
        // Cancel before authorization finishes: a late helper must never receive start.
        let done = DispatchSemaphore(value: 0)
        let cancelled = AwakeSession(helper: URL(fileURLWithPath: "/unused"), launch: { _ in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["5"]; return p
        }, report: { event in
            if case .cancelled = event { done.signal() }
            else { preconditionFailure("unexpected cancellation result") }
        })
        cancelled.start(); cancelled.stop()
        precondition(done.wait(timeout: .now() + 3) == .success)
        print("PASS authorization cancellation")
    }
}
