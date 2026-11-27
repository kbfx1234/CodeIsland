import AppKit
import Darwin
import SQLite3
import CodeIslandCore

/// Process-side half of host-harness support (#321): reads the agent's
/// ancestry, verifies the harness server, and performs the jump. The matching
/// rules themselves live in `HostHarnessResolver` (CodeIslandCore) so they
/// stay pure and tested.
enum HostHarnessSupport {
    /// Outcome of one ancestry probe. `conclusive` is false when the walk
    /// could not even read the starting process (it exited before we looked);
    /// only conclusive results are worth caching.
    struct ProbeResult: Sendable {
        let harness: HostHarness?
        let conclusive: Bool
    }

    private static let environmentKeys: Set<String> = ["T3CODE_HOME"]

    /// Walk `cliPid`'s ancestry and resolve the hosting harness, if any.
    /// Blocking (sysctl + a small file read) — call off the main actor.
    nonisolated static func probe(cliPid: pid_t) -> ProbeResult {
        let ancestry = collectAncestry(from: cliPid)
        guard !ancestry.isEmpty else { return ProbeResult(harness: nil, conclusive: false) }
        guard var harness = HostHarnessResolver.detect(
            ancestry: ancestry,
            homeDirectory: NSHomeDirectory()
        ) else {
            return ProbeResult(harness: nil, conclusive: true)
        }
        if case .browser = harness.surface {
            verifyBrowserOrigin(&harness)
        }
        return ProbeResult(harness: harness, conclusive: true)
    }

    // MARK: - Ancestry

    private nonisolated static func collectAncestry(from pid: pid_t) -> [ProcessAncestor] {
        var result: [ProcessAncestor] = []
        var current = pid
        var visited = Set<pid_t>()
        while current > 1, !visited.contains(current), result.count < HostHarnessResolver.maxAncestryDepth {
            visited.insert(current)
            guard let parent = parentPID(of: current) else { break }
            let path = executablePath(for: current)
            let parsed = procArgs(for: current)
            result.append(ProcessAncestor(
                pid: current,
                executablePath: path,
                arguments: parsed?.arguments ?? [],
                environment: parsed?.environment ?? [:],
                bundleIdentifier: path.flatMap(bundleIdentifier(forExecutable:))
            ))
            current = parent
        }
        return result
    }

