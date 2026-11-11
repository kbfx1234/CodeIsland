import AppKit
import CodeIslandCore
import Foundation
import Network
import os.log

/// The ssh tunnel behind one remote host: `SSHForwarder`, or a stand-in in tests.
@MainActor
protocol RemoteTunnel: AnyObject {
    var onStatusChange: ((SSHForwarder.Status) -> Void)? { get set }
    func connect(host: RemoteHost, localSocketPath: String, remoteSocketPath: String)
    func disconnect()
}

extension SSHForwarder: RemoteTunnel {}

@MainActor
final class RemoteManager: ObservableObject {
    static let shared = RemoteManager()
    private static let log = Logger(subsystem: "com.codeisland", category: "RemoteManager")

    @Published private(set) var hosts: [RemoteHost] = []
    @Published private(set) var connectionStatus: [String: SSHForwarder.Status] = [:]
    @Published private(set) var installRunning: [String: Bool] = [:]
    @Published private(set) var lastMessage: [String: String] = [:]

    var onDisconnect: ((String) -> Void)?

    /// Where each host's hooks arrive on this Mac: a socket of the host's
    /// own, bound before its tunnel starts (``RemoteHookSockets``). The app
    /// sets it before ``startup()``; without it no host connects, for a
    /// forward may end only at a socket the island bound for its host.
    var hookSockets: (any RemoteHookSocketProviding)?

    private var forwarders: [String: any RemoteTunnel] = [:]
    // Per-user remote socket path resolved at connect time (#193). Keyed by host id;
    // reused by installHooks so the SSH -R forward and the remote hooks agree.
    private var remoteSocketPaths: [String: String] = [:]
    private let defaults: UserDefaults
    private let hostsKey = "remoteHosts"

    // Auto-reconnect (#92): when an ssh tunnel drops without the user asking for
    // it (laptop sleep / network blip / server bounce), retry with backoff
    // instead of leaving the host silently disconnected. Waking up and the
    // network coming back restart hosts that are still down (#375). Published
    // so Settings can tell a failed host that is still trying.
    @Published private var reconnectPolicy: RemoteReconnectPolicy
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var recoveryTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    // One token per connect. The remote socket-path probe runs before ssh
    // starts; a Disconnect or a newer connect in the meantime retires it.
    private var connectTokens: [String: UInt64] = [:]
    private var lastConnectToken: UInt64 = 0

    private let now: () -> Date
    private let makeTunnel: @MainActor () -> any RemoteTunnel
    private let probeSocketPath: (RemoteHost) async -> Result<String, RemoteSocketCheckFailure>
    private let installRemoteHooks: (RemoteHost, String) async -> RemoteInstallResult

    /// Everything after `reconnectPolicy` reaches ssh, the clock or the
    /// hosts' sockets; tests pass stand-ins.
    init(
        defaults: UserDefaults = .standard,
        reconnectPolicy: RemoteReconnectPolicy = RemoteReconnectPolicy(),
        hookSockets: (any RemoteHookSocketProviding)? = nil,
        now: @escaping () -> Date = Date.init,
        makeTunnel: @escaping @MainActor () -> any RemoteTunnel = { SSHForwarder() },
        probeSocketPath: @escaping (RemoteHost) async -> Result<String, RemoteSocketCheckFailure> = {
            await RemoteInstaller.prepareRemoteSocketPath(host: $0)
        },
        installRemoteHooks: @escaping (RemoteHost, String) async -> RemoteInstallResult = {
            await RemoteInstaller.installAll(host: $0, remoteSocketPath: $1)
        }
    ) {
        self.defaults = defaults
        self.reconnectPolicy = reconnectPolicy
        self.hookSockets = hookSockets
        self.now = now
        self.makeTunnel = makeTunnel
        self.probeSocketPath = probeSocketPath
        self.installRemoteHooks = installRemoteHooks
        load()
    }

    func startup() {
        // Before any host binds one: sockets a crash left behind.
        hookSockets?.removeStale()
        startRecoveryTriggers()
        for host in hosts where host.autoConnect {
            connect(id: host.id)
        }
    }

    func shutdown() {
        for host in hosts {
            disconnect(id: host.id)
        }
        hookSockets?.closeAll()
    }

