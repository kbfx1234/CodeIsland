import Foundation

/// When a remote host's SSH tunnel is brought back without the user clicking
/// Connect (#92, #375). Pure: `RemoteManager` reports what happened — the
/// user connecting or disconnecting, a tunnel coming up or dropping, the Mac
/// waking, the network path changing — and carries out the `Step`s it gets
/// back. Nothing here touches ssh, timers or AppKit.
///
/// - Only hosts the user wants connected come back. Connect in Settings, or
///   Auto-connect on Launch at startup, sets that; Disconnect clears it, and
///   nothing in here sets it again.
/// - A tunnel that drops on an auto-connect host is retried with backoff.
///   When the fast schedule runs out it keeps trying, slowly, instead of
///   giving up for good.
/// - Waking up and the network coming back are when a dead tunnel is most
///   likely to work again, so every wanted host that is neither up nor
///   connecting starts over there and then, with a fresh backoff. That covers
///   a host that used up its retries with the lid closed (each dark wake fires
///   the overdue retry, and with no network it fails at once) and one whose
///   next retry is still minutes away. A host the user connected by hand comes
///   back too; only the backoff after a failure stays auto-connect-only, so a
///   typo in a manual host is not retried on a clock.
/// - Offline, a failure does not use up an attempt: the host waits for the
///   network, with a slow re-check in case that report never comes.
/// - A host that is connecting is left to finish, so a burst of wake and
///   network events costs at most one connect per host.
/// - A host still up at wake is left alone. ssh's keepalives (15 s × 2) drop
///   a dead tunnel within about 45 s, and the retry then starts at the first,
///   short step; bouncing every tunnel on wake would also cut the ones that
///   survived a short sleep, and with them their sessions.
public struct RemoteReconnectPolicy: Equatable, Sendable {
    public struct Config: Equatable, Sendable {
        /// Wait before the nth retry; the last step repeats.
        public var backoff: [TimeInterval] = [5, 15, 45, 120, 300]
        /// Retries on `backoff` before slowing down to `slowRetry`.
        public var fastAttempts = 10
        public var slowRetry: TimeInterval = 900
        /// Offline, try anyway this often, in case the network coming back is
        /// never reported.
        public var offlineRecheck: TimeInterval = 300
        /// A tunnel up at least this long worked, so its next drop starts the
        /// backoff over. ssh counts as up 0.35 s after it starts — before it
        /// has reached the host, let alone logged in (an unreachable host
        /// takes up to 75 s to time out) — so a quicker drop is one more
        /// failed attempt, not a fresh start.
        public var stableAfter: TimeInterval = 120
        /// After a wake, give Wi-Fi, DHCP and VPNs a moment before connecting.
        public var wakeSettle: TimeInterval = 3
        /// Likewise after the network comes back.
        public var networkSettle: TimeInterval = 2

        public init() {}

        /// Wait before the nth retry (1-based).
        public func delay(forAttempt attempt: Int) -> TimeInterval {
            guard attempt >= 1 else { return backoff[0] }
            return backoff[min(attempt - 1, backoff.count - 1)]
        }
    }

    public enum Phase: Equatable, Sendable {
        /// Nothing in flight, nothing planned.
        case idle
        /// A connect is in flight: probing the remote socket path, clearing a
        /// stale socket, or starting ssh.
        case connecting
        /// ssh has been running since `since`.
        case connected(since: Date)
        /// Failed; a retry timer is pending.
        case retryPending
        /// Failed while offline; waiting for the network.
        case waitingForNetwork
    }

    /// What the owner does next for one host.
    public enum Step: Equatable, Sendable {
        case none
        /// Connect now.
        case connect
        /// Retry after `delay`: attempt `attempt` of `Config.fastAttempts`.
        case retry(delay: TimeInterval, attempt: Int)
        /// The fast retries are used up (`failures` so far); next try after `delay`.
        case retrySlowly(delay: TimeInterval, failures: Int)
        /// Offline: connect when the network is back, or after `recheck`.
        case waitForNetwork(recheck: TimeInterval)
    }

    struct HostState: Equatable, Sendable {
        var wanted = false
        var phase: Phase = .idle
        var failures = 0
    }

    public var config: Config
    private(set) var hosts: [String: HostState] = [:]
    /// The last network path report; nil before the first. Unknown counts as
    /// online.
    public private(set) var networkSatisfied: Bool?

