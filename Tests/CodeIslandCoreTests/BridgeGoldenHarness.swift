import Foundation
import XCTest

/// One hook invocation codeisland-bridge serves: what its agent hands it and
/// the process tree it runs in. See ``BridgeGoldenRunner``.
struct BridgeGoldenFixture {
    /// A process above the bridge.
    struct Ancestor {
        /// Executable path under the fixture's root.
        let path: String
        /// argv after argv[0].
        var arguments: [String] = []
    }

    let name: String
    /// The bridge's argv after argv[0] (`--source`, `--event`).
    var arguments: [String] = []
    /// On top of PATH and the socket / log overrides. `$ROOT` is the fixture's root.
    var environment: [String: String] = [:]
    /// Exactly the bytes the agent writes to the hook's stdin.
    var stdin: String
    /// Nearest first, by path under the runner's process tree (shared by all
    /// fixtures: a new executable is slow to launch the first time). The
    /// runner pads the chain with neutral processes to the six ancestors the
    /// bridge reads, so nothing of the test's own process tree (Xcode, a
    /// terminal, an agent running the tests) reaches it.
    var ancestors: [Ancestor] = []
    /// `.app` bundles in the process tree, by path, and their identifiers.
    var bundleIdentifiers: [String: String] = [:]
    /// What the stand-in island answers.
    var reply: String = "{}"
    /// Files to create first, by path under the fixture's root (`$ROOT` is
    /// replaced in contents), such as Grok's chat history.
    var files: [String: String] = [:]
    /// False: no socket at CODEISLAND_SOCKET_PATH (the island is not running).
    var hasSocket = true

    static let maxAncestry = 6

    /// The ancestry the bridge sees, padded with neutral processes.
    var paddedAncestors: [Ancestor] {
        var chain = ancestors
        var index = 1
        while chain.count < Self.maxAncestry {
            chain.append(Ancestor(path: "neutral/proc\(index)"))
            index += 1
        }
        return chain
    }

