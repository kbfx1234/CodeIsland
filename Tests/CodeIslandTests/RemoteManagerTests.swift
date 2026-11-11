import XCTest
import CodeIslandCore
@testable import CodeIsland

/// Drives a private `RemoteManager` with stand-ins for ssh and for the
/// hosts' sockets: no process is started, no host is contacted, no socket is
/// bound. The reconnect rules themselves are covered by
/// `RemoteReconnectPolicyTests`; these check the wiring — the host's own
/// socket bound before ssh starts and the only place its tunnel ends, the
/// socket-path probe awaited before ssh starts, the debounced recovery pass,
/// and late reports from a tunnel that was already replaced.
@MainActor
final class RemoteManagerTests: XCTestCase {
    private let suiteName = "RemoteManagerTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Stands in for `SSHForwarder`: counts connects and reports whatever the
    /// test tells it to.
    @MainActor
    private final class FakeTunnel: RemoteTunnel {
        var onStatusChange: ((SSHForwarder.Status) -> Void)?
        private(set) var connects = 0
        private(set) var disconnects = 0
        /// Where each connect forwarded the host's hooks to.
        private(set) var localSocketPaths: [String] = []

        func connect(host: RemoteHost, localSocketPath: String, remoteSocketPath: String) {
            connects += 1
            localSocketPaths.append(localSocketPath)
            onStatusChange?(.connecting)
        }

        func disconnect() {
            disconnects += 1
            onStatusChange?(.disconnected)
        }

        func report(_ status: SSHForwarder.Status) {
            onStatusChange?(status)
        }
    }

    @MainActor
    private final class Tunnels {
        private(set) var made: [FakeTunnel] = []
        var connects: Int { made.reduce(0) { $0 + $1.connects } }

        func make() -> any RemoteTunnel {
            let tunnel = FakeTunnel()
            made.append(tunnel)
            return tunnel
        }
    }

    /// The check of the folder for the island's socket on the host, which
    /// runs before ssh starts: it finds `outcome`. While `holding`, each
    /// probe waits for `release()`.
    @MainActor
    private final class ProbeGate {
        var holding = false
        var outcome: Result<String, RemoteSocketCheckFailure> = .success("/tmp/codeisland-501/island.sock")
        private(set) var started = 0
        private var held: [CheckedContinuation<Void, Never>] = []

        func probe() async -> Result<String, RemoteSocketCheckFailure> {
            started += 1
            if holding {
                await withCheckedContinuation { held.append($0) }
            }
            return outcome
        }

        func release() {
            let waiting = held
            held = []
            waiting.forEach { $0.resume() }
        }
    }

    /// Stands in for `RemoteHookSockets`: binds nothing, gives each open a
    /// path of its own, fails when told to, and keeps a log.
    @MainActor
    private final class FakeHookSockets: RemoteHookSocketProviding {
        var failure: RemoteHookSocketFailure?
        /// What happened, in order: "stale", "open host-id", "close host-id".
        private(set) var log: [String] = []
        /// The path each host has open now.
        private(set) var open: [String: String] = [:]
        private(set) var names: [String: String] = [:]
        private var binds = 0

        func open(for host: RemoteHost) -> Result<String, RemoteHookSocketFailure> {
            open[host.id] = nil
            log.append("open \(host.id)")
            if let failure { return .failure(failure) }
            binds += 1
            let path = "/tmp/ci-fake-hosts/\(host.id)-\(binds).sock"
            open[host.id] = path
            names[host.id] = host.name
            return .success(path)
        }

        func rename(hostId: String, to name: String) {
            names[hostId] = name
        }

        func close(hostId: String) {
            guard open.removeValue(forKey: hostId) != nil else { return }
            log.append("close \(hostId)")
        }

        func closeAll() {
            for hostId in open.keys.sorted() { close(hostId: hostId) }
        }

        func removeStale() {
            log.append("stale")
        }
    }

    /// The install that follows each connect: it checks the socket on the
    /// host first, and finds `socketProblem`. While `holding`, each install
    /// waits for `release()`.
    @MainActor
    private final class Installs {
        var socketProblem: RemoteSocketCheckFailure?
        var holding = false
        private(set) var paths: [String] = []
        private var held: [CheckedContinuation<Void, Never>] = []