    private nonisolated static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private nonisolated static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private nonisolated static func procArgs(for pid: pid_t) -> (arguments: [String], environment: [String: String])? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return ProcArgsParser.parse(Array(buffer.prefix(size)), environmentKeys: environmentKeys)
    }

    private nonisolated static func bundleIdentifier(forExecutable path: String) -> String? {
        guard let appPath = HostHarnessResolver.outermostAppBundlePath(forExecutable: path) else { return nil }
        return Bundle(path: appPath)?.bundleIdentifier
    }

    // MARK: - T3 server

    /// Pin the browser origin to the state directory whose runtime file was
    /// written by this very server process. Without a match the harness stays
    /// un-jumpable (hidden affordance) instead of guessing a port.
    private nonisolated static func verifyBrowserOrigin(_ harness: inout HostHarness) {
        guard let runtime = verifiedT3Runtime(for: harness) else { return }
        harness.browserOrigin = runtime.origin
        harness.stateDirectories = [runtime.directory]
    }

    private nonisolated static func verifiedT3Runtime(for harness: HostHarness) -> (directory: String, origin: String)? {
        for directory in harness.stateDirectories {
            let path = (directory as NSString).appendingPathComponent("server-runtime.json")
            guard let data = FileManager.default.contents(atPath: path),
                  let origin = HostHarnessResolver.t3BrowserOrigin(runtimeJSON: data, expectedPid: harness.serverPid) else {
                continue
            }
            return (directory, origin)
        }
        return nil
    }

    /// Thread URL when T3's state maps this agent session to a thread, else
    /// T3's root (its thread list). The mapping is read at click time — the
    /// harness records it lazily.
    nonisolated static func t3BrowserURL(
        harness: HostHarness,
        sessionId: String?,
        session: SessionSnapshot
    ) -> URL? {
        guard let origin = harness.browserOrigin else { return nil }
        let thread = harness.stateDirectories.first.flatMap {
            t3Thread(in: $0, sessionId: sessionId, session: session)
        }
        return HostHarnessResolver.t3BrowserURL(origin: origin, environmentId: thread?.environmentId, threadId: thread?.threadId)
    }

    nonisolated static func t3DesktopURL(harness: HostHarness, sessionId: String?, session: SessionSnapshot) -> URL? {
        guard case .desktopApp(let bundleId) = harness.surface,
              let runtime = verifiedT3Runtime(for: harness),
              let thread = t3Thread(in: runtime.directory, sessionId: sessionId, session: session) else { return nil }
        return HostHarnessResolver.t3DesktopURL(bundleId: bundleId, environmentId: thread.environmentId, threadId: thread.threadId)
    }

    private nonisolated static func t3Thread(
        in directory: String, sessionId: String?, session: SessionSnapshot
    ) -> (environmentId: String, threadId: String)? {
        let directory = directory as NSString
        guard let environmentId = try? String(
            contentsOfFile: directory.appendingPathComponent("environment-id"),
            encoding: .utf8
        ) else { return nil }
        let candidates = HostHarnessResolver.providerSessionIdCandidates(
            sessionId: sessionId ?? "",
            source: session.source,
            providerSessionId: session.providerSessionId
        )
        let provider: String
        switch session.source {
        case "claude": provider = "claudeAgent"
        case "cursor-cli": provider = "cursor"
        default: provider = session.source
        }
        let v2Path = directory.appendingPathComponent("statev2.sqlite")
        let usesV2 = FileManager.default.fileExists(atPath: v2Path)
        guard let threadId = lookupT3ThreadId(
            databasePath: usesV2 ? v2Path : directory.appendingPathComponent("state.sqlite"),
            usesV2: usesV2,
            provider: provider,
            providerSessionIds: candidates
        ) else { return nil }
        return (environmentId, threadId)
    }

    // T3 v2 stores the native identity on its provider-thread projection.
    // Multiple rows may belong to the same thread after a provider restart.
    private static let t3V2ThreadSQL = """
        SELECT DISTINCT provider_thread.thread_id
        FROM orchestration_v2_projection_provider_threads AS provider_thread
        JOIN orchestration_v2_projection_threads AS thread ON thread.thread_id = provider_thread.thread_id
        WHERE provider_thread.provider = ?1
          AND thread.deleted_at IS NULL
          AND CASE WHEN json_valid(provider_thread.payload_json)
                   THEN json_extract(provider_thread.payload_json, '$.nativeThreadRef.nativeId')
              END IN (?2, ?3)
        LIMIT 2;
        """

    private static let t3LegacyThreadSQL = """
        SELECT DISTINCT thread_id
        FROM provider_session_runtime
        WHERE provider_name = ?1
          AND thread_id IS NOT NULL
          AND CASE WHEN json_valid(resume_cursor_json) THEN
                CASE ?1
                  WHEN 'claudeAgent' THEN json_extract(resume_cursor_json, '$.resume')
                  WHEN 'codex' THEN json_extract(resume_cursor_json, '$.threadId')
                  ELSE COALESCE(
                      json_extract(resume_cursor_json, '$.sessionId'),
                      json_extract(resume_cursor_json, '$.threadId')
                  )
                END
              END IN (?2, ?3)
        """

    private nonisolated static func lookupT3ThreadId(
        databasePath: String, usesV2: Bool, provider: String, providerSessionIds: [String]
    ) -> String? {
        guard !providerSessionIds.isEmpty else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close_v2(db) }
            return nil
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 500)

        var legacySQL = t3LegacyThreadSQL
        if usesV2 {
            guard let matches = t3ThreadMatches(db: db, sql: t3V2ThreadSQL, provider: provider, ids: providerSessionIds) else {
                return nil
            }
            if !matches.isEmpty { return matches.count == 1 ? matches.first : nil }
            // A migrated resume cursor can target a thread still present in this database.
            legacySQL += """

                AND thread_id IN (
                    SELECT thread_id FROM orchestration_v2_projection_threads WHERE deleted_at IS NULL
                )
                """
        }
        let matches = t3ThreadMatches(db: db, sql: legacySQL + "\nLIMIT 2;", provider: provider, ids: providerSessionIds)
        return matches?.count == 1 ? matches?.first : nil
    }

    private nonisolated static func t3ThreadMatches(db: OpaquePointer, sql: String, provider: String, ids: [String]) -> [String]? {
        guard let first = ids.first else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, provider, -1, transient)
        sqlite3_bind_text(statement, 2, first, Int32(first.utf8.count), transient)
        if let second = ids.dropFirst().first {
            sqlite3_bind_text(statement, 3, second, Int32(second.utf8.count), transient)
        }
        var matches: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0) else { return nil }
            matches.append(String(cString: id))
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? matches : nil
    }

    // MARK: - Jump

    /// Bring the harness forward for this session. Returns false when there
    /// is nowhere verified to go (callers hide the affordance in that case,
    /// so this is a safety net, not a user-visible path).
    @discardableResult
    static func activate(harness: HostHarness, session: SessionSnapshot, sessionId: String?) -> Bool {
        switch harness.surface {
        case .desktopApp(let bundleId):
            guard let path = harness.desktopApplicationPath else {
                guard let appURL = TerminalActivator.appURL(forBundleId: bundleId) else { return false }
                activateT3Desktop(appURL: appURL, bundleId: bundleId)
                return true
            }
            guard let bundle = Bundle(path: path), bundle.bundleIdentifier?.lowercased() == bundleId else { return false }
            let appURL = bundle.bundleURL
            guard let schemes = bundle.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] else {
                activateT3Desktop(appURL: appURL, bundleId: bundleId)
                return true
            }
            let registeredSchemes = schemes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            DispatchQueue.global(qos: .userInitiated).async {
                let link = t3DesktopURL(harness: harness, sessionId: sessionId, session: session)
                DispatchQueue.main.async {
                    guard let link, let scheme = link.scheme, registeredSchemes.contains(scheme) else {
                        activateT3Desktop(appURL: appURL, bundleId: bundleId)
                        return
                    }
                    NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                        guard error != nil else { return }
                        DispatchQueue.main.async { activateT3Desktop(appURL: appURL, bundleId: bundleId) }
                    }
                }
            }
            return true
        case .browser:
            guard harness.browserOrigin != nil else { return false }
            // The sqlite read is small but still I/O; keep it off the main actor.
            DispatchQueue.global(qos: .userInitiated).async {
                guard let url = t3BrowserURL(harness: harness, sessionId: sessionId, session: session) else { return }
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            return true
        }
    }

    private static func activateT3Desktop(appURL: URL, bundleId: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first(where: {
            $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL
        }) {
            if app.isHidden { app.unhide() }
            app.activate()
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Did the jump land? Desktop: the harness app is frontmost. Browser: the
    /// default web browser is frontmost — which tab is showing is not
    /// observable, so this is app-level only (like Warp/Alacritty).
    static func isFrontmost(_ harness: HostHarness) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() else { return false }
        switch harness.surface {
        case .desktopApp(let bundleId):
            return front == bundleId.lowercased()
        case .browser:
            guard let probe = URL(string: "http://localhost"),
                  let browserURL = NSWorkspace.shared.urlForApplication(toOpen: probe),
                  let browserId = Bundle(url: browserURL)?.bundleIdentifier?.lowercased() else {
                return false
            }
            return front == browserId
        }
    }
}
