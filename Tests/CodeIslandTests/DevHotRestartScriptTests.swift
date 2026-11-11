import XCTest

/// `scripts/dev-hot-restart.sh` stops the build it runs before each
/// relaunch, and nothing else. It used to stop every process named
/// CodeIsland with SIGTERM — the user's installed island too, even with
/// `--socket-path` or `--isolated`, the way the changelog says to run a
/// development build next to it: no session save, and its SSH tunnels left
/// running without it.
///
/// The script is sourced and `pgrep`, `ps`, `kill` and `sleep` are stubbed:
/// nothing is signalled, and nothing named CodeIsland is started.
final class DevHotRestartScriptTests: XCTestCase {
    private static let installed = "/Applications/CodeIsland.app/Contents/MacOS/CodeIsland"
    private static let build = "/repo/.build/debug/CodeIsland"

    private var script: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/dev-hot-restart.sh").path
    }

    /// Runs `command` (`quit_app`, `launch_app`) with the processes `running`
    /// (pid → the path it was started from), the build at `appPath` and
    /// `--socket-path` set to `socketPath` ("" for none). Returns the
    /// signals sent, in order ("-TERM:4002"), what the script logged, and
    /// the command's status.
    private func run(
        _ command: String,
        running: [(pid: Int, path: String)],
        appPath: String = DevHotRestartScriptTests.build,
        socketPath: String
    ) throws -> (signalled: [String], logged: String, status: String) {
        let pids = running.map { String($0.pid) }.joined(separator: " ")
        let paths = running.map { "\($0.pid)) echo '\($0.path)' ;;" }.joined(separator: "\n")
        let driver = """
        source "$1"
        set +euo pipefail
        APP_PATH="$2"
        SOCKET_PATH="$3"
        SIGNALLED=""
        GONE=""
        pgrep() { for pid in \(pids); do echo "$pid"; done; }
        ps() {
          case "${*: -1}" in
        \(paths)
          esac
        }
        kill() {
          if [[ "$1" == "-0" ]]; then
            [[ " $GONE " == *" $2 "* ]] && return 1
            return 0
          fi
          SIGNALLED+=" $1:$2"
          GONE+=" $2"
        }
        sleep() { :; }
        log() { echo "$*" >&2; }
        fail() { echo "fail: $*" >&2; }
        \(command)
        status=$?
        wait
        echo "$status$SIGNALLED"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", driver, "dev-hot-restart-test", script, appPath, socketPath]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, err)
        XCTAssertFalse(err.contains("fail:"), err)
        var words = out.split(whereSeparator: \.isWhitespace).map(String.init)
        let status = words.isEmpty ? "" : words.removeFirst()
        return (words, err, status)
    }

    func testABuildOnASocketOfItsOwnLeavesTheInstalledIslandRunning() throws {
        let quit = try run("quit_app", running: [(4001, Self.installed), (4002, Self.build)], socketPath: "/tmp/codeisland-dev.sock")
        XCTAssertEqual(quit.signalled, ["-TERM:4002"])
    }

    func testTheInstalledIslandIsNeverStoppedOnTheDefaultSocketEither() throws {
        let quit = try run("quit_app", running: [(4001, Self.installed), (4002, Self.build)], socketPath: "")
        XCTAssertEqual(quit.signalled, ["-TERM:4002"])
    }

    func testOnlyTheInstalledIslandRunningNothingIsStopped() throws {
        let quit = try run("quit_app", running: [(4001, Self.installed)], socketPath: "/tmp/codeisland-dev.sock")
        XCTAssertEqual(quit.signalled, [])
    }

    /// Another copy of CodeIsland built elsewhere is not this build either.
    func testAnotherBuildOfCodeIslandIsNotStopped() throws {
        let quit = try run(
            "quit_app",
            running: [(4003, "/elsewhere/.build/debug/CodeIsland"), (4002, Self.build)],
            socketPath: "/tmp/codeisland-dev.sock"
        )
        XCTAssertEqual(quit.signalled, ["-TERM:4002"])
    }

    /// With the installed island serving the default socket, a build there
    /// would quit at once: the script says so instead of launching it.
    func testABuildIsNotLaunchedOnADefaultSocketAnotherIslandServes() throws {
        let launch = try run("launch_app", running: [(4001, Self.installed)], appPath: "/usr/bin/true", socketPath: "")
        XCTAssertEqual(launch.status, "1")
        XCTAssertTrue(launch.logged.contains("Not launching"), launch.logged)
        XCTAssertTrue(launch.logged.contains("4001"), launch.logged)
        XCTAssertTrue(launch.logged.contains("--socket-path"), launch.logged)
    }

    func testABuildIsLaunchedOnADefaultSocketNobodyServes() throws {
        let launch = try run("launch_app", running: [], appPath: "/usr/bin/true", socketPath: "")
        XCTAssertEqual(launch.status, "0")
        XCTAssertTrue(launch.logged.contains("Launching app: /usr/bin/true"), launch.logged)
    }

    /// Next to the installed island, on a socket of its own, it launches.
    func testABuildOnASocketOfItsOwnLaunchesNextToTheInstalledIsland() throws {
        let launch = try run(
            "launch_app",
            running: [(4001, Self.installed)],
            appPath: "/usr/bin/true",
            socketPath: "/tmp/codeisland-dev.sock"
        )
        XCTAssertEqual(launch.status, "0")
        XCTAssertTrue(launch.logged.contains("CODEISLAND_SOCKET_PATH=/tmp/codeisland-dev.sock"), launch.logged)
    }
}
