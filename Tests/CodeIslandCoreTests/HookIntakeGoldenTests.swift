import Foundation
import XCTest
@testable import CodeIslandCore

/// HookIntake on the facts of every ``BridgeGoldenFixtures`` fixture, handed
/// over directly — no process, no socket — must produce what the bridge
/// recorded for it (``BridgeGoldenExpectations``): the interpretation is all
/// in there, and nothing in it reads anything but its facts.
final class HookIntakeGoldenTests: XCTestCase {
    private let root = "/golden-root/case"
    private let tree = "/golden-root/tree"
    private let home = "/golden-home"

    func testIntakeReproducesTheBridgesRecordedOutput() throws {
        for fixture in BridgeGoldenFixtures.all {
            guard let expected = BridgeGoldenExpectations.all[fixture.name] else {
                XCTFail("\(fixture.name): no recorded expectation")
                continue
            }
            let (forwarded, stdout) = deliver(fixture)
            XCTAssertEqual(forwarded, expected.forwarded, "\(fixture.name): forwarded event")
            XCTAssertEqual(stdout, expected.stdout, "\(fixture.name): stdout")
        }
    }

    /// The bridge hands HookIntake only `environmentKeys`; the rest of an
    /// environment must change nothing.
    func testIntakeReadsNoOtherEnvironment() throws {
        for fixture in BridgeGoldenFixtures.all {
            var noisy = fixture
            noisy.environment.merge(["UNRELATED_SECRET": "x", "PATH": "/usr/bin", "HOME": "/elsewhere"]) { current, _ in current }
            XCTAssertEqual(deliver(noisy, filterEnvironment: false).forwarded, deliver(fixture).forwarded, fixture.name)
        }
    }

    // MARK: - The bridge's flow, on injected facts

    private func deliver(
        _ fixture: BridgeGoldenFixture,
        filterEnvironment: Bool = true
    ) -> (forwarded: String?, stdout: String) {
        let arguments = ["codeisland-bridge"] + fixture.arguments
        let sourceTag = arguments.firstIndex(of: "--source").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let eventTag = arguments.firstIndex(of: "--event").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        var environment = fixture.environment.mapValues { $0.replacingOccurrences(of: "$ROOT", with: root) }
        if filterEnvironment {
            environment = environment.filter { HookIntake.environmentKeys.contains($0.key) }
        }

        var stdout = ""
        var wroteImmediate = false
        func writeImmediate(_ text: String?) {
            guard !wroteImmediate, let text else { return }
            wroteImmediate = true
            stdout += text
        }
        writeImmediate(HookIntake.immediateStdout(sourceTag: sourceTag, eventName: eventTag))
        guard HookIntake.admits(sourceTag: sourceTag, environment: environment), fixture.hasSocket else {
            return (nil, stdout)
        }
        let input = Data(fixture.stdin.utf8)
        guard !input.isEmpty, let object = HookIntake.stdinObject(input, sourceTag: sourceTag) else {
            return (nil, stdout)
        }

        let chain = fixture.paddedAncestors
        let pids = chain.indices.map { Int32(1001 + $0) }
        // The argv each stub ran with: its own arguments, then the rest of the chain.
        var command: [String] = []
        for ancestor in chain.reversed() {
            command += [tree + "/" + ancestor.path] + ancestor.arguments + ["--"]
        }
        command += ["codeisland-bridge"] + fixture.arguments
        let ancestry = chain.enumerated().map { index, ancestor -> HookIntake.Ancestor in
            let path = tree + "/" + ancestor.path
            let argvStart = command.firstIndex(of: path) ?? 0
            let bundle = HostHarnessResolver.outermostAppBundlePath(forExecutable: path).flatMap { app in
                fixture.bundleIdentifiers[String(app.dropFirst(tree.count + 1))]
            }
            return HookIntake.Ancestor(
                pid: pids[index],
                executablePath: path,
                arguments: { Array(command[argvStart...]) },
                bundleIdentifier: { bundle }
            )
        }
        let existing = Set(fixture.files.keys.map { root + "/" + $0 })

        let facts = HookIntake.Facts(
            sourceTag: sourceTag,
            eventTag: eventTag,
            environment: environment,
            parentPID: pids[0],
            ancestry: ancestry,
            workingDirectory: { self.root + "/work" },
            homeDirectory: { self.home },
            expandingTildeInPath: { path in
                path == "~" ? self.home : path.hasPrefix("~/") ? self.home + path.dropFirst() : path
            },
            stdinDigest: { CursorHookPayload.deliveryDigest(of: input) },
            fileExists: { existing.contains($0) }
        )
        guard var intake = HookIntake(stdin: object, facts: facts) else {
            return (nil, stdout)
        }
        writeImmediate(intake.immediateStdout)
        intake.addTerminalContext()
        if let answer = intake.stdout(forAnswer: Data(fixture.reply.utf8)) {
            stdout += String(decoding: answer, as: UTF8.self)
        }
        var normalizer = BridgeGoldenNormalizer(pids: pids, root: root)
        normalizer.home = home
        return (normalizer.canonicalString(intake.payload), stdout)
    }
}
