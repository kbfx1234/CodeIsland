import XCTest
@testable import CodeIsland

/// Calls only the Codex JSON installer. Every write is redirected into a fixture;
/// no app launch, global installation, environment override, or hook execution.
final class CodexInterruptTimeoutTests: XCTestCase {
    private func withFixture(_ body: (CLIConfig, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeIsland-CodexInterrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var codex = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "codex" })
        let fixturePath = directory.path
        codex.rootOverride = { fixturePath }
        let file = URL(fileURLWithPath: codex.fullPath)
        XCTAssertEqual(file.standardizedFileURL.deletingLastPathComponent(), directory.standardizedFileURL)
        try body(codex, file)
    }

    private func read(_ file: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private func entries(_ event: String, in root: [String: Any]) throws -> [[String: Any]] {
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        return try XCTUnwrap(hooks[event] as? [[String: Any]])
    }

    private func managedInterruptTimeouts(in root: [String: Any]) throws -> [Int] {
        try entries("Interrupt", in: root).flatMap { entry -> [Int] in
            let hooks = try XCTUnwrap(entry["hooks"] as? [[String: Any]])
            return hooks.compactMap { hook in
                guard let command = hook["command"] as? String,
                      command.contains("codeisland-bridge --source codex") else { return nil }
                return hook["timeout"] as? Int
            }
        }
    }

    func testFirstInstallGeneratesInterruptWithinTeardownCap() throws {
        try withFixture { codex, file in
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: codex, fm: .default))
            let root = try read(file)
            XCTAssertEqual(try managedInterruptTimeouts(in: root), [3])
            let stop = try XCTUnwrap(try entries("Stop", in: root).first?["hooks"] as? [[String: Any]])
            XCTAssertEqual(stop.first?["timeout"] as? Int, 5)
            let permission = try XCTUnwrap(try entries("PermissionRequest", in: root).first?["hooks"] as? [[String: Any]])
            XCTAssertEqual(permission.first?["timeout"] as? Int, 86400)
        }
    }

    func testRepeatedInstallDoesNotRestoreFiveSecondsOrDuplicateManagedHook() throws {
        try withFixture { codex, file in
            for _ in 0..<3 {
                XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: codex, fm: .default))
                XCTAssertEqual(try managedInterruptTimeouts(in: read(file)), [3])
            }
        }
    }

    func testUpgradeMergeRepairsStaleManagedTimeoutAndPreservesForeignHooksAndSettings() throws {
        try withFixture { codex, file in
            let foreignInterrupt: [String: Any] = ["matcher": "fixture", "hooks": [
                ["type": "command", "command": "/fixture/foreign-interrupt", "timeout": 2]
            ]]
            let foreignPermission: [String: Any] = ["hooks": [
                ["type": "command", "command": "/fixture/foreign-permission", "timeout": 30]
            ]]
            let unrelated: [[String: Any]] = [["fixture": "leave unchanged"]]
            let settings: [String: Any] = ["label": "fixture", "enabled": false]
            let seed: [String: Any] = ["fixtureSettings": settings, "hooks": [
                "Interrupt": [foreignInterrupt, ["hooks": [
                    ["type": "command", "command": "/fixture/.codeisland/codeisland-bridge --source codex", "timeout": 5]
                ]]],
                "PermissionRequest": [foreignPermission],
                "FixtureOnlyEvent": unrelated
            ]]
            try JSONSerialization.data(withJSONObject: seed, options: [.prettyPrinted, .sortedKeys]).write(to: file)

            for _ in 0..<2 {
                XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: codex, fm: .default))
                let root = try read(file)
                XCTAssertEqual(try managedInterruptTimeouts(in: root), [3])
                XCTAssertEqual(try entries("Interrupt", in: root).count, 2)
                XCTAssertEqual(try entries("Interrupt", in: root).first.map { NSDictionary(dictionary: $0) }, NSDictionary(dictionary: foreignInterrupt))
                XCTAssertEqual(try entries("PermissionRequest", in: root).first.map { NSDictionary(dictionary: $0) }, NSDictionary(dictionary: foreignPermission))
                XCTAssertEqual(try entries("FixtureOnlyEvent", in: root).map { NSDictionary(dictionary: $0) }, unrelated.map { NSDictionary(dictionary: $0) })
                XCTAssertEqual((root["fixtureSettings"] as? [String: Any]).map { NSDictionary(dictionary: $0) }, NSDictionary(dictionary: settings))
            }
        }
    }
}