    func addHost(_ host: RemoteHost) {
        hosts.append(host)
        save()
    }

    func updateHost(_ host: RemoteHost) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        let previous = hosts[index]
        let wasConnected = (connectionStatus[host.id] == .connected)
        hosts[index] = host
        save()
        // The host's socket stamps its requests with its name.
        if previous.name != host.name {
            hookSockets?.rename(hostId: host.id, to: host.name)
        }
        // Only bounce the tunnel when a field the SSH connection depends on
        // changed. Local-only fields (name, cwdFilter — filtering happens in
        // HookServer, #240) must not interrupt live sessions. Who may use the
        // socket on the host is set by the tunnel and the hooks installed
        // after it connects.
        let connectionChanged = previous.host != host.host
            || previous.user != host.user
            || previous.port != host.port
            || previous.identityFile != host.identityFile
            || previous.authSocket != host.authSocket
            || previous.agentsRunAsOtherUsers != host.agentsRunAsOtherUsers
        if wasConnected && connectionChanged {
            reconnect(id: host.id)
        }
    }

    func removeHost(id: String) {
        disconnect(id: id)
        reconnectPolicy.forget(id)
        hosts.removeAll { $0.id == id }
        connectionStatus[id] = .disconnected
        installRunning[id] = false
        lastMessage[id] = nil
        save()
    }

    func reconnect(id: String) {
        disconnect(id: id)
        connect(id: id)
    }

    func connect(id: String) {
        // User-initiated connect (or autoConnect at startup): the host is wanted
        // from now on. Drops any pending retry and starts with a fresh backoff.
        apply(reconnectPolicy.userConnected(id), to: id)
    }

    /// Whether the user still wants this host connected. A failed host then
    /// keeps coming back on its own (retries, wake, network) until Disconnect.
    func wantsConnection(id: String) -> Bool {
        reconnectPolicy.wantsConnection(id)
    }

    /// Where the host stands in the reconnect cycle.
    func reconnectPhase(id: String) -> RemoteReconnectPolicy.Phase {
        reconnectPolicy.phase(of: id)
    }

    private func connectInternal(id: String) {
        guard let host = hosts.first(where: { $0.id == id }) else {
            reconnectPolicy.forget(id)
            return
        }
        // A host without an id would get a socket that names no host: its
        // hooks' requests would pass for this Mac's.
        guard !HookOrigin.isBlankHostId(host.id) else {
            reconnectPolicy.connectAborted(id)
            let message = L10n.shared["remote_host_id_blank"]
            connectionStatus[id] = .failed(message)
            lastMessage[id] = message
            return
        }
        guard !host.sshTarget.isEmpty else {
            reconnectPolicy.connectAborted(id)
            connectionStatus[id] = .failed("invalid host")
            lastMessage[id] = "invalid host"
            return
        }
        // A field ssh would read as an option of its own never reaches it.
        if let field = host.unsafeSSHField {
            reconnectPolicy.connectAborted(id)
            let message = String(format: L10n.shared["remote_ssh_field_unsafe"], field)
            connectionStatus[id] = .failed(message)
            lastMessage[id] = message
            return
        }

        // The host's hooks arrive on a socket bound for it now, which names
        // the host to everything they reach (HookOrigin); its tunnel ends
        // there and nowhere else. Without one, nothing is forwarded.
        let opened = hookSockets?.open(for: host)
            ?? .failure(.cannotListen(path: RemoteHookSockets.defaultFolders().directory))
        let localSocketPath: String
        switch opened {
        case .success(let path):
            localSocketPath = path
        case .failure(let failure):
            failWithoutSocket(host, failure)
            return
        }

        let forwarder = forwarders[id] ?? makeTunnel()
        forwarders[id] = forwarder
        forwarder.onStatusChange = { [weak self, weak forwarder] status in
            Task { @MainActor in
                // Late news from a tunnel that Disconnect already dropped (its
                // own .disconnected included) must not overwrite what replaced it.
                guard let self, let forwarder, self.forwarders[host.id] === forwarder else { return }
                self.handleStatusChange(status, for: host)
            }
        }

        lastConnectToken &+= 1
        let token = lastConnectToken
        connectTokens[id] = token
        connectionStatus[id] = .connecting
        lastMessage[id] = host.displayAddress

        Task {
            // The folder the island's socket goes in on the host, made and
            // checked before anything is forwarded there.
            let prepared = await probeSocketPath(host)
            await MainActor.run {
                // The probe takes seconds. A Disconnect meanwhile must not be
                // followed by a tunnel nothing can stop any more, and of two
                // overlapping connects only the newer one starts ssh.
                // Still this connect's, so the socket it bound is still the
                // host's: a Disconnect closes it, a newer connect binds anew.
                guard self.connectTokens[id] == token, self.forwarders[id] === forwarder else { return }
                switch prepared {
                case .success(let remoteSocketPath):
                    self.remoteSocketPaths[host.id] = remoteSocketPath
                    forwarder.connect(host: host, localSocketPath: localSocketPath, remoteSocketPath: remoteSocketPath)
                case .failure(let failure):
                    self.failRemoteSocket(host, failure)
                }
            }
        }
    }

    /// The island's socket on the host is not one only the SSH user can
    /// reach, or could not be checked: nothing is forwarded there, and a
    /// tunnel already up is stopped. The host fails with the reason and is
    /// retried as a tunnel that failed is.
    private func failRemoteSocket(_ host: RemoteHost, _ failure: RemoteSocketCheckFailure) {
        Self.log.error("remote \(host.id, privacy: .public) socket on the host: \(String(describing: failure), privacy: .public)")
        connectTokens[host.id] = nil
        forwarders[host.id]?.disconnect()
        forwarders[host.id] = nil
        hookSockets?.close(hostId: host.id)
        remoteSocketPaths[host.id] = nil
        handleStatusChange(.failed(failure.message(L10n.shared)), for: host)
    }

    /// The host could not have a socket of its own: it does not connect,
    /// and says why. A tunnel it still had is stopped — it led to a socket
    /// that is gone. Tried again on a wake, the network coming back, or
    /// Connect.
    private func failWithoutSocket(_ host: RemoteHost, _ failure: RemoteHookSocketFailure) {
        let message = failure.message(L10n.shared)
        Self.log.error("remote \(host.id, privacy: .public) has no socket: \(String(describing: failure), privacy: .public)")
        reconnectPolicy.connectAborted(host.id)
        connectTokens[host.id] = nil
        forwarders[host.id]?.disconnect()
        forwarders[host.id] = nil
        connectionStatus[host.id] = .failed(message)
        lastMessage[host.id] = message
        installRunning[host.id] = false
        onDisconnect?(host.id)
    }

    func disconnect(id: String) {
        cancelScheduledReconnect(id: id)
        // An explicit Disconnect: no retry, wake or network change brings the
        // host back until the user connects again.
        reconnectPolicy.userDisconnected(id)
        connectTokens[id] = nil
        forwarders[id]?.disconnect()
        forwarders[id] = nil
        hookSockets?.close(hostId: id)
        remoteSocketPaths[id] = nil
        connectionStatus[id] = .disconnected
        installRunning[id] = false
        onDisconnect?(id)
    }

    private func handleStatusChange(_ status: SSHForwarder.Status, for host: RemoteHost) {
        connectionStatus[host.id] = status

        switch status {
        case .connected:
            reconnectPolicy.tunnelConnected(host.id, now: now())
            cancelScheduledReconnect(id: host.id)
            Task { await installHooks(for: host) }
        case .failed(let message):
            installRunning[host.id] = false
            lastMessage[host.id] = message
            onDisconnect?(host.id)
            // Only Auto-connect hosts retry on a timer, so a typo in a manual
            // host isn't retried over and over (#92).
            let autoRetry = hosts.first(where: { $0.id == host.id })?.autoConnect ?? false
            let step = reconnectPolicy.tunnelFailed(host.id, autoRetry: autoRetry, now: now())
            Self.log.notice("remote \(host.id, privacy: .public) failed (\(message)): \(String(describing: step), privacy: .public)")
            apply(step, to: host.id)
        case .disconnected:
            // User-initiated disconnects go through disconnect(id:), which
            // drops the tunnel before its report arrives; this is the tunnel
            // resetting itself at the start of a retry.
            installRunning[host.id] = false
            onDisconnect?(host.id)
        case .connecting:
            break
        }
    }

    // MARK: - Retries

    /// Carries out what the reconnect policy decided for one host.
    private func apply(_ step: RemoteReconnectPolicy.Step, to id: String) {
        let l10n = L10n.shared
        switch step {
        case .none:
            break
        case .connect:
            cancelScheduledReconnect(id: id)
            connectInternal(id: id)
        case .retry(let delay, let attempt):
            lastMessage[id] = String(format: l10n["remote_retry_in"], Int(delay), attempt, reconnectPolicy.config.fastAttempts)
            scheduleRetry(id: id, after: delay)
        case .retrySlowly(let delay, let failures):
            lastMessage[id] = String(format: l10n["remote_retry_slow"], failures, max(1, Int(delay / 60)))
            scheduleRetry(id: id, after: delay)
        case .waitForNetwork(let recheck):
            lastMessage[id] = l10n["remote_waiting_network"]
            scheduleRetry(id: id, after: recheck)
        }
    }

    private func scheduleRetry(id: String, after delay: TimeInterval) {
        cancelScheduledReconnect(id: id)
        reconnectTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            // Cancelled and checked on the main actor, so a timer that was
            // replaced or cancelled never gets past this line.
            guard !Task.isCancelled, let self else { return }
            self.reconnectTasks[id] = nil
            self.apply(self.reconnectPolicy.retryDue(id), to: id)
        }
    }

    private func cancelScheduledReconnect(id: String) {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
    }

    // MARK: - Wake and network recovery (#375)

    /// Watches for the Mac waking up and the network coming back. Idempotent.
    private func startRecoveryTriggers() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        // screensDidWake too: after a dark wake (Power Nap) the system is
        // already up when the lid opens, so the displays coming on may be the
        // only wake an app sees.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            })
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            MainActor.assumeIsolated { self?.networkPathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// The Mac (or its displays) woke up: every wanted host gets a fresh
    /// backoff, and those still down reconnect once the network has settled.
    func systemDidWake() {
        reconnectPolicy.systemWoke()
        Self.log.notice("wake: recovering remote hosts")
        scheduleRecovery(after: reconnectPolicy.config.wakeSettle)
    }

    /// A report from the network path monitor.
    func networkPathChanged(satisfied: Bool) {
        let previous = reconnectPolicy.networkSatisfied
        let cameBack = reconnectPolicy.networkChanged(satisfied: satisfied)
        if previous != satisfied {
            Self.log.notice("network \(satisfied ? "up" : "down", privacy: .public)")
        }
        if cameBack {
            scheduleRecovery(after: reconnectPolicy.config.networkSettle)
        }
    }

    /// One recovery pass after `delay`. Another wake or network event in the
    /// meantime restarts the wait, so a burst of them makes a single pass.
    private func scheduleRecovery(after delay: TimeInterval) {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.recoveryTask = nil
            for (id, step) in self.reconnectPolicy.recover() {
                Self.log.notice("remote \(id, privacy: .public) recovery: \(String(describing: step), privacy: .public)")
                self.apply(step, to: id)
            }
        }
    }

    private func installHooks(for host: RemoteHost) async {
        // Only where this connect prepared the folder for the socket.
        guard let remoteSocketPath = remoteSocketPaths[host.id] else { return }
        let token = connectTokens[host.id]
        let tunnel = forwarders[host.id]
        installRunning[host.id] = true
        let result = await installRemoteHooks(host, remoteSocketPath)
        installRunning[host.id] = false
        if let problem = result.socketProblem {
            // The tunnel leads to a socket nobody vouched for: it goes —
            // unless a Disconnect or another connect has replaced it since,
            // or it has failed on its own meanwhile (and is being retried).
            guard token != nil, connectTokens[host.id] == token,
                  let tunnel, forwarders[host.id] === tunnel,
                  connectionStatus[host.id] == .connected else { return }
            failRemoteSocket(host, problem)
            return
        }
        lastMessage[host.id] = result.message
        if !result.ok {
            connectionStatus[host.id] = .failed(result.message)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: hostsKey),
              let decoded = try? JSONDecoder().decode([RemoteHost].self, from: data) else {
            hosts = []
            return
        }
        hosts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        defaults.set(data, forKey: hostsKey)
    }
}