        func install(_ host: RemoteHost, _ path: String) async -> RemoteInstallResult {
            paths.append(path)
            if holding {
                await withCheckedContinuation { held.append($0) }
            }
            if let socketProblem {
                return RemoteInstallResult(ok: false, message: "Socket not verified", socketProblem: socketProblem)
            }
            return RemoteInstallResult(ok: true, message: "installed")
        }

        func release() {
            let waiting = held
            held = []
            waiting.forEach { $0.resume() }
        }
    }

    private func makeManager(
        sockets: FakeHookSockets? = nil,
        installs: Installs? = nil,
        _ configure: (inout RemoteReconnectPolicy.Config) -> Void = { _ in }
    ) -> (RemoteManager, ProbeGate, Tunnels) {
        var config = RemoteReconnectPolicy.Config()
        config.wakeSettle = 0
        config.networkSettle = 0
        configure(&config)
        let gate = ProbeGate()
        let tunnels = Tunnels()
        let installs = installs ?? Installs()
        let manager = RemoteManager(
            defaults: defaults,
            reconnectPolicy: RemoteReconnectPolicy(config: config),
            hookSockets: sockets ?? FakeHookSockets(),
            makeTunnel: { tunnels.make() },
            probeSocketPath: { _ in await gate.probe() },
            installRemoteHooks: { await installs.install($0, $1) }
        )
        return (manager, gate, tunnels)
    }

    private func addHost(to manager: RemoteManager, autoConnect: Bool = true) -> RemoteHost {
        let host = RemoteHost(name: "devbox", host: "devbox.invalid", user: "me", autoConnect: autoConnect)
        manager.addHost(host)
        return host
    }

    /// Connects `host` and waits until its tunnel has started.
    private func connect(_ host: RemoteHost, on manager: RemoteManager, tunnels: Tunnels) async {
        let before = tunnels.connects
        manager.connect(id: host.id)
        await waitUntil("the tunnel never started") { tunnels.connects == before + 1 }
    }

    /// Lets queued main-actor work (status reports, a zero-delay recovery
    /// pass, a released probe) run, for asserting that something did not
    /// happen.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Probe re-entrancy

    /// Disconnect while the socket-path probe is still running: once the
    /// probe returns, ssh must not start — nothing could stop that tunnel.
    func testDisconnectDuringTheProbeNeverStartsSSH() async {
        let (manager, gate, tunnels) = makeManager()
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        gate.holding = true

        manager.connect(id: host.id)
        await waitUntil { gate.started == 1 }
        manager.disconnect(id: host.id)
        gate.release()
        await settle()

        XCTAssertEqual(tunnels.connects, 0)
        XCTAssertEqual(manager.connectionStatus[host.id], .disconnected)
        XCTAssertFalse(manager.wantsConnection(id: host.id))
    }

    /// Two connects overlapping across the probe: only the newer starts ssh.
    func testOnlyTheNewerOfTwoOverlappingConnectsStartsSSH() async {
        let (manager, gate, tunnels) = makeManager()
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        gate.holding = true

        manager.connect(id: host.id)
        manager.connect(id: host.id)
        await waitUntil { gate.started == 2 }
        gate.release()
        await waitUntil { tunnels.connects == 1 }
        await settle()

        XCTAssertEqual(tunnels.connects, 1)
        XCTAssertEqual(tunnels.made.count, 1)
    }

    // MARK: - Wake and network (#375)

    /// The lid case: the host is down with a retry pending when the wake, a
    /// network flap and the displays waking arrive together. That makes one
    /// connect, and more of the same while it is still probing make none.
    func testWakeAndNetworkBurstReconnectsOnce() async {
        let (manager, gate, tunnels) = makeManager()
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        manager.networkPathChanged(satisfied: true)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.failed("ssh exited (255)"))
        await waitUntil { manager.reconnectPhase(id: host.id) == .retryPending }

        gate.holding = true
        manager.systemDidWake()
        manager.networkPathChanged(satisfied: false)
        manager.networkPathChanged(satisfied: true)
        manager.systemDidWake()
        await waitUntil { gate.started == 2 }

        manager.systemDidWake()
        manager.networkPathChanged(satisfied: false)
        manager.networkPathChanged(satisfied: true)
        await settle()
        XCTAssertEqual(gate.started, 2, "a connect still probing is not started again")

