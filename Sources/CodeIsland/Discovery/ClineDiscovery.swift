import Foundation
import CodeIslandCore

/// Cline sessions (VS Code extension `saoudrizwan.claude-dev`): the task
/// history kept in the extension's storage.
enum ClineDiscovery {
    static func clineStorageRoot() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? ""
        return "\(appSupport)/Code/User/globalStorage/saoudrizwan.claude-dev"
    }

    static func findActiveClineSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let clineRoot = clineStorageRoot()
        let fm = FileManager.default
        let historyPath = "\(clineRoot)/state/taskHistory.json"
        guard fm.fileExists(atPath: historyPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: historyPath)),
              let history = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !history.isEmpty
        else { return [] }

        // Sort by ts descending, take the most recent task
        let sorted = history.sorted {
            ($0["ts"] as? Double ?? 0) > ($1["ts"] as? Double ?? 0)
        }
        guard let latest = sorted.first,
              let taskId = latest["id"] as? String
        else { return [] }

        // Use the conversation file's mtime for freshness — more accurate than taskHistory ts.
        let conversationPath = "\(clineRoot)/tasks/\(taskId)/api_conversation_history.json"
        let fileDate: Date
        if let attrs = try? fm.attributesOfItem(atPath: conversationPath),
           let mtime = attrs[.modificationDate] as? Date {
            fileDate = mtime
        } else if let taskTs = latest["ts"] as? Double {
            fileDate = Date(timeIntervalSince1970: taskTs / 1000.0)
        } else {
            return []
        }

        // Cline has no process monitor — allow 10 min staleness
        let freshnessLimit: TimeInterval = -600
        guard fileDate.timeIntervalSinceNow > freshnessLimit else { return [] }

        let (model, messages) = readRecentFromClineHistory(
            path: conversationPath,
            modelFromHistory: latest["modelId"] as? String
        )

        let cwd = latest["cwdOnTaskInitialization"] as? String ?? ""
        // No PID for Cline — it's a VSCode extension, not a CLI process
        let pid: pid_t? = nil

        return [DiscoveredSession(
            sessionId: taskId,
            cwd: cwd,
            tty: nil,
            model: model,
            pid: pid,
            modifiedAt: fileDate,
            recentMessages: messages,
            source: "cline"
        )]
    }

    private static func readRecentFromClineHistory(
        path: String,
        modelFromHistory: String?
    ) -> (String?, [ChatMessage]) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return (modelFromHistory, []) }

        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for entry in entries {
            guard let role = entry["role"] as? String,
                  let textContent = SessionDiscovery.extractTextContent(from: entry["content"])
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
        return (modelFromHistory, Array(combined.suffix(3).map { $0.1 }))
    }
}
