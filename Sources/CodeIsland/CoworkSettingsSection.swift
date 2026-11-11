import SwiftUI
import AppKit

/// Hooks-page section for Claude Desktop's Cowork / local Chat sessions. They
/// have no hook to install — the toggle only starts or stops the read-only
/// session-store watcher (AppState+CoworkWatch).
struct ClaudeDesktopCoworkSection: View {
    var appState: AppState?
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.trackClaudeDesktopCowork)
    private var trackCowork = SettingsDefaults.trackClaudeDesktopCowork

    var body: some View {
        Section("Claude Desktop") {
            HStack(spacing: 8) {
                if let icon = claudeDesktopIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(l10n["cowork_tracking_toggle"], isOn: $trackCowork)
                        .onChange(of: trackCowork) { _, enabled in
                            if enabled {
                                appState?.startCoworkWatcher()
                            } else {
                                appState?.stopCoworkWatcher()
                            }
                        }
                    Text(l10n["cowork_tracking_desc"])
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var claudeDesktopIcon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: AppState.claudeDesktopBundleId
        ) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
