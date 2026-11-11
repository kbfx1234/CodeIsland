import Foundation
import CryptoKit
import CodeIslandCore

/// Kimi sessions: kimi-code's session index (`~/.kimi-code`) and legacy
/// kimi-cli's per-cwd session directories, and the wire-protocol transcript
/// reader for both.
enum KimiDiscovery {
    private static func md5Hash(of string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func findActiveKimiSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let kimiPids = AgentProcessFinder.findKimiPids(candidatePids: candidatePids)
        guard !kimiPids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        // Legacy kimi-cli hashes cwd under sessions/; kimi-code may only need
        // session_index.jsonl, so do not bail when these dirs are absent.
        let sessionsBases = ["\(home)/.kimi-code/sessions", "\(home)/.kimi/sessions"]
            .filter { fm.fileExists(atPath: $0) }

        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in kimiPids {
            guard let cwd = ProcessTable.getCwd(for: pid), !cwd.isEmpty, !SessionDiscovery.isSubagentWorktree(cwd) else { continue }
            let processStart = ProcessTable.getProcessStartTime(pid)

            // Prefer kimi-code session_index.jsonl (workDir → sessionDir mapping).
            if let indexed = discoverKimiCodeSessionFromIndex(
                home: home,
                cwd: cwd,
                pid: pid,
                processStart: processStart,
                fm: fm
            ), !seenSessionIds.contains(indexed.sessionId) {
                seenSessionIds.insert(indexed.sessionId)
                results.append(indexed)
                continue
            }

            // Legacy kimi-cli: ~/.kimi/sessions/<md5(cwd)>/<sessionId>/wire.jsonl
            let workdirHash = md5Hash(of: cwd)
            for sessionsBase in sessionsBases {
                let workdirPath = "\(sessionsBase)/\(workdirHash)"
                guard fm.fileExists(atPath: workdirPath),
                      let sessionDirs = try? fm.contentsOfDirectory(atPath: workdirPath) else { continue }

                var bestPath: String?
                var bestDate = Date.distantPast
                var bestSessionId: String?

                for sessionId in sessionDirs {
                    let wirePath = "\(workdirPath)/\(sessionId)/wire.jsonl"
                    guard fm.fileExists(atPath: wirePath),
                          let attrs = try? fm.attributesOfItem(atPath: wirePath),
                          let modified = attrs[.modificationDate] as? Date,
                          modified > bestDate else { continue }
                    if let start = processStart, modified < start.addingTimeInterval(-10) {
                        continue
                    }
                    bestPath = wirePath
                    bestDate = modified
                    bestSessionId = sessionId
                }

                guard let path = bestPath, let sessionId = bestSessionId else { continue }
                let freshnessLimit: TimeInterval = processStart != nil ? -300 : -30
                if bestDate.timeIntervalSinceNow < freshnessLimit { continue }

                let (_, messages) = readRecentFromKimiTranscript(path: path)
                guard !seenSessionIds.contains(sessionId) else { continue }
                seenSessionIds.insert(sessionId)

                results.append(DiscoveredSession(
                    sessionId: sessionId,
                    cwd: cwd,
                    tty: nil,
                    model: nil,
                    pid: pid,
                    modifiedAt: bestDate,
                    recentMessages: messages,
                    source: "kimi"
                ))
                break
            }
        }

        return results
    }

    /// kimi-code tracks sessions in `~/.kimi-code/session_index.jsonl` with
    /// `{ sessionId, sessionDir, workDir }` — workdir folders are no longer md5(cwd).
    /// `home` is the user home directory (fixture-injectable for tests).
    private static func discoverKimiCodeSessionFromIndex(
        home: String,
        cwd: String,
        pid: pid_t,
        processStart: Date?,
        fm: FileManager
    ) -> DiscoveredSession? {
        let indexPath = "\(home)/.kimi-code/session_index.jsonl"
        guard fm.fileExists(atPath: indexPath),
              let data = fm.contents(atPath: indexPath),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var best: (sessionId: String, sessionDir: String, modified: Date)?
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let workDir = json["workDir"] as? String,
                  workDir == cwd,
                  let sessionId = json["sessionId"] as? String,
                  let sessionDir = json["sessionDir"] as? String
            else { continue }

            let statePath = "\(sessionDir)/state.json"
            let stampPath = fm.fileExists(atPath: statePath) ? statePath : sessionDir
            guard let attrs = try? fm.attributesOfItem(atPath: stampPath),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            if let start = processStart, modified < start.addingTimeInterval(-10) {
                continue
            }
            if best == nil || modified > best!.modified {
                best = (sessionId, sessionDir, modified)
            }
        }

        guard let match = best else { return nil }
        let freshnessLimit: TimeInterval = processStart != nil ? -300 : -30
        if match.modified.timeIntervalSinceNow < freshnessLimit { return nil }

