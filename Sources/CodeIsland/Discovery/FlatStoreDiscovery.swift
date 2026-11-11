import Foundation
import CodeIslandCore

/// Qoder, CodeBuddy and Factory (droid) sessions: JSONL transcripts kept
/// flat in one directory per project (`~/.qoder/projects`,
/// `~/.codebuddy/projects`, `~/.factory/sessions`), and the readers for each
/// agent's flavor of the format.
enum FlatStoreDiscovery {
    static func qoderLatestFinishedTurnTimestamp(
        sessionId: String,
        session: SessionSnapshot
    ) -> Date? {
        guard let transcriptPath = qoderTranscriptPath(sessionId: sessionId, cwd: session.cwd),
              let tail = SessionDiscovery.readTranscriptTail(path: transcriptPath, maxBytes: 131072) else {
            return nil
        }
        return qoderLatestTerminalTurnTimestamp(in: tail)
    }

    static func codeBuddyLatestFinishedTurnTimestamp(
        sessionId: String,
        session: SessionSnapshot
    ) -> Date? {
        guard let transcriptPath = codeBuddyTranscriptPath(sessionId: sessionId, cwd: session.cwd),
              let tail = SessionDiscovery.readTranscriptTail(path: transcriptPath, maxBytes: 131072) else {
            return nil
        }
        return codeBuddyLatestTerminalTurnTimestamp(in: tail)
    }

    /// Config roots a Qoder session's transcript can live under: the international
    /// build uses ~/.qoder, the China build (`qoderclicn`) uses ~/.qoder-cn (#289).
    static let qoderConfigRoots = [".qoder", ".qoder-cn"]

    private static func qoderTranscriptPath(sessionId: String, cwd: String?) -> String? {
        guard let cwd else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = qoderConfigRoots.flatMap { root -> [String] in
            let projectPath = home
                .appendingPathComponent("\(root)/projects/\(cwd.claudeProjectDirEncoded())")
            return [
                projectPath.appendingPathComponent("\(sessionId).jsonl").path,
                projectPath.appendingPathComponent("transcript/\(sessionId).jsonl").path,
            ]
        }

        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func codeBuddyTranscriptPath(sessionId: String, cwd: String?) -> String? {
        guard let cwd else { return nil }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codebuddy/projects/\(cwd.appProjectDirEncoded())/\(sessionId).jsonl").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static func findFlatStoreSessions(
        pids: [pid_t],
        basePath: String,
        source: String,
        projectEncoder: (String) -> String,
        transcriptReader: (String) -> (String?, [ChatMessage])
    ) -> [DiscoveredSession] {
        guard !pids.isEmpty else { return [] }

        let fm = FileManager.default
        guard fm.fileExists(atPath: basePath) else { return [] }

        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in pids {
            guard let cwd = ProcessTable.getCwd(for: pid), !cwd.isEmpty, !SessionDiscovery.isSubagentWorktree(cwd) else { continue }
            let processStart = ProcessTable.getProcessStartTime(pid)
            let projectPath = "\(basePath)/\(projectEncoder(cwd))"
            guard let best = SessionDiscovery.findMostRecentJSONLFile(in: projectPath, after: processStart, fm: fm) else { continue }
            if best.modified.timeIntervalSinceNow < -300 { continue }

            let sessionId = ((best.path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            let (model, messages) = transcriptReader(best.path)
            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: best.modified,
                recentMessages: messages,
                source: source
            ))
        }

        return results
    }

    static func findActiveQoderSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return findFlatStoreSessions(
            pids: AgentProcessFinder.findQoderPids(candidatePids: candidatePids),
            basePath: "\(home)/.qoder/projects",
            source: "qoder",
            projectEncoder: { $0.claudeProjectDirEncoded() },
            transcriptReader: { ClaudeDiscovery.readRecentFromTranscript(path: $0) }
        )
    }