    static func infoPlist(bundleIdentifier: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>\(bundleIdentifier)</string></dict></plist>
        """
    }
}

/// What a recorded bridge run must reproduce: the event it forwarded
/// (normalized, see ``BridgeGoldenRun/normalizedForwarded``), its stdout and
/// its exit status.
struct BridgeGoldenExpectation: Equatable {
    let forwarded: String?
    let stdout: String
    let status: Int32
}

/// One bridge run under a fixture.
struct BridgeGoldenRun {
    /// The bytes the bridge sent to the island; nil when it never connected.
    let forwarded: Data?
    let stdout: Data
    let status: Int32
    let log: String
    /// The ancestry's pids, nearest first.
    let pids: [Int32]
    let root: String

    /// The forwarded event with what differs between runs replaced: ancestry
    /// pids by `$PID<n>` (`_ppid`, `_hook_ppid`, a `-ppid-` session id), the
    /// fixture's root by `$ROOT`, the home directory by `$HOME`. Keys sorted.
    var normalizedForwarded: String? {
        guard let forwarded else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: forwarded) else {
            return "unparsable: " + String(decoding: forwarded, as: UTF8.self)
        }
        return BridgeGoldenNormalizer(pids: pids, root: root).canonicalString(object)
    }

    var expectation: BridgeGoldenExpectation {
        BridgeGoldenExpectation(
            forwarded: normalizedForwarded,
            stdout: String(decoding: stdout, as: UTF8.self),
            status: status
        )
    }

    /// The exact forwarded bytes and debug log with pids, timestamps and the
    /// root replaced, for comparing two bridge builds byte for byte.
    var byteSignature: String {
        let normalizer = BridgeGoldenNormalizer(pids: pids, root: root)
        let event = forwarded.map { normalizer.textReplacingPids(String(decoding: $0, as: UTF8.self)) } ?? "<none>"
        let logLines = log.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            // "[2026-10-22T08:00:00Z] message"
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return String(line) }
            return String(line[line.index(after: close)...])
        }
        return [
            "event: " + event,
            "stdout: " + String(decoding: stdout, as: UTF8.self),
            "status: \(status)",
            "log:" + normalizer.textReplacingPids(logLines.joined(separator: "\n")),
        ].joined(separator: "\n")
    }
}

struct BridgeGoldenNormalizer {
    let pids: [Int32]
    let root: String
    var home: String = NSHomeDirectory()

    func canonicalString(_ object: Any) -> String {
        let normalized = normalize(object, key: nil)
        let data = (try? JSONSerialization.data(
            withJSONObject: normalized,
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func pidToken(_ pid: Int) -> String? {
        pids.firstIndex(of: Int32(pid)).map { "$PID\($0)" }
    }

    private func normalize(_ value: Any, key: String?) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = normalize(v, key: k) }
            return out
        }
        if let array = value as? [Any] {
            return array.map { normalize($0, key: nil) }
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           key == "_ppid" || key == "_hook_ppid", let token = pidToken(number.intValue) {
            return token
        }
        if let string = value as? String {
            var text = string
            if key == "session_id", let range = text.range(of: "-ppid-"),
               let pid = Int(text[range.upperBound...]), let token = pidToken(pid) {
                text = String(text[..<range.upperBound]) + token
            }
            return replacingPaths(text)
        }
        return value
    }

    func replacingPaths(_ text: String) -> String {
        var text = text.replacingOccurrences(of: root, with: "$ROOT")
        if !home.isEmpty, home != "/" {
            text = text.replacingOccurrences(of: home, with: "$HOME")
        }
        return text
    }

    /// Raw text with each ancestry pid replaced where the bridge writes one:
    /// a JSON number value (`"_ppid":123,`) or a `-ppid-123` session id.
    func textReplacingPids(_ text: String) -> String {
        var text = text
        for (index, pid) in pids.enumerated() {
            for (before, after) in [(":", ","), (":", "}"), ("-ppid-", "\""), ("-ppid-", "\\\""), ("-ppid-", "\n"), ("-ppid-", " ")] {
                text = text.replacingOccurrences(of: "\(before)\(pid)\(after)", with: "\(before)$PID\(index)\(after)")
            }
        }
        return text
    }
}

/// Runs codeisland-bridge on a fixture for real: under a process chain of
/// stub executables at the fixture's paths (with the argv it names), against
/// a stand-in island socket, with stdin from a file.
final class BridgeGoldenRunner {
    /// Why the golden runs cannot happen. A failure, never a skip: a skip
    /// would quietly drop the bridge's regression test.
    struct SetupError: Error, CustomStringConvertible {
        let description: String
    }

    let root: String
    /// Where the fixtures' ancestor executables live.
    var tree: String { root + "/tree" }
    /// The stand-in ancestor (Tests/GoldenAncestryStub), copied to every path
    /// a fixture names.
    private let stub: String

    init(stub: URL) throws {
        self.stub = stub.path
        // A short, neutral root: no path component may look like an agent
        // (`/pi…`, `/claude`, …) to the bridge's ancestry inference.
        let base = "/tmp/ci-golden-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        // realpath, not resolvingSymlinksInPath (which strips `/private`):
        // proc_pidpath and getcwd report /private/tmp/….
        guard let resolved = realpath(base, nil) else {
            throw SetupError(description: "cannot resolve \(base)")
        }
        root = String(cString: resolved)
        free(resolved)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(atPath: root)
    }

    /// FNV-1a of `text`, in hex: a directory name that is the same every run.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// The bridge built next to the test bundle, or the build named by
    /// `CODEISLAND_BRIDGE_UNDER_TEST` (a release build, say).
    static func bridgeUnderTest(for testCase: AnyClass) throws -> URL {
        if let path = ProcessInfo.processInfo.environment["CODEISLAND_BRIDGE_UNDER_TEST"] {
            return URL(fileURLWithPath: path)
        }
        return try builtNextToTests("codeisland-bridge", for: testCase)
    }

    /// The stand-in ancestor, built with the package next to the test bundle.
    static func builtStub(for testCase: AnyClass) throws -> URL {
        try builtNextToTests("codeisland-golden-stub", for: testCase)
    }

    private static func builtNextToTests(_ product: String, for testCase: AnyClass) throws -> URL {
        let url = Bundle(for: testCase).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(product)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw SetupError(description: "\(product) is not built next to the test bundle (swift build --build-tests)")
        }
        return url
    }

    func run(
        _ fixture: BridgeGoldenFixture,
        bridge: URL,
        deterministicHashing: Bool = false
    ) throws -> BridgeGoldenRun {
        let fm = FileManager.default
        // Not the fixture's name: a directory named like an agent
        // (`pi-…`, `kimi-…`) would match every process under it.
        let dir = root + "/case-" + Self.stableHash(fixture.name)
        try? fm.removeItem(atPath: dir)
        try fm.createDirectory(atPath: dir + "/work", withIntermediateDirectories: true)

        for (path, contents) in fixture.files {
            let full = dir + "/" + path
            try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(contents.replacingOccurrences(of: "$ROOT", with: dir).utf8).write(to: URL(fileURLWithPath: full))
        }

        let chain = fixture.paddedAncestors
        for ancestor in chain {
            let full = tree + "/" + ancestor.path
            guard !fm.fileExists(atPath: full) else { continue }
            try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.copyItem(atPath: stub, toPath: full)
        }
        for (app, identifier) in fixture.bundleIdentifiers {
            let plist = tree + "/" + app + "/Contents/Info.plist"
            try fm.createDirectory(atPath: (plist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(BridgeGoldenFixture.infoPlist(bundleIdentifier: identifier).utf8)
                .write(to: URL(fileURLWithPath: plist))
        }

        // Farthest ancestor first; each one runs what follows its first `--`.
        var command: [String] = []
        for ancestor in chain.reversed() {
            command += [tree + "/" + ancestor.path] + ancestor.arguments + ["--"]
        }
        command += [bridge.path] + fixture.arguments

        let server = fixture.hasSocket ? try XCTUnwrap(GoldenUnixServer(reply: Data(fixture.reply.utf8))) : nil
        let socketPath = server?.path ?? "/tmp/ci-golden-absent-\(UUID().uuidString.prefix(8)).sock"

        let stdinPath = dir + "/stdin"
        let stdoutPath = dir + "/stdout"
        let logPath = dir + "/bridge.log"
        let pidsPath = dir + "/pids"
        try Data(fixture.stdin.utf8).write(to: URL(fileURLWithPath: stdinPath))
        fm.createFile(atPath: stdoutPath, contents: nil)

        var environment = [
            "PATH": "/usr/bin:/bin",
            "CODEISLAND_SOCKET_PATH": socketPath,
            "CODEISLAND_BRIDGE_LOG": logPath,
            "GOLDEN_STUB_PIDS": pidsPath,
        ]
        for (key, value) in fixture.environment {
            environment[key] = value.replacingOccurrences(of: "$ROOT", with: dir)
        }
        if deterministicHashing {
            environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: dir + "/work")
        process.standardInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: stdinPath))
        process.standardOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: stdoutPath))
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 20) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 5)
            XCTFail("\(fixture.name): the bridge did not exit")
        }

        var forwarded: Data?
        if let server, server.waitUntilAccepted(timeout: 0.1), server.waitUntilServed(timeout: 5) {
            forwarded = server.received
        }

        let pidLines = (try? String(contentsOfFile: pidsPath, encoding: .utf8)) ?? ""
        var pidByPath: [String: Int32] = [:]
        for line in pidLines.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            pidByPath[String(parts[1])] = pid
        }
        let pids = chain.map { pidByPath[tree + "/" + $0.path] ?? -1 }

        return BridgeGoldenRun(
            forwarded: forwarded,
            stdout: (try? Data(contentsOf: URL(fileURLWithPath: stdoutPath))) ?? Data(),
            status: process.terminationStatus,
            log: (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "",
            pids: pids,
            root: dir
        )
    }
}

/// Minimal Unix-socket stand-in for HookServer: accepts one connection,
/// reads the event to EOF, answers with `reply`, closes. Gone with its
/// owner even when nothing connected (a dropped hook): its thread polls, so
/// it notices and closes the listener, and the socket file is removed.
final class GoldenUnixServer {
    let path: String
    private let state: State

    /// What the accepting thread shares; never the server itself, so the
    /// server can go while the thread still waits.
    private final class State {
        let listener: Int32
        let accepted = DispatchSemaphore(value: 0)
        let served = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _received = Data()
        private var _stopped = false

        init(listener: Int32) {
            self.listener = listener
        }

        var received: Data {
            get { lock.lock(); defer { lock.unlock() }; return _received }
            set { lock.lock(); _received = newValue; lock.unlock() }
        }

        var stopped: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _stopped }
            set { lock.lock(); _stopped = newValue; lock.unlock() }
        }
    }

    var received: Data { state.received }

    init?(reply: Data) {
        // sun_path is 104 bytes; NSTemporaryDirectory() can be too long for it.
        let path = "/tmp/ci-gold-\(UUID().uuidString.prefix(8)).sock"
        self.path = path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { _ = strcpy(ptr, $0) }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            close(listener)
            unlink(path)
            return nil
        }
        let state = State(listener: listener)
        self.state = state
        DispatchQueue.global().async {
            defer { close(state.listener) }
            var pending = pollfd(fd: state.listener, events: Int16(POLLIN), revents: 0)
            while !state.stopped {
                guard poll(&pending, 1, 50) > 0 else { continue }
                let client = accept(state.listener, nil, nil)
                guard client >= 0 else { return }
                // The bridge may be gone before the answer: no SIGPIPE for it.
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                state.accepted.signal()
                var buffer = [UInt8](repeating: 0, count: 4096)
                var data = Data()
                while true {
                    let n = read(client, &buffer, buffer.count)
                    if n <= 0 { break }
                    data.append(contentsOf: buffer[..<n])
                }
                state.received = data
                _ = reply.withUnsafeBytes { write(client, $0.baseAddress, reply.count) }
                close(client)
                state.served.signal()
                return
            }
        }
    }

    /// Whether the bridge connected at all. It exits only after reading the
    /// answer, so once it has exited this needs no real wait.
    func waitUntilAccepted(timeout: TimeInterval) -> Bool {
        state.accepted.wait(timeout: .now() + timeout) == .success
    }

    func waitUntilServed(timeout: TimeInterval) -> Bool {
        state.served.wait(timeout: .now() + timeout) == .success
    }

    deinit {
        state.stopped = true
        unlink(path)
    }
}
