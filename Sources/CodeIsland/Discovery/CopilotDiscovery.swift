import Foundation
import CodeIslandCore

/// GitHub Copilot CLI sessions: running processes matched to their
/// directories under `~/.copilot/session-state`.
enum CopilotDiscovery {
    static func readModelFromCopilotStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let sessionsBase = "\(home)/.copilot/session-state"
        guard let best = findRecentCopilotSession(base: sessionsBase, cwd: cwd, after: processStart, fm: fm) else {
            return nil
        }
        return readRecentFromCopilotTranscript(path: best.path).0
    }

    static func findActiveCopilotSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let copilotPids = AgentProcessFinder.findCopilotPids(candidatePids: candidatePids)
        guard !copilotPids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let sessionsBase = "\(home)/.copilot/session-state"
        guard fm.fileExists(atPath: sessionsBase) else { return [] }

        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in copilotPids {
            guard let cwd = ProcessTable.getCwd(for: pid), !cwd.isEmpty, !SessionDiscovery.isSubagentWorktree(cwd) else { continue }
            let processStart = ProcessTable.getProcessStartTime(pid)
            guard let best = findRecentCopilotSession(base: sessionsBase, cwd: cwd, after: processStart, fm: fm) else {
                continue
            }
            if best.modified.timeIntervalSinceNow < -300 { continue }

            let sessionDir = (best.path as NSString).deletingLastPathComponent
            let sessionId = (sessionDir as NSString).lastPathComponent
            guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            let (model, messages) = readRecentFromCopilotTranscript(path: best.path)
            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: best.modified,
                recentMessages: messages,
                source: "copilot"
            ))
        }

        return results
    }

    private static func findRecentCopilotSession(
        base: String,
        cwd: String,
        after processStart: Date?,
        fm: FileManager
    ) -> (path: String, modified: Date)? {
        guard let dirs = try? fm.contentsOfDirectory(atPath: base) else { return nil }

        let candidates = dirs.compactMap { dir -> (path: String, modified: Date)? in
            let fullPath = "\(base)/\(dir)/events.jsonl"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date else { return nil }
            return (fullPath, modified)
        }.sorted { $0.modified > $1.modified }

        for candidate in candidates.prefix(50) {
            if let start = processStart, candidate.modified < start.addingTimeInterval(-10) {
                continue
            }
            if copilotSessionMatchesCwd(path: candidate.path, cwd: cwd) {
                return candidate
            }
        }
        return nil
    }

    private static func copilotSessionMatchesCwd(path: String, cwd: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 32768)
        guard let text = String(data: data, encoding: .utf8) else { return false }

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  let payload = json["data"] as? [String: Any] else { continue }

            if type == "session.start",
               let context = payload["context"] as? [String: Any],
               let sessionCwd = context["cwd"] as? String, sessionCwd == cwd {
                return true
            }

            if type == "hook.start",
               let input = payload["input"] as? [String: Any],
               let sessionCwd = input["cwd"] as? String, sessionCwd == cwd {
                return true
            }
        }
        return false
    }

    private static func readRecentFromCopilotTranscript(path: String) -> (String?, [ChatMessage]) {
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
                  let type = json["type"] as? String,
                  let payload = json["data"] as? [String: Any]
            else { continue }

            if model == nil {
                if let currentModel = payload["currentModel"] as? String, !currentModel.isEmpty {
                    model = currentModel
                } else if let eventModel = payload["model"] as? String, !eventModel.isEmpty {
                    model = eventModel
                } else if let metrics = payload["modelMetrics"] as? [String: Any],
                          let metricModel = metrics.keys.sorted().last, !metricModel.isEmpty {
                    model = metricModel
                }
            }

            if type == "user.message",
               let textContent = payload["content"] as? String, !textContent.isEmpty {
                userMessages.append((index, textContent))
            } else if type == "assistant.message",
                      let textContent = payload["content"] as? String, !textContent.isEmpty {
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
}
