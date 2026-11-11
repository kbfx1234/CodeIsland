import XCTest
@testable import CodeIsland
import CodeIslandCore

/// pi and Oh My Pi are matched by their programs' whole names: as substrings,
/// "/pi" and "/bin/pi" also took pinentry (which gpg starts to sign a
/// commit), pigz, pico, and everything under a home folder like /Users/pierre,
/// so a pi card could be watched on one of them, and SIGTERMed with it.
final class PiProcessMatchingTests: XCTestCase {
    private let notPi = [
        "/opt/homebrew/bin/pinentry-mac",
        "/opt/homebrew/bin/pinentry",
        "/opt/homebrew/bin/pigz",
        "/usr/bin/pico",
        "/Users/pierre/.nvm/versions/node/v22.11.0/bin/node",
        "/Users/pierre/.local/bin/pipx",
    ]
    private let pi = [
        "/opt/homebrew/bin/pi",
        "/Users/pierre/.local/bin/pi",
        "/Users/pierre/.local/bin/omp",
        "/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/dist/pi",
    ]

    func testTheResolverTakesPiAndOmpOnlyByName() {
        for path in notPi {
            XCTAssertFalse(CLIProcessResolver.sourceMatchesExecutablePath(path, source: "pi"), path)
        }
        for path in pi {
            XCTAssertTrue(CLIProcessResolver.sourceMatchesExecutablePath(path, source: "pi"), path)
        }
        XCTAssertTrue(CLIProcessResolver.sourceMatchesExecutablePath("/Users/pierre/.local/bin/omp", source: "omp"))
    }

    func testDiscoveryTakesPiByNameOrByItsPackage() {
        var paths: [pid_t: String] = [:]
        var argv: [pid_t: [String]] = [:]
        var next: pid_t = 100
        for path in notPi {
            paths[next] = path
            argv[next] = [path]
            next += 1
        }
        var expected: Set<pid_t> = []
        for path in pi {
            paths[next] = path
            argv[next] = [path]
            expected.insert(next)
            next += 1
        }
        // The npm install: node runs the package's script.
        paths[next] = "/opt/homebrew/bin/node"
        argv[next] = ["node", "/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/dist/cli.js"]
        expected.insert(next)

        let found = AgentProcessFinder.findPiPids(
            candidatePids: paths.keys.sorted(),
            executablePath: { paths[$0] },
            arguments: { argv[$0] }
        )
        XCTAssertEqual(Set(found), expected)
    }
}
