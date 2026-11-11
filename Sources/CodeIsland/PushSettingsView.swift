import SwiftUI
import CodeIslandCore

/// Settings → Behavior → Push Notifications, right under the generic
/// webhook. One collapsible block per service; channels live in a single
/// JSON setting so adding a service never needs a new settings key.
struct PushNotificationsSection: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.pushEnabled) private var pushEnabled = SettingsDefaults.pushEnabled
    @AppStorage(SettingsKey.pushOnlyWhenAway) private var onlyWhenAway = SettingsDefaults.pushOnlyWhenAway
    @AppStorage(SettingsKey.pushAwayIdleMinutes) private var idleMinutes = SettingsDefaults.pushAwayIdleMinutes
    @AppStorage(SettingsKey.pushSummaryLength) private var summaryLength = SettingsDefaults.pushSummaryLength
    @AppStorage(SettingsKey.pushChannels) private var channelsJSON = SettingsDefaults.pushChannels

    private static let idleChoices = [1, 2, 5, 10, 15, 30]
    private static let summaryChoices = [100, 200, 500, 1000]

    var body: some View {
        Section(l10n["push_title"]) {
            Text(l10n["push_desc"])
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(l10n["push_enable"], isOn: $pushEnabled)
            if pushEnabled {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(l10n["push_only_when_away"], isOn: $onlyWhenAway)
                    Text(l10n["push_only_when_away_desc"])
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Picker(l10n["push_idle_minutes"], selection: $idleMinutes) {
                    ForEach(Self.idleChoices, id: \.self) { minutes in
                        Text(String(format: l10n["push_minutes_format"], minutes)).tag(minutes)
                    }
                }
                .disabled(!onlyWhenAway)
                Picker(l10n["push_summary_length"], selection: $summaryLength) {
                    ForEach(Self.summaryChoices, id: \.self) { count in
                        Text(String(format: l10n["push_chars_format"], count)).tag(count)
                    }
                }
                ForEach(PushChannelKind.allCases) { kind in
                    PushChannelEditor(config: binding(for: kind))
                }
                Text(l10n["push_storage_note"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func binding(for kind: PushChannelKind) -> Binding<PushChannelConfig> {
        Binding(
            get: {
                PushChannelConfig.decodeList(channelsJSON).first { $0.kind == kind } ?? PushChannelConfig(kind: kind)
            },
            set: { updated in
                var list = PushChannelConfig.decodeList(channelsJSON)
                if let index = list.firstIndex(where: { $0.kind == kind }) {
                    list[index] = updated
                }
                channelsJSON = PushChannelConfig.encodeList(list)
            }
        )
    }
}

/// One text setting of a channel, in display order.
struct PushFieldSpec: Equatable {
    enum Prompt: Equatable {
        case none
        case literal(String)
        case optional

        func text(_ l10n: L10n) -> String? {
            switch self {
            case .none: return nil
            case .literal(let text): return text
            case .optional: return l10n["push_optional"]
            }
        }
    }

    /// L10n key of the label.
    let key: String
    let value: WritableKeyPath<PushChannelConfig, String>
    var prompt: Prompt = .none
    /// A credential, or a value that works as one: the device key, the ntfy
    /// topic (anyone who knows it can read and post), a webhook URL (its
    /// query or path is the token), tokens and secrets. Shown as dots until
    /// the eye is clicked, so a shared screen or a screenshot doesn't hand
    /// them out.
    var masked = false

    static func fields(for kind: PushChannelKind) -> [PushFieldSpec] {
        switch kind {
        case .bark:
            return [
                PushFieldSpec(key: "push_field_server", value: \.endpoint, prompt: .literal(kind.defaultEndpoint)),
                PushFieldSpec(key: "push_field_device_key", value: \.target, masked: true),
                PushFieldSpec(key: "push_field_group", value: \.group, prompt: .literal("CodeIsland")),
                PushFieldSpec(key: "push_field_icon", value: \.icon, prompt: .optional),
                PushFieldSpec(key: "push_field_sound", value: \.sound, prompt: .optional),
            ]
        case .ntfy:
            return [
                PushFieldSpec(key: "push_field_server", value: \.endpoint, prompt: .literal(kind.defaultEndpoint)),
                PushFieldSpec(key: "push_field_topic", value: \.target, masked: true),
                PushFieldSpec(key: "push_field_token", value: \.token, prompt: .optional, masked: true),
            ]
        case .dingtalk, .feishu:
            return [
                PushFieldSpec(key: "push_field_webhook", value: \.endpoint, masked: true),
                PushFieldSpec(key: "push_field_secret", value: \.secret, prompt: .optional, masked: true),
            ]
        case .wecom, .slack:
            return [PushFieldSpec(key: "push_field_webhook", value: \.endpoint, masked: true)]
        case .telegram:
            return [
                PushFieldSpec(key: "push_field_bot_token", value: \.token, masked: true),
                PushFieldSpec(key: "push_field_chat_id", value: \.target),
                PushFieldSpec(key: "push_field_api_base", value: \.endpoint, prompt: .literal(kind.defaultEndpoint)),
            ]
        }
    }
}

/// A credential field: dots by default, plain text while the eye is on.
/// Reverts to dots whenever the settings page is rebuilt.
private struct MaskedPushField: View {
    @ObservedObject private var l10n = L10n.shared
    let title: String
    @Binding var text: String
    let prompt: String?
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if revealed {
                    TextField(title, text: $text, prompt: prompt.map { Text($0) })
                        .autocorrectionDisabled(true)
                } else {
                    SecureField(title, text: $text, prompt: prompt.map { Text($0) })
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(l10n[revealed ? "push_hide_value" : "push_show_value"])
            .accessibilityLabel(l10n[revealed ? "push_hide_value" : "push_show_value"])
        }
    }
}

private struct PushChannelEditor: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var notifier = PushNotifier.shared
    @Binding var config: PushChannelConfig

    @State private var expanded = false
    @State private var testing = false
    @State private var testResult: PushDeliveryResult?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                fields
                Text(l10n["push_hint_\(config.kind.rawValue)"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                eventToggles
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(l10n["push_include_details"], isOn: $config.includeDetails)
                        .font(.system(size: 12))
                    Text(l10n["push_include_details_desc"])
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                testRow
                status
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Toggle(isOn: $config.enabled) {
                    Text(l10n["push_channel_\(config.kind.rawValue)"])
                }
                Spacer()
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 7, height: 7)
                    .help(indicatorHelp)
            }
        }
        .onChange(of: config) { _, _ in testResult = nil }
    }

    // MARK: Fields

    @ViewBuilder
    private var fields: some View {
        ForEach(PushFieldSpec.fields(for: config.kind), id: \.key) { spec in
            let text = $config[dynamicMember: spec.value]
            let prompt = spec.prompt.text(l10n)
            if spec.masked {
                MaskedPushField(title: l10n[spec.key], text: text, prompt: prompt)
            } else {
                TextField(l10n[spec.key], text: text, prompt: prompt.map { Text($0) })
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled(true)
            }
        }
        if config.kind == .ntfy {
            Picker(l10n["push_field_priority"], selection: $config.priority) {
                Text("3 · default").tag(3)
                Text("4 · high").tag(4)
                Text("5 · urgent").tag(5)
            }
        }
    }

    /// One row when it fits, a column in a narrow settings window.
    private var eventToggles: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                eventsLabel
                eventCheckboxes
            }
            VStack(alignment: .leading, spacing: 4) {
                eventsLabel
                eventCheckboxes
            }
        }
    }

    private var eventsLabel: some View {
        Text(l10n["push_events"])
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var eventCheckboxes: some View {
        ForEach(PushEventKind.configurable, id: \.self) { kind in
            Toggle(l10n["push_event_\(kind.rawValue)"], isOn: eventBinding(kind))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help(kind == .reminder ? l10n["push_event_reminder_help"] : "")
        }
    }

    private func eventBinding(_ kind: PushEventKind) -> Binding<Bool> {
        Binding(
            get: { config.events.contains(kind) },
            set: { isOn in
                if isOn { config.events.insert(kind) } else { config.events.remove(kind) }
            }
        )
    }

    // MARK: Test + status

    private var testRow: some View {
        HStack(spacing: 8) {
            Button(l10n["push_send_test"]) {
                testing = true
                testResult = nil
                let snapshot = config
                Task {
                    let result = await notifier.sendTest(snapshot)
                    testResult = result
                    testing = false
                }
            }
            .disabled(testing || config.problem != nil)
            if testing {
                ProgressView().controlSize(.small)
                Text(l10n["push_sending"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let problem = config.problem {
            Text(l10n["push_problem_\(problem.rawValue)"])
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let testResult {
            resultLine(testResult, prefix: testResult.ok ? l10n["push_test_ok"] : l10n["push_test_failed"])
        } else if let record = notifier.lastDelivery[config.kind] {
            resultLine(
                record.result,
                prefix: String(format: l10n["push_last_delivery"], record.date.formatted(date: .omitted, time: .shortened))
            )
        }
    }

    private func resultLine(_ result: PushDeliveryResult, prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text("\(prefix) · \(result.summary)")
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
            }
            .font(.caption)
            .foregroundStyle(result.ok ? Color.green : Color.red)
            if let redirected = result.redirectedTo {
                Text(String(format: l10n["push_redirected"], redirected))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if let refused = result.redirectRefusedTo {
                Text(String(format: l10n["push_redirect_refused"], refused))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var indicatorColor: Color {
        guard config.enabled else { return .secondary.opacity(0.4) }
        if config.problem != nil { return .orange }
        if let record = notifier.lastDelivery[config.kind], !record.result.ok { return .red }
        return .green
    }

    private var indicatorHelp: String {
        guard config.enabled else { return "" }
        if let problem = config.problem { return l10n["push_problem_\(problem.rawValue)"] }
        return notifier.lastDelivery[config.kind]?.result.summary ?? ""
    }
}
