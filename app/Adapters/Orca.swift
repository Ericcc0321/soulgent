import AppKit
import Combine
import ImageIO
import SQLite3
import SwiftUI

// ───────── Orca: its local socket and its terminals ─────────

/// One request to the running Orca app over the local socket its own command line uses.
/// ~/Library/Application Support/orca/orca-runtime.json names the socket and holds the token
/// Orca issues to local clients; the token is used for the request and nothing else.
/// Asking Orca this way takes a few milliseconds, where starting its command line for every click
/// takes far longer, and longer still when memory is tight.
func orcaCall(_ method: String, _ params: [String: Any]) -> [String: Any]? {
    guard let (token, endpoint) = orcaRuntime(FileManager.default.contents(atPath: home + "/Library/Application Support/orca/orca-runtime.json"))
    else { return nil }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var limit = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(endpoint.utf8)
    guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return nil }

    let request: [String: Any] = ["id": UUID().uuidString.lowercased(), "authToken": token, "method": method, "params": params]
    guard var body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
    body.append(0x0A)
    guard body.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == body.count else { return nil }

    // The answer is one line of JSON; keep-alive lines may come before it.
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        received.append(buffer, count: count)
        while let newline = received.firstIndex(of: 0x0A) {
            let frame = Data(received[received.startIndex..<newline])
            received = Data(received[(newline + 1)...])
            guard let reply = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else { continue }
            if reply["_keepalive"] == nil { return reply }
        }
    }
}

/// The token and the socket orca-runtime.json gives, and whether it is of the shape read (`OrcaFormat`): a file that reads as
/// JSON without them is Orca's format changed; no file (Orca not installed or not running) or one that does not read (being
/// written) says nothing.
func orcaRuntime(_ data: Data?) -> (token: String, endpoint: String)? {
    guard let data else {
        OrcaFormat.shared.set(.orcaRuntime, false)
        return nil
    }
    guard let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    let token = meta["authToken"] as? String
    let endpoint = (meta["transports"] as? [[String: Any]])?.first(where: { ($0["kind"] as? String) == "unix" })?["endpoint"] as? String
    OrcaFormat.shared.set(.orcaRuntime, token == nil || endpoint == nil)
    guard let token, let endpoint else { return nil }
    return (token, endpoint)
}

/// Whether Orca's answer to `terminal.list` is of a shape read: its result a list of terminals, or an object with one
/// (`terminals`) or with the layouts (`visualLayouts`), the terminals objects and some with a `handle`. Nil for no answer or
/// one with no result (an error, Orca busy), which says nothing of the format.
func orcaTerminalsUnderstood(_ reply: [String: Any]?) -> Bool? {
    guard let reply, let result = reply["result"] else { return nil }
    let terminals: [Any]
    if let list = result as? [Any] {
        terminals = list
    } else if let object = result as? [String: Any] {
        if let list = object["terminals"] as? [Any] {
            terminals = list
        } else {
            return object["visualLayouts"] is [Any]
        }
    } else {
        return false
    }
    let entries = terminals.compactMap { $0 as? [String: Any] }
    return entries.count == terminals.count && (entries.isEmpty || entries.contains { $0["handle"] is String })
}

/// Orca's answer to `terminal.list`, as it is, its shape noted (`OrcaFormat`).
func orcaTerminalList(_ reply: [String: Any]?) -> [String: Any]? {
    if let understood = orcaTerminalsUnderstood(reply) { OrcaFormat.shared.set(.orcaTerminals, !understood) }
    return reply
}

/// Where a session lives in Orca. Orca puts the tab's handle and pane ids in the environment
/// of every process it starts; they are read once per process and remembered.
final class OrcaTabs {
    static let shared = OrcaTabs()
    private var known: [Int32: (terminal: String, pane: String)] = [:]
    private var looked = Set<Int32>()  // processes whose environment has been read at least once, Orca's or not
    private let lock = NSLock()

    func tab(of pid: Int32) -> (terminal: String, pane: String)? {
        lock.lock()
        let cached = known[pid]
        lock.unlock()
        if let cached { return cached }
        let env = run("/bin/ps", ["eww", "-o", "command=", "-p", String(pid)])
        func value(_ key: String) -> String {
            guard let range = env.range(of: key + #"=\S+"#, options: .regularExpression) else { return "" }
            return String(env[range].dropFirst(key.count + 1))
        }
        let terminal = value("ORCA_TERMINAL_HANDLE")
        let found = terminal.isEmpty ? nil : (terminal: terminal, pane: value("ORCA_PANE_KEY"))
        // Both at once: looked at but not yet known would be "not from Orca" to `pane(of:)` for a moment.
        lock.lock()
        looked.insert(pid)
        if let found { known[pid] = found }
        lock.unlock()
        return found
    }

    /// The pane a process was started in, from what has been read so far, never waiting for `ps`: "" when it has none (not
    /// started from Orca), nil while its environment has not been read yet.
    func pane(of pid: Int32) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let tab = known[pid] { return tab.pane }
        return looked.contains(pid) ? "" : nil
    }

    /// For a process whose environment has been read already (a Codex session's, from the kernel).
    func learn(_ pid: Int32, terminal: String, pane: String) {
        lock.lock()
        known[pid] = (terminal, pane)
        lock.unlock()
    }

    /// Look the tabs up ahead of time, so even the first click on a card has nothing to wait for.
    func prepare(_ pids: [Int32]) {
        lock.lock()
        // Once looked at is enough: a process's environment does not change (not from Orca, `ps` is not asked every tick).
        let missing = pids.filter { known[$0] == nil && !looked.contains($0) }
        lock.unlock()
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { for pid in missing { _ = self.tab(of: pid) } }
    }
}

func orcaCommand() -> String? {
    ["/usr/local/bin/orca", "/Applications/Orca.app/Contents/Resources/bin/orca"]
        .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
}
