import Foundation
import CodeIslandCore

/// Cursor agent sessions: running processes matched to the agent
/// transcripts under `~/.cursor/projects/<encoded cwd>/agent-transcripts`.
enum CursorDiscovery {
    /// Check if Cursor is in YOLO mode by reading its settings
    static func detectCursorYoloMode() -> Bool {
        let settingsPath = NSHomeDirectory() + "/Library/Application Support/Cursor/User/settings.json"
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsPath),
              let data = fm.contents(atPath: settingsPath),
              let str = String(data: data, encoding: .utf8) else { return false }
        let stripped = ConfigInstaller.stripJSONComments(str)
        guard let strippedData = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: strippedData) as? [String: Any] else { return false }
        if json["cursor.general.yoloMode"] as? Bool == true { return true }
        if json["cursor.agent.enableYoloMode"] as? Bool == true { return true }
        return false
    }

    static func readModelFromCursorStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let transcriptBase = "\(home)/.cursor/projects/\(cwd.appProjectDirEncoded())/agent-transcripts"
        guard let best = findMostRecentCursorTranscript(in: transcriptBase, after: processStart, fm: fm) else {
            return nil
        }
        return readRecentFromCursorTranscript(path: best.path).0
    }

    static func findActiveCursorSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let cursorPids = AgentProcessFinder.findCursorPids(candidatePids: candidatePids)
        guard !cursorPids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let projectsBase = "\(home)/.cursor/projects"
        guard fm.fileExists(atPath: projectsBase) else { return [] }

        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in cursorPids {
            guard let cwd = ProcessTable.getCwd(for: pid), !cwd.isEmpty, !SessionDiscovery.isSubagentWorktree(cwd) else { continue }
            let processStart = ProcessTable.getProcessStartTime(pid)
            let transcriptBase = "\(projectsBase)/\(cwd.appProjectDirEncoded())/agent-transcripts"
            guard let best = findMostRecentCursorTranscript(in: transcriptBase, after: processStart, fm: fm) else { continue }
            let cursorFreshnessLimit: TimeInterval = processStart != nil ? -300 : -30
            if best.modified.timeIntervalSinceNow < cursorFreshnessLimit { continue }

            let sessionId = ((best.path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            let (model, messages) = readRecentFromCursorTranscript(path: best.path)
            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: best.modified,
                recentMessages: messages,
                source: "cursor",
                transcriptPath: best.path
            ))
        }

        return results
    }

    private static func findMostRecentCursorTranscript(
        in transcriptsBase: String,
        after processStart: Date?,
        fm: FileManager
    ) -> (path: String, modified: Date)? {
        guard let sessionDirs = try? fm.contentsOfDirectory(atPath: transcriptsBase) else { return nil }

        var best: (path: String, modified: Date)?
        for sessionDir in sessionDirs {
            let dirPath = "\(transcriptsBase)/\(sessionDir)"
            guard let candidate = SessionDiscovery.findMostRecentJSONLFile(in: dirPath, after: processStart, fm: fm) else { continue }
            if best == nil || candidate.modified > best!.modified {
                best = candidate
            }
        }
        return best
    }

    static func readRecentFromCursorTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, []) }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 65536)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, []) }

        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let role = json["role"] as? String,
                  let message = json["message"] as? [String: Any],
                  let textContent = JSONLTailer.normalizedCursorChatText(from: message["content"])
                    ?? SessionDiscovery.extractTextContent(from: message["content"])
            else { continue }

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
        return (nil, Array(combined.suffix(3).map { $0.1 }))
    }
}
