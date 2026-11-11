import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The strict KERN_PROCARGS2 reader against real processes. If it rejected a
/// real environment block, every Claude/Codex/Grok process would count as
/// "environment unknown"; if it accepted a withheld one, the process would be
/// pinned to the default root. Children are `sleep` — never an AI CLI.
final class ConfigRootEnvironmentTests: XCTestCase {
    private var children: [Process] = []
    private var sandbox: String!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-root-env-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for child in children where child.isRunning { child.terminate() }
        children.removeAll()
        try? FileManager.default.removeItem(atPath: sandbox)
        super.tearDown()
    }

    private func spawn(_ executable: String, environment: [String: String]) throws -> pid_t {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["30"]
        child.environment = environment
        try child.run()
        children.append(child)
        return child.processIdentifier
    }

    /// A copy of `sleep` is an ordinary (non-platform) binary, like the
    /// claude / codex / grok executables, whose environment the kernel shows
    /// to the same user.
    private func spawnOrdinary(environment: [String: String]) throws -> pid_t {
        let copy = sandbox + "/sleep-copy"
        if !FileManager.default.fileExists(atPath: copy) {
            try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: copy)
        }
        return try spawn(copy, environment: environment)
    }

    private func codexScan(registered: [ExtraConfigDir] = []) -> ConfigRootScan {
        ConfigRootScan(
            cli: .codex,
            defaultRoot: "/Users/nobody/.codex",
            snapshot: ConfigRootSnapshot(cli: .codex, primary: "/p", defaultRoot: "/Users/nobody/.codex", registered: registered)
        )
    }

    func testAChildsConfigRootVariablesAreReadFromItsOwnEnvironment() throws {
        let pid = try spawnOrdinary(environment: ["PATH": "/usr/bin:/bin", "CODEX_HOME": "/acct/codex-work"])
        guard let environment = SessionDiscovery.configRootEnvironment(for: pid) else {
            throw XCTSkip("this kernel withholds even an ordinary binary's environment")
        }
        XCTAssertEqual(environment, ["CODEX_HOME": "/acct/codex-work"])
        XCTAssertEqual(codexScan().lookup(pid: pid), .root("/acct/codex-work"))
        XCTAssertEqual(
            codexScan(registered: [ExtraConfigDir(cli: .codex, path: "/acct/codex-work", enabled: false)]).lookup(pid: pid),
            .paused,
            "a paused extra dir drops its processes from discovery"
        )
    }

    func testAnUnsetVariableReadsAsUnsetNotUnknown() throws {
        let pid = try spawnOrdinary(environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()])
        guard let environment = SessionDiscovery.configRootEnvironment(for: pid) else {
            throw XCTSkip("this kernel withholds even an ordinary binary's environment")
        }
        XCTAssertEqual(environment, [:])
        XCTAssertEqual(codexScan().lookup(pid: pid), .root("/Users/nobody/.codex"), "unset: the default root")
    }

    /// The kernel strips the environment of platform binaries such as
    /// /bin/sleep: the buffer ends after argv. That is "unknown", never
    /// "unset" — the lenient parser used to pin such a process to the
    /// default root.
    func testAWithheldEnvironmentIsUnknown() throws {
        let pid = try spawn("/bin/sleep", environment: ["PATH": "/usr/bin:/bin", "CODEX_HOME": "/acct/codex-work"])
        guard SessionDiscovery.configRootEnvironment(for: pid) == nil else {
            throw XCTSkip("this kernel shows /bin/sleep's environment; nothing withheld to test")
        }
        XCTAssertEqual(codexScan().lookup(pid: pid), .unknown)
    }

    func testOwnProcessAndAMissingProcess() {
        XCTAssertNotNil(SessionDiscovery.configRootEnvironment(for: getpid()))
        XCTAssertNil(SessionDiscovery.configRootEnvironment(for: 0x3FFF_FFFF), "no such process: unknown")
    }
}