    public init(config: Config = Config()) {
        self.config = config
    }

    public func wantsConnection(_ id: String) -> Bool { hosts[id]?.wanted ?? false }
    public func phase(of id: String) -> Phase { hosts[id]?.phase ?? .idle }
    public func failures(of id: String) -> Int { hosts[id]?.failures ?? 0 }

    private var isOnline: Bool { networkSatisfied ?? true }

    // MARK: User

    /// Connect in Settings, or Auto-connect on Launch: wanted from now on,
    /// connecting right away with a fresh backoff.
    public mutating func userConnected(_ id: String) -> Step {
        hosts[id] = HostState(wanted: true, phase: .connecting)
        return .connect
    }

    /// Disconnect in Settings: stays down until the user connects again.
    public mutating func userDisconnected(_ id: String) {
        hosts[id] = HostState()
    }

    /// The host was removed.
    public mutating func forget(_ id: String) {
        hosts[id] = nil
    }

    // MARK: Tunnel

    /// A connect stopped before ssh started (the host has no address).
    public mutating func connectAborted(_ id: String) {
        hosts[id]?.phase = .idle
    }

    public mutating func tunnelConnected(_ id: String, now: Date) {
        hosts[id]?.phase = .connected(since: now)
    }

    /// The tunnel failed to come up, or dropped. Only `autoRetry` hosts
    /// (Auto-connect on Launch) retry on a timer.
    public mutating func tunnelFailed(_ id: String, autoRetry: Bool, now: Date) -> Step {
        guard var host = hosts[id], host.wanted else { return .none }
        defer { hosts[id] = host }
        if case .connected(let since) = host.phase, now.timeIntervalSince(since) >= config.stableAfter {
            host.failures = 0
        }
        guard autoRetry else {
            host.phase = .idle
            return .none
        }
        guard isOnline else {
            host.phase = .waitingForNetwork
            return .waitForNetwork(recheck: config.offlineRecheck)
        }
        host.failures += 1
        host.phase = .retryPending
        if host.failures <= config.fastAttempts {
            return .retry(delay: config.delay(forAttempt: host.failures), attempt: host.failures)
        }
        return .retrySlowly(delay: config.slowRetry, failures: host.failures)
    }

    /// A retry or re-check timer fired.
    public mutating func retryDue(_ id: String) -> Step {
        guard var host = hosts[id], host.wanted else { return .none }
        defer { hosts[id] = host }
        switch host.phase {
        case .retryPending where !isOnline:
            // Went offline while waiting: keep the attempt for when it's back.
            host.phase = .waitingForNetwork
            return .waitForNetwork(recheck: config.offlineRecheck)
        case .retryPending, .waitingForNetwork:
            // The offline re-check connects whatever the path says: it is
            // there for when that report is wrong.
            host.phase = .connecting
            return .connect
        case .idle, .connecting, .connected:
            return .none
        }
    }

    // MARK: Wake and network

    /// The Mac woke up: every wanted host starts from a fresh backoff. The
    /// owner runs `recover()` once the network has had `wakeSettle` to return.
    public mutating func systemWoke() {
        for (id, host) in hosts where host.wanted {
            hosts[id]?.failures = 0
        }
    }

    /// A network path report. True when the network has come back, so a
    /// `recover()` is due after `networkSettle`. The first report only says
    /// where things stand.
    public mutating func networkChanged(satisfied: Bool) -> Bool {
        let previous = networkSatisfied
        networkSatisfied = satisfied
        guard let previous else { return false }
        return satisfied && !previous
    }

    /// Brings back every wanted host that is neither up nor connecting, with
    /// a fresh backoff; offline, it waits for the network instead.
    public mutating func recover() -> [String: Step] {
        var steps: [String: Step] = [:]
        for (id, var host) in hosts where host.wanted {
            host.failures = 0
            switch host.phase {
            case .connecting, .connected:
                break
            case .idle, .retryPending, .waitingForNetwork:
                if isOnline {
                    host.phase = .connecting
                    steps[id] = .connect
                } else {
                    host.phase = .waitingForNetwork
                    steps[id] = .waitForNetwork(recheck: config.offlineRecheck)
                }
            }
            hosts[id] = host
        }
        return steps
    }
}