        gate.release()
        await waitUntil { tunnels.connects == 2 }
        await settle()
        XCTAssertEqual(tunnels.connects, 2)
        XCTAssertEqual(tunnels.made.count, 1, "the host keeps its one tunnel")
    }

    /// Every fast retry failed while the lid was closed; waking brings the
    /// host back instead of leaving it on the slow schedule.
    func testWakeReconnectsAHostPastItsFastRetries() async {
        let (manager, _, tunnels) = makeManager { $0.fastAttempts = 0 }
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.failed("ssh exited (255)"))
        await waitUntil { manager.reconnectPhase(id: host.id) == .retryPending }
        XCTAssertEqual(
            manager.lastMessage[host.id],
            String(format: L10n.shared["remote_retry_slow"], 1, 15)
        )

        manager.systemDidWake()
        await waitUntil { tunnels.connects == 2 }
        tunnels.made[0].report(.connected)
        await waitUntil { manager.connectionStatus[host.id] == .connected }
    }

    /// Offline at wake: nothing is tried until the path is back.
    func testOfflineAtWakeConnectsWhenTheNetworkReturns() async {
        let (manager, gate, tunnels) = makeManager()
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        manager.networkPathChanged(satisfied: true)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.failed("ssh exited (255)"))
        await waitUntil { manager.reconnectPhase(id: host.id) == .retryPending }

        manager.networkPathChanged(satisfied: false)
        manager.systemDidWake()
        await waitUntil { manager.reconnectPhase(id: host.id) == .waitingForNetwork }
        XCTAssertEqual(manager.lastMessage[host.id], L10n.shared["remote_waiting_network"])
        XCTAssertEqual(gate.started, 1)

        manager.networkPathChanged(satisfied: true)
        await waitUntil { tunnels.connects == 2 }
        XCTAssertEqual(gate.started, 2)
    }

    /// Disconnect is the user's call: no wake or network event undoes it.
    func testUserDisconnectSurvivesWakeAndNetworkReturning() async {
        let (manager, gate, tunnels) = makeManager()
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        manager.networkPathChanged(satisfied: true)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.connected)
        await waitUntil { manager.connectionStatus[host.id] == .connected }

        manager.disconnect(id: host.id)
        manager.systemDidWake()
        manager.networkPathChanged(satisfied: false)
        manager.networkPathChanged(satisfied: true)
        await settle()

        XCTAssertEqual(gate.started, 1)
        XCTAssertEqual(tunnels.connects, 1)
        XCTAssertEqual(manager.connectionStatus[host.id], .disconnected)
        XCTAssertFalse(manager.wantsConnection(id: host.id))
    }

    /// A host connected by hand (Auto-connect off) is restored after a wake,
    /// though its failure alone schedules no retry.
    func testManualHostIsRestoredOnWake() async {
        let (manager, _, tunnels) = makeManager()
        defer { manager.shutdown() }
        let host = addHost(to: manager, autoConnect: false)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.failed("ssh exited (255)"))
        await waitUntil { manager.connectionStatus[host.id] == .failed("ssh exited (255)") }
        XCTAssertEqual(manager.reconnectPhase(id: host.id), .idle)
        XCTAssertTrue(manager.wantsConnection(id: host.id))

        manager.systemDidWake()
        await waitUntil { tunnels.connects == 2 }
    }

    // MARK: - The host's own socket

    /// The tunnel ends at the socket bound for the host on this connect —
    /// never at the main socket, which another user may have taken first.
    func testTheTunnelEndsAtTheSocketBoundForTheHost() async {
        let sockets = FakeHookSockets()
        let (manager, _, tunnels) = makeManager(sockets: sockets)
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        await connect(host, on: manager, tunnels: tunnels)

        let bound = sockets.open[host.id]
        XCTAssertNotNil(bound)
        XCTAssertEqual(tunnels.made[0].localSocketPaths, [bound!])
        XCTAssertNotEqual(bound, HookServer.socketPath)

        // A reconnect binds afresh and forwards there.
        manager.reconnect(id: host.id)
        await waitUntil { tunnels.connects == 2 }
        XCTAssertEqual(sockets.log, ["open \(host.id)", "close \(host.id)", "open \(host.id)"])
        XCTAssertEqual(tunnels.made.last?.localSocketPaths.last, sockets.open[host.id])
        XCTAssertNotEqual(sockets.open[host.id], bound)
    }

    /// No socket of its own, no tunnel: the host fails, says why, and is
    /// still wanted — a wake, the network or Connect tries again.
    func testAHostWithoutASocketDoesNotConnect() async {
        let sockets = FakeHookSockets()
        sockets.failure = .folderNotPrivate(path: "/tmp/codeisland-501-hosts")
        let (manager, gate, tunnels) = makeManager(sockets: sockets)
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        var dropped: [String] = []
        manager.onDisconnect = { dropped.append($0) }

        manager.connect(id: host.id)
        await settle()

        let message = RemoteHookSocketFailure.folderNotPrivate(path: "/tmp/codeisland-501-hosts").message(L10n.shared)
        XCTAssertEqual(gate.started, 0, "not even the probe runs")
        XCTAssertEqual(tunnels.connects, 0, "no ssh")
        XCTAssertEqual(manager.connectionStatus[host.id], .failed(message))
        XCTAssertEqual(manager.lastMessage[host.id], message)
        XCTAssertTrue(manager.wantsConnection(id: host.id))
        XCTAssertEqual(manager.reconnectPhase(id: host.id), .idle)
        XCTAssertEqual(dropped, [host.id], "its sessions go")

        sockets.failure = nil
        manager.systemDidWake()
        await waitUntil { tunnels.connects == 1 }
        XCTAssertEqual(tunnels.made[0].localSocketPaths, [sockets.open[host.id]!])
    }

    /// A tunnel still running when the host can no longer have a socket led
    /// to one that is gone: it is stopped, not left forwarding.
    func testAFailedSocketStopsTheTunnelThatLedThere() async {
        let sockets = FakeHookSockets()
        let (manager, _, tunnels) = makeManager(sockets: sockets)
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.failed("ssh exited (255)"))
        await waitUntil { manager.reconnectPhase(id: host.id) == .retryPending }

        sockets.failure = .cannotListen(path: "/tmp/x.sock")
        manager.systemDidWake()
        await waitUntil { manager.connectionStatus[host.id] == .failed(RemoteHookSocketFailure.cannotListen(path: "/tmp/x.sock").message(L10n.shared)) }
        XCTAssertEqual(tunnels.made[0].disconnects, 1)
        XCTAssertEqual(tunnels.connects, 1)
    }

    func testDisconnectRemoveAndQuitCloseTheHostsSocket() async {
        let sockets = FakeHookSockets()
        let (manager, _, tunnels) = makeManager(sockets: sockets)
        let first = addHost(to: manager)
        let second = addHost(to: manager)
        let third = addHost(to: manager)
        await connect(first, on: manager, tunnels: tunnels)
        await connect(second, on: manager, tunnels: tunnels)
        await connect(third, on: manager, tunnels: tunnels)

        manager.disconnect(id: first.id)
        XCTAssertNil(sockets.open[first.id])
        manager.removeHost(id: second.id)
        XCTAssertNil(sockets.open[second.id])
        manager.shutdown()
        XCTAssertTrue(sockets.open.isEmpty)
        XCTAssertEqual(sockets.log.filter { $0.hasPrefix("close") }.count, 3)
    }

    func testStartupClearsStaleSocketsBeforeAnyHostBinds() async {
        let sockets = FakeHookSockets()
        let (manager, _, tunnels) = makeManager(sockets: sockets)
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        manager.startup()
        await waitUntil { tunnels.connects == 1 }
        XCTAssertEqual(sockets.log.prefix(2), ["stale", "open \(host.id)"])
    }

    /// The name travels with every request on the host's socket; renaming
    /// needs no new tunnel.
    func testRenamingAHostRenamesItsSocket() async {
        let sockets = FakeHookSockets()
        let (manager, _, tunnels) = makeManager(sockets: sockets)
        defer { manager.shutdown() }
        var host = addHost(to: manager)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.connected)
        await waitUntil { manager.connectionStatus[host.id] == .connected }

        host.name = "Build Box"
        manager.updateHost(host)
        XCTAssertEqual(sockets.names[host.id], "Build Box")
        await settle()
        XCTAssertEqual(tunnels.connects, 1, "a new name keeps the tunnel")
    }

    /// Who may use the socket on the host is the tunnel's and the installed
    /// hooks' to set: a connected host reconnects to apply it.
    func testLettingOtherUsersInReconnectsTheHost() async {
        let (manager, _, tunnels) = makeManager()
        defer { manager.shutdown() }
        var host = addHost(to: manager)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.connected)
        await waitUntil { manager.connectionStatus[host.id] == .connected }

        host.agentsRunAsOtherUsers = true
        manager.updateHost(host)
        await waitUntil { tunnels.connects == 2 }
    }

    /// A host saved without an id (an old or hand-edited setting) does not
    /// connect: a socket for it would name no host, and its hooks' requests
    /// would pass for this Mac's.
    func testAHostWithoutAnIdDoesNotConnect() async {
        let sockets = FakeHookSockets()
        let (manager, gate, tunnels) = makeManager(sockets: sockets)
        defer { manager.shutdown() }
        let host = RemoteHost(id: "  ", name: "devbox", host: "devbox.invalid", user: "me", autoConnect: true)
        manager.addHost(host)

        manager.connect(id: host.id)
        await settle()

        let message = L10n.shared["remote_host_id_blank"]
        XCTAssertEqual(manager.connectionStatus[host.id], .failed(message))
        XCTAssertEqual(manager.lastMessage[host.id], message)
        XCTAssertFalse(sockets.log.contains { $0.hasPrefix("open") }, "a socket was bound for it")
        XCTAssertEqual(gate.started, 0)
        XCTAssertEqual(tunnels.connects, 0)
    }

    /// A host whose fields ssh would read as options of its own does not
    /// connect, and says which: nothing reaches ssh.
    func testAHostSSHWouldMisreadDoesNotConnect() async {
        let sockets = FakeHookSockets()
        let (manager, gate, tunnels) = makeManager(sockets: sockets)
        defer { manager.shutdown() }
        let host = RemoteHost(name: "devbox", host: "-oProxyCommand=touch /tmp/ci-pwned", autoConnect: true)
        manager.addHost(host)

        manager.connect(id: host.id)
        await settle()

        let message = String(format: L10n.shared["remote_ssh_field_unsafe"], "-oProxyCommand=touch /tmp/ci-pwned")
        XCTAssertEqual(manager.connectionStatus[host.id], .failed(message))
        XCTAssertTrue(sockets.log.filter { $0.hasPrefix("open") }.isEmpty)
        XCTAssertEqual(gate.started, 0, "the probe ran ssh")
        XCTAssertEqual(tunnels.connects, 0)
    }

    // MARK: - The island's socket on the host

    /// The folder for the island's socket on the host is not the SSH
    /// user's alone: nothing is forwarded there, and the host says why.
    func testAHostWhoseSocketFolderIsUnsafeDoesNotConnect() async {
        let sockets = FakeHookSockets()
        let (manager, gate, tunnels) = makeManager(sockets: sockets)
        defer { manager.shutdown() }
        let failure = RemoteSocketCheckFailure.folderUnsafe(path: "/tmp/codeisland-1000", detail: "it belongs to uid 1001")
        gate.outcome = .failure(failure)
        let host = addHost(to: manager)
        var dropped: [String] = []
        manager.onDisconnect = { dropped.append($0) }

        manager.connect(id: host.id)
        await waitUntil { gate.started == 1 }
        await settle()

        let message = failure.message(L10n.shared)
        XCTAssertTrue(message.contains("/tmp/codeisland-1000") && message.contains("uid 1001"), message)
        XCTAssertEqual(tunnels.connects, 0, "a tunnel to an unsafe folder")
        XCTAssertEqual(manager.connectionStatus[host.id], .failed(message))
        XCTAssertNil(sockets.open[host.id], "the host's socket on this Mac stayed open")
        XCTAssertEqual(dropped, [host.id])
        XCTAssertTrue(manager.wantsConnection(id: host.id), "retried as a tunnel that failed is")
        XCTAssertEqual(manager.reconnectPhase(id: host.id), .retryPending)

        // Once the folder passes, the host connects.
        gate.outcome = .success("/tmp/codeisland-1000/island.sock")
        manager.connect(id: host.id)
        await waitUntil { tunnels.connects == 1 }
    }

    /// The host could not be reached to check the folder: it fails with
    /// ssh's own words, as a tunnel that cannot reach it does.
    func testAHostThatCannotBeCheckedFailsWithSSHsWords() async {
        let (manager, gate, tunnels) = makeManager()
        defer { manager.shutdown() }
        let words = "ssh: connect to host devbox.invalid port 22: Connection refused"
        gate.outcome = .failure(.unreachable(words))
        let host = addHost(to: manager, autoConnect: false)
        manager.connect(id: host.id)
        await waitUntil { manager.connectionStatus[host.id] == .failed(words) }
        XCTAssertEqual(tunnels.connects, 0)
    }

    /// The socket the tunnel made cannot be vouched for: the tunnel goes,
    /// with the host's socket on this Mac, and the host says why.
    func testAnUnverifiedSocketClosesItsTunnel() async {
        let sockets = FakeHookSockets()
        let installs = Installs()
        let problem = RemoteSocketCheckFailure.socketUnverified(
            path: "/tmp/codeisland-501/island.sock",
            detail: "the socket belongs to uid 0"
        )
        installs.socketProblem = problem
        let (manager, _, tunnels) = makeManager(sockets: sockets, installs: installs)
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.connected)

        let message = problem.message(L10n.shared)
        await waitUntil { manager.connectionStatus[host.id] == .failed(message) }
        XCTAssertEqual(installs.paths, ["/tmp/codeisland-501/island.sock"], "the install checks the socket the tunnel made")
        XCTAssertEqual(tunnels.made[0].disconnects, 1, "the tunnel was left up")
        XCTAssertNil(sockets.open[host.id], "the host's socket on this Mac was left open")
        XCTAssertTrue(message.contains("uid 0"), message)
    }

    /// A check that ends after its tunnel has failed on its own (and is
    /// being retried) closes nothing more, and counts no second failure.
    func testASocketProblemAfterItsTunnelFailedLeavesTheRetryAlone() async {
        let installs = Installs()
        installs.socketProblem = .socketUnverified(path: "/tmp/codeisland-501/island.sock", detail: "the socket: No such file or directory")
        installs.holding = true
        let sockets = FakeHookSockets()
        let (manager, _, tunnels) = makeManager(sockets: sockets, installs: installs)
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.connected)
        await waitUntil { installs.paths.count == 1 }

        tunnels.made[0].report(.failed("ssh exited (255)"))
        await waitUntil { manager.reconnectPhase(id: host.id) == .retryPending }
        let message = manager.lastMessage[host.id]
        installs.release()
        await settle()

        XCTAssertEqual(tunnels.made[0].disconnects, 0, "the failed tunnel was closed again")
        XCTAssertEqual(manager.connectionStatus[host.id], .failed("ssh exited (255)"))
        XCTAssertEqual(manager.lastMessage[host.id], message, "the retry's word was overwritten")
        XCTAssertEqual(manager.reconnectPhase(id: host.id), .retryPending)
    }

    /// A check that ends after the host was reconnected is old news: the
    /// newer tunnel stays.
    func testALateSocketProblemLeavesANewerTunnelAlone() async {
        let installs = Installs()
        installs.socketProblem = .socketUnverified(path: "/tmp/codeisland-501/island.sock", detail: "late")
        installs.holding = true
        let (manager, _, tunnels) = makeManager(installs: installs)
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        await connect(host, on: manager, tunnels: tunnels)
        tunnels.made[0].report(.connected)
        await waitUntil { installs.paths.count == 1 }

        manager.reconnect(id: host.id)
        await waitUntil { tunnels.connects == 2 }
        installs.release()
        await settle()

        XCTAssertEqual(tunnels.made.last?.disconnects, 0, "a late check closed the newer tunnel")
        XCTAssertEqual(manager.connectionStatus[host.id], .connecting)
    }

    // MARK: - Stale reports

    /// Reinstall swaps the tunnel; a late failure from the old one must not
    /// mark the host failed or schedule a retry.
    func testLateReportFromAReplacedTunnelIsIgnored() async {
        let (manager, _, tunnels) = makeManager()
        defer { manager.shutdown() }
        let host = addHost(to: manager)
        await connect(host, on: manager, tunnels: tunnels)
        let old = tunnels.made[0]
        old.report(.connected)
        await waitUntil { manager.connectionStatus[host.id] == .connected }

        manager.reconnect(id: host.id)
        await waitUntil { tunnels.made.count == 2 && tunnels.made[1].connects == 1 }
        old.report(.failed("late"))
        await settle()

        XCTAssertNotEqual(manager.connectionStatus[host.id], .failed("late"))
        XCTAssertEqual(manager.reconnectPhase(id: host.id), .connecting)
    }
}
