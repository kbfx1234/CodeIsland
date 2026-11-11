import Foundation
import CodeIslandCore

/// Gemini CLI sessions: running processes matched to the chats under
/// `~/.gemini/tmp/<project>/chats`.
enum GeminiDiscovery {
    static func readModelFromGeminiStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let tmpBase = "\(home)/.gemini/tmp"
        guard let projectDir = findGeminiProjectDirectory(
            for: cwd,
            tmpBase: tmpBase,
            projects: readGeminiProjectsMap(path: "\(home)/.gemini/projects.json"),
            fm: fm
        ) else {
            return nil
        }
        let chatsBase = "\(tmpBase)/\(projectDir)/chats"
        guard let best = findMostRecentGeminiSession(in: chatsBase, after: processStart, fm: fm) else {
            return nil
        }
        return readRecentFromGeminiTranscript(path: best.path).1
    }

    static func findActiveGeminiSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let geminiPids = AgentProcessFinder.findGeminiPids(candidatePids: candidatePids)
        guard !geminiPids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let tmpBase = "\(home)/.gemini/tmp"
        guard fm.fileExists(atPath: tmpBase) else { return [] }

        let projects = readGeminiProjectsMap(path: "\(home)/.gemini/projects.json")
        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in geminiPids {
            guard let cwd = ProcessTable.getCwd(for: pid), !cwd.isEmpty, !SessionDiscovery.isSubagentWorktree(cwd) else { continue }
            guard let projectDir = findGeminiProjectDirectory(for: cwd, tmpBase: tmpBase, projects: projects, fm: fm) else {
                continue
            }

            let processStart = ProcessTable.getProcessStartTime(pid)
            let chatsBase = "\(tmpBase)/\(projectDir)/chats"
            guard let best = findMostRecentGeminiSession(in: chatsBase, after: processStart, fm: fm) else { continue }
            let geminiFreshnessLimit: TimeInterval = processStart != nil ? -300 : -30
            if best.modified.timeIntervalSinceNow < geminiFreshnessLimit { continue }

            let (sessionId, model, messages) = readRecentFromGeminiTranscript(path: best.path)
            guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: best.modified,
                recentMessages: messages,
                source: "gemini"
            ))
        }

        return results
    }

    private static func readGeminiProjectsMap(path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: String] else {
            return [:]
        }
        return projects
    }

    private static func findGeminiProjectDirectory(
        for cwd: String,
        tmpBase: String,
        projects: [String: String],
        fm: FileManager
    ) -> String? {
        if let mapped = projects[cwd], fm.fileExists(atPath: "\(tmpBase)/\(mapped)") {
            return mapped
        }

        guard let dirs = try? fm.contentsOfDirectory(atPath: tmpBase) else { return nil }
        for dir in dirs {
            let projectRootPath = "\(tmpBase)/\(dir)/.project_root"
            guard let data = fm.contents(atPath: projectRootPath),
                  let root = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  root == cwd else { continue }
            return dir
        }
        return nil
    }

    private static func findMostRecentGeminiSession(
        in directory: String,
        after processStart: Date?,
        fm: FileManager
    ) -> (path: String, modified: Date)? {
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return nil }

        var bestPath: String?
        var bestDate = Date.distantPast
        for file in files where file.hasPrefix("session-") && file.hasSuffix(".json") {
            let fullPath = "\(directory)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date,
                  modified > bestDate else { continue }
            if let start = processStart, modified < start.addingTimeInterval(-10) {
                continue
            }
            bestPath = fullPath
            bestDate = modified
        }

        guard let bestPath else { return nil }
        return (bestPath, bestDate)
    }

    private static func readRecentFromGeminiTranscript(path: String) -> (String, String?, [ChatMessage]) {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (((path as NSString).lastPathComponent as NSString).deletingPathExtension, nil, [])
        }

        let sessionId = (json["sessionId"] as? String)
            ?? (((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        let model = json["model"] as? String
        let messages = (json["messages"] as? [[String: Any]]) ?? []

        var combined: [(Int, ChatMessage)] = []
        for (index, message) in messages.enumerated() {
            let type = (message["type"] as? String)?.lowercased() ?? ""
            let text = SessionDiscovery.extractTextContent(from: message["content"])
                ?? (message["content"] as? String)
            guard let text, !text.isEmpty else { continue }

            if type == "user" {
                combined.append((index, ChatMessage(isUser: true, text: text)))
            } else {
                combined.append((index, ChatMessage(isUser: false, text: text)))
            }
        }

        combined.sort { $0.0 < $1.0 }
        return (sessionId, model, Array(combined.suffix(3).map { $0.1 }))
    }
}