    static func findActiveCodeBuddySessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return findFlatStoreSessions(
            pids: AgentProcessFinder.findCodeBuddyPids(candidatePids: candidatePids),
            basePath: "\(home)/.codebuddy/projects",
            source: "codebuddy",
            projectEncoder: { $0.appProjectDirEncoded() },
            transcriptReader: { readRecentFromCodeBuddyTranscript(path: $0) }
        )
    }

    static func findActiveFactorySessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return findFlatStoreSessions(
            pids: AgentProcessFinder.findFactoryPids(candidatePids: candidatePids),
            basePath: "\(home)/.factory/sessions",
            source: "droid",
            projectEncoder: { $0.claudeProjectDirEncoded() },
            transcriptReader: { readRecentFromFactoryTranscript(path: $0) }
        )
    }

    static func readRecentFromCodeBuddyTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, []) }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 65536)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, []) }

        var model: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "message",
                  let role = json["role"] as? String,
                  let textContent = SessionDiscovery.extractTextContent(from: json["content"])
            else { continue }

            if model == nil,
               let providerData = json["providerData"] as? [String: Any],
               let messageModel = providerData["model"] as? String, !messageModel.isEmpty {
                model = messageModel
            }

            if role == "user" {
                userMessages.append((index, textContent))
            } else if role == "assistant" {
                assistantMessages.append((index, textContent))
            }
            index += 1
        }

        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        return (model, Array(combined.suffix(3).map { $0.1 }))
    }

    static func readRecentFromFactoryTranscript(path: String) -> (String?, [ChatMessage]) {
        let sidecarPath = path.replacingOccurrences(of: ".jsonl", with: ".settings.json")
        var model: String?
        if let data = FileManager.default.contents(atPath: sidecarPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let foundModel = json["model"] as? String, !foundModel.isEmpty {
            model = foundModel
        }
        let (_, messages) = ClaudeDiscovery.readRecentFromTranscript(path: path)
        return (model, messages)
    }

    static func qoderLatestTerminalTurnTimestamp(in transcriptTail: String) -> Date? {
        var latest: Date?

        for line in transcriptTail.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let timestamp = json["timestamp"] as? String,
                  let date = SessionDiscovery.parseISO8601Timestamp(timestamp) else { continue }

            let type = json["type"] as? String ?? ""
            if type == "progress",
               let data = json["data"] as? [String: Any] {
                let hookEvent = (data["hookEvent"] as? String) ?? (data["hookName"] as? String) ?? ""
                if hookEvent == "Stop" || hookEvent == "SessionEnd" {
                    if latest == nil || date > latest! {
                        latest = date
                    }
                    continue
                }
            }

            if type == "assistant",
               let message = json["message"] as? [String: Any],
               (message["role"] as? String) == "assistant",
               SessionDiscovery.extractTextContent(from: message["content"]) != nil {
                if latest == nil || date > latest! {
                    latest = date
                }
            }
        }

        return latest
    }

    static func codeBuddyLatestTerminalTurnTimestamp(in transcriptTail: String) -> Date? {
        var latest: Date?

        for line in transcriptTail.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "message",
                  (json["role"] as? String) == "assistant",
                  (json["status"] as? String) == "completed",
                  SessionDiscovery.extractTextContent(from: json["content"]) != nil else { continue }

            let date: Date?
            if let rawTimestamp = json["timestamp"] as? NSNumber {
                date = Date(timeIntervalSince1970: rawTimestamp.doubleValue / 1000)
            } else if let rawTimestamp = json["timestamp"] as? Double {
                date = Date(timeIntervalSince1970: rawTimestamp / 1000)
            } else if let rawTimestamp = json["timestamp"] as? Int64 {
                date = Date(timeIntervalSince1970: TimeInterval(rawTimestamp) / 1000)
            } else {
                date = nil
            }

            guard let date else { continue }
            if latest == nil || date > latest! {
                latest = date
            }
        }

        return latest
    }
}