        // kimi-code keeps the transcript under agents/main/wire.jsonl.
        let wirePath = "\(match.sessionDir)/agents/main/wire.jsonl"
        let messages: [ChatMessage]
        if fm.fileExists(atPath: wirePath) {
            messages = readRecentFromKimiTranscript(path: wirePath).1
        } else {
            messages = []
        }

        return DiscoveredSession(
            sessionId: match.sessionId,
            cwd: cwd,
            tty: nil,
            model: nil,
            pid: pid,
            modifiedAt: match.modified,
            recentMessages: messages,
            source: "kimi"
        )
    }

    /// Test seam for ``discoverKimiCodeSessionFromIndex`` without exposing
    /// private ``DiscoveredSession``.
    static func discoverKimiCodeSessionFromIndexForTesting(
        home: String,
        cwd: String,
        pid: pid_t,
        processStart: Date?,
        fm: FileManager
    ) -> (sessionId: String, cwd: String, pid: pid_t?, source: String, messageTexts: [String])? {
        guard let match = discoverKimiCodeSessionFromIndex(
            home: home,
            cwd: cwd,
            pid: pid,
            processStart: processStart,
            fm: fm
        ) else { return nil }
        return (
            match.sessionId,
            match.cwd,
            match.pid,
            match.source,
            match.recentMessages.map(\.text)
        )
    }

    /// Parse recent chat turns from a Kimi wire.jsonl transcript.
    /// Supports legacy kimi-cli (`message.type = TurnBegin|ContentPart|TurnEnd`)
    /// and kimi-code (`turn.prompt` / `context.append_message` / `content.part`).
    static func readRecentFromKimiTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, []) }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 262_144)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, []) }

        var messages: [ChatMessage] = []
        var previousUserText: String?
        var previousAssistantText: String = ""
        /// True when the current open turn was started by `context.append_message`
        /// rather than `turn.prompt` — used so a later `turn.prompt` can replace
        /// the user text without flushing a duplicate line.
        var turnOpenedByAppend = false

        func flushTurn() {
            if let userText = previousUserText, !userText.isEmpty {
                messages.append(ChatMessage(isUser: true, text: userText))
                if !previousAssistantText.isEmpty {
                    messages.append(ChatMessage(isUser: false, text: previousAssistantText))
                }
            }
            previousUserText = nil
            previousAssistantText = ""
            turnOpenedByAppend = false
        }

        func textParts(from value: Any?) -> String {
            let parts: [[String: Any]]
            if let typed = value as? [[String: Any]] {
                parts = typed
            } else if let anyParts = value as? [Any] {
                parts = anyParts.compactMap { $0 as? [String: Any] }
            } else {
                return ""
            }
            return parts.compactMap { part -> String? in
                if let type = part["type"] as? String, type != "text" { return nil }
                return part["text"] as? String
            }.joined()
        }

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            // Legacy kimi-cli envelope: { "message": { "type": "TurnBegin"|... } }
            if let message = json["message"] as? [String: Any],
               let type = message["type"] as? String {
                switch type {
                case "TurnBegin":
                    flushTurn()
                    if let payload = message["payload"] as? [String: Any] {
                        previousUserText = textParts(from: payload["user_input"])
                    }
                case "ContentPart":
                    if let payload = message["payload"] as? [String: Any],
                       payload["type"] as? String == "text",
                       let textContent = payload["text"] as? String {
                        previousAssistantText += textContent
                    }
                case "TurnEnd":
                    flushTurn()
                default:
                    break
                }
                continue
            }

            // kimi-code wire protocol (v1.4+).
            // Observed order: turn.prompt opens a turn, then optional
            // context.append_message (same user text), then content.part replies.
            // Prefer turn.prompt when both exist. If append_message arrives first
            // (defensive), mark the turn so the later turn.prompt replaces the
            // user text instead of flushing a duplicate user line.
            switch json["type"] as? String {
            case "turn.prompt":
                let promptText = textParts(from: json["input"])
                if turnOpenedByAppend && previousAssistantText.isEmpty {
                    // Replace append-opened user text only when turn.prompt has
                    // content; an empty prompt must not wipe the append line.
                    if !promptText.isEmpty {
                        previousUserText = promptText
                    }
                } else {
                    flushTurn()
                    previousUserText = promptText
                }
                turnOpenedByAppend = false
            case "context.append_message":
                if let message = json["message"] as? [String: Any],
                   message["role"] as? String == "user" {
                    let userText = textParts(from: message["content"])
                    if !userText.isEmpty {
                        // Prefer turn.prompt when both exist for the same turn;
                        // only start a turn here if we don't already have one open.
                        if previousUserText == nil {
                            previousUserText = userText
                            turnOpenedByAppend = true
                        }
                    }
                }
            case "context.append_loop_event":
                if let event = json["event"] as? [String: Any],
                   event["type"] as? String == "content.part",
                   let part = event["part"] as? [String: Any],
                   part["type"] as? String == "text",
                   let textContent = part["text"] as? String {
                    previousAssistantText += textContent
                }
            default:
                break
            }
        }

        flushTurn()
        return (nil, Array(messages.suffix(3)))
    }
}
