import Foundation

/// Small adapter for the Herdr Desktop window, whose terminals are owned by
/// herdr-core and identified by addresses such as `t3`.
enum HerdrDesktopController {
    typealias Runner = (_ path: String, _ args: [String], _ timeout: TimeInterval) -> Data?

    static func focus(
        terminalId: String,
        executablePath: String? = nil,
        runner: Runner = productionRunner
    ) -> Bool {
        guard let executable = executable(override: executablePath) else { return false }
        let payload: [String: String] = ["terminal": terminalId]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let arguments = String(data: data, encoding: .utf8),
              let response = runner(executable, ["do", "pane.focus", arguments], 2),
              let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            return false
        }
        return object["ok"] as? Bool == true
    }

    static func isFocused(
        terminalId: String,
        executablePath: String? = nil,
        runner: Runner = productionRunner
    ) -> Bool {
        guard let executable = executable(override: executablePath),
              let data = runner(executable, ["status"], 1),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return status["agent"] as? String == terminalId
    }

    private static func executable(override: String?) -> String? {
        if let override, !override.isEmpty { return override }
        let fm = FileManager.default
        return [
            NSHomeDirectory() + "/.local/bin/herdr-app",
            "/opt/homebrew/bin/herdr-app",
            "/usr/local/bin/herdr-app",
            "/Applications/Herdr.app/Contents/MacOS/Herdr",
        ].first(where: fm.isExecutableFile(atPath:))
    }

    private static func productionRunner(
        path: String,
        args: [String],
        timeout: TimeInterval
    ) -> Data? {
        ProcessRunner.run(path: path, args: args, timeout: timeout)
    }
}
