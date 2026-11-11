import Darwin
import Foundation
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "HookServer")

/// How much of the island the hooks on one socket may take.
///
/// This Mac's hooks are the user's own processes, and keep what they always
/// had. A remote host's socket is the end of its SSH forward: whoever can
/// reach the island's socket on that host — every user there, when its
/// agents run as other users — reaches this one, and must not be able to
/// hold the island's descriptors (one per connection, from a limit every
/// socket shares), its memory or its cards. So a host gets a bounded share:
/// so many connections at once, so many requests waiting on an answer,
/// smaller requests, and a time by which each must have arrived. What goes
/// past it is that host's loss alone.
struct HookSocketLimits: Equatable, Sendable {
    /// The most one request may be, in bytes.
    var maxRequestBytes: Int
    /// How long a hook may send nothing before its request is complete.
    var readIdleTimeout: TimeInterval
    /// How long a request may take to arrive in all, however steadily it
    /// trickles in; nil: as long as it keeps coming.
    var readDeadline: TimeInterval?
    /// The most connections open at once; one more is closed the moment it
    /// is accepted. Nil: no bound.
    var maxConnections: Int?
    /// The most bytes of unfinished requests the socket's connections hold
    /// between them; the connection that would pass it is dropped. Nil: no
    /// bound.
    var maxBufferedBytes: Int?
    /// The most requests held for an answer at once (permission requests,
    /// questions); one more is answered at once with nothing, so its agent
    /// asks in its own way. Nil: no bound.
    var maxHeldRequests: Int?

    /// This Mac's socket: as it always was.
    static let local = HookSocketLimits(
        maxRequestBytes: 10_485_760,
        readIdleTimeout: HookConnection.readIdleTimeout
    )

    /// A remote host's socket. A hook writes its request at once; the
    /// deadline leaves a slow SSH link minutes for the largest one.
    static let remoteHost = HookSocketLimits(
        maxRequestBytes: 1_048_576,
        readIdleTimeout: HookConnection.readIdleTimeout,
        readDeadline: 300,
        maxConnections: 64,
        maxBufferedBytes: 8_388_608,
        maxHeldRequests: 32
    )

    /// The limits of a socket whose requests come from `origin`.
    static func `for`(_ origin: HookOrigin) -> HookSocketLimits {
        if case .remoteHost = origin { return .remoteHost }
        return .local
    }
}

/// The bytes of unfinished requests a socket's connections hold between
/// them (``HookSocketLimits/maxBufferedBytes``). Used on the listener's
/// queue only.
final class HookReadBudget: @unchecked Sendable {
    let limit: Int
    private(set) var used = 0

    init(limit: Int) {
        self.limit = limit
    }

    /// Takes `count` bytes; false, taking nothing, when that would pass the
    /// limit.
    func take(_ count: Int) -> Bool {
        guard count <= limit - used else { return false }
        used += count
        return true
    }

    func give(_ count: Int) {
        used -= min(count, used)
    }
}

/// The island's end of the hook socket: a Unix-domain stream listener that
/// accepts and reads every connection on its own queue, off the main thread.
///
/// A hook that does not wait for an answer may close its end the moment it
/// has written its event: the remote hook does, and so does a plugin whose
/// process quits right after its SessionEnd. The kernel keeps such a
/// connection, with its bytes and its EOF, until it is accepted. NWListener
/// did not: a connection whose peer had closed before NWListener had set it
/// up was dropped without a callback, on whatever queue the listener ran,
/// and its event was lost — a stale card, when that was a Stop.
final class HookSocketListener: @unchecked Sendable {
    let path: String
    private let queue: DispatchQueue
    private let maxConnections: Int?
    private let onConnection: @Sendable (HookConnection) -> Void
    // On `queue`, once started.
    private var source: DispatchSourceRead?
    private var paused = false
    /// Accepted connections not yet closed.
    private var openConnections = 0
    /// Connections are being turned away (``maxConnections``): logged once
    /// each time it starts.
    private var turningAway = false
    /// The socket file start() made, by device and inode, so that
    /// removeSocketFile() never takes one that has taken its place. Set and
    /// read on the thread that starts and removes the listener.
    private var madeFile: (device: dev_t, inode: ino_t)?

    /// `onConnection` gets each accepted connection, on `queue`. With
    /// `maxConnections`, a connection accepted while that many are open is
    /// closed at once: its hook finds no island.
    init(
        path: String,
        queue: DispatchQueue,
        maxConnections: Int? = nil,
        onConnection: @escaping @Sendable (HookConnection) -> Void
    ) {
        self.path = path
        self.queue = queue
        self.maxConnections = maxConnections
        self.onConnection = onConnection
    }

    deinit {
        // Dropped without stop(): the socket must not stay open. Nothing else
        // can be running: every handler holds the listener weakly.
        guard let source else { return }
        if paused { source.resume() }
        source.cancel()
    }

    /// Creates the socket file, readable by this user only, and starts
    /// accepting. False, logged, when the socket cannot be created — or
    /// another island of this user's listens there already: its socket is
    /// never taken from under it.
    func start() -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        // Before anything is removed: a path no socket can have is left alone.
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            log.error("HookServer: socket path too long: \(self.path, privacy: .public)")
            return false
        }
        // A listener of this process's own is one being replaced, as before.
        if let other = Self.islandListening(at: path), other != getpid() {
            log.error("HookServer: another CodeIsland (pid \(other)) already listens at \(self.path, privacy: .public); leaving it alone")
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.error("HookServer: socket() failed: \(String(cString: strerror(errno)), privacy: .public)")
            return false
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // The umask is set before bind() creates the socket file, so the file
        // is never accessible to anyone else, not even briefly.
        let previousUmask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousUmask)
        guard bound == 0, listen(fd, SOMAXCONN) == 0 else {
            log.error("HookServer: cannot listen on \(self.path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            if bound == 0 { unlink(path) }
            return false
        }
        // Belt-and-suspenders: owner-only even if the umask did not take.
        chmod(path, 0o700)
        var made = stat()
        if lstat(path, &made) == 0 {
            madeFile = (made.st_dev, made.st_ino)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // Before the handlers, which read it (pause()): ThreadSanitizer orders
        // what precedes setting a handler before the handler runs, and not
        // what comes between that and resume().
        self.source = source
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return true
    }

    /// Whether an island already listens at `path`: a socket of `uid`'s
    /// there that takes a connection, from a listener the kernel says is
    /// `uid` too. Its pid when one does (0 when the kernel will not say);
    /// nil for a stale file, a path nobody holds, or anyone else's. Answers
    /// the connection it makes with nothing: an island reads an empty
    /// request and drops it.
    static func islandListening(at path: String, uid: uid_t = getuid()) -> pid_t? {
        guard case .thisUser = SocketPath.holder(of: path, uid: uid) else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, SocketPath.peerIsUser(fd, uid: uid) else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) != 0 { pid = 0 }
        return pid
    }

    /// Removes the socket file start() made, and nothing else: not a file
    /// that has taken its place at `path` since.
    func removeSocketFile() {
        guard let made = madeFile else { return }
        madeFile = nil
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_dev == made.device, info.st_ino == made.inode,
              (info.st_mode & S_IFMT) == S_IFSOCK else { return }
        unlink(path)
    }

    /// Stops accepting and closes the listener. Connections already accepted
    /// carry on until they are answered.
    func stop() {
        queue.async { [self] in
            guard let source else { return }
            self.source = nil
            if paused {
                paused = false
                source.resume()
            }
            source.cancel()
        }
    }

    private func acceptPending(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client >= 0 {
                if let maxConnections, openConnections >= maxConnections {
                    // Accepted only to be closed: left queued, it would fill
                    // the backlog for good.
                    Darwin.close(client)
                    if !turningAway {
                        turningAway = true
                        log.warning("HookServer: \(self.path, privacy: .public) already has \(maxConnections) connections open; turning more away")
                    }
                    continue
                }
                openConnections += 1
                let connection = HookConnection(fd: client, queue: queue)
                connection.onClose { [weak self] in self?.connectionClosed() }
                onConnection(connection)
                continue
            }
            let error = errno
            switch error {
            case EINTR, ECONNABORTED:
                continue
            case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                // That connection is lost: XNU closes the connection accept()
                // fails on rather than leave it queued, and its hook finds
                // its end closed. Back off briefly rather than spin on a
                // listener that stays readable, losing one connection after
                // another. The limit raised at launch (raiseDescriptorLimit)
                // leaves this to a real shortage.
                log.error("HookServer: cannot accept: \(String(cString: strerror(error)), privacy: .public)")
                pause()
                return
            default:
                return  // EAGAIN: none left
            }
        }
    }

    /// An accepted connection closed. On `queue`.
    private func connectionClosed() {
        openConnections -= 1
        if turningAway, openConnections < (maxConnections ?? .max) {
            turningAway = false
        }
    }

    private func pause() {
        guard let source, !paused else { return }
        paused = true
        source.suspend()
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.paused, let source = self.source else { return }
            self.paused = false
            source.resume()
        }
    }

    /// The soft limit on open descriptors the island wants. launchd starts an
    /// app with 256, and a held request keeps its hook's socket open for as
    /// long as the hook waits; short of descriptors, accept() drops the
    /// connection it fails on.
    static let wantedDescriptorLimit: rlim_t = 4096

    /// Raises this process's soft descriptor limit toward
    /// ``wantedDescriptorLimit``: never past the hard limit, never lower.
    static func raiseDescriptorLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0,
              let raised = raisedDescriptorLimit(soft: limit.rlim_cur, hard: limit.rlim_max) else { return }
        limit.rlim_cur = raised
        if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
            log.error("HookServer: cannot raise the descriptor limit to \(raised): \(String(cString: strerror(errno)), privacy: .public)")
        }
    }

    /// The soft limit to set; nil when `soft` already reaches what is wanted,
    /// or what `hard` allows.
    static func raisedDescriptorLimit(soft: rlim_t, hard: rlim_t) -> rlim_t? {
        let target = min(hard, wantedDescriptorLimit)
        return target > soft ? target : nil
    }
}

/// Tells held hook connections that their hook is gone, through one kqueue
/// for all of them: a held request costs its socket and nothing more, and
/// watching one more needs no descriptor that may not be there.
///
/// A hook half-closes its end once it has written (the bridge's
/// `shutdown(SHUT_WR)`), so its EOF on the read side says nothing. The write
/// side ends only when the hook is gone: the write filter, edge triggered,
/// fires once when it is added (writable), then not again until that happens
/// (EV_EOF). Nothing is polled. Each watch carries a token of its own, so a
/// descriptor closed and its number reused is never taken for the
/// connection that had it.
final class HookPeerWatch: @unchecked Sendable {
    static let shared = HookPeerWatch()

    private struct Watched {
        weak var connection: HookConnection?
    }

    private let makeKqueue: () -> Int32
    private let queue = DispatchQueue(label: "com.codeisland.hook-peer-watch", qos: .userInitiated)
    private let lock = NSLock()
    // Under `lock`:
    private var kq: Int32 = -1
    private var source: DispatchSourceRead?
    private var watched: [UInt: Watched] = [:]
    private var lastToken: UInt = 0

    /// `makeKqueue` is for tests: a kqueue() that fails.
    init(makeKqueue: @escaping () -> Int32 = { kqueue() }) {
        self.makeKqueue = makeKqueue
    }

    deinit {
        // The shared watch lives as long as the app; a test's ends here.
        source?.cancel()
    }

    /// Watches `fd` until its hook is gone, then tells `connection`. Nil,
    /// logged, when no watch can be set (no kqueue to be had): the
    /// connection must find out some other way.
    func watch(_ fd: Int32, for connection: HookConnection) -> UInt? {
        lock.lock()
        defer { lock.unlock() }
        guard let kq = openKqueue() else { return nil }
        lastToken += 1
        let token = lastToken
        var change = kevent(
            ident: UInt(fd),
            filter: Int16(EVFILT_WRITE),
            flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: 0,
            data: 0,
            udata: UnsafeMutableRawPointer(bitPattern: token)
        )
        guard kevent(kq, &change, 1, nil, 0, nil) == 0 else {
            log.error("HookServer: cannot watch a held hook: \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        watched[token] = Watched(connection: connection)
        return token
    }

    /// Stops telling the connection of `token`, which is closing. Its
    /// descriptor's close takes the kevent away.
    func unwatch(_ token: UInt) {
        lock.lock()
        watched[token] = nil
        lock.unlock()
    }

    /// The kqueue, opened on first use; nil, logged, while it cannot be.
    /// Under `lock`.
    private func openKqueue() -> Int32? {
        if kq >= 0 { return kq }
        let opened = makeKqueue()
        guard opened >= 0 else {
            log.error("HookServer: kqueue() failed: \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        _ = fcntl(opened, F_SETFD, FD_CLOEXEC)
        let source = DispatchSource.makeReadSource(fileDescriptor: opened, queue: queue)
        kq = opened
        self.source = source
        source.setEventHandler { [weak self] in self?.reportGone(from: opened) }
        source.setCancelHandler { Darwin.close(opened) }
        source.resume()
        return opened
    }

    /// Tells each connection whose hook has gone. On `queue`.
    private func reportGone(from kq: Int32) {
        var events: [kevent] = Array(repeating: kevent(), count: 16)
        var now = timespec(tv_sec: 0, tv_nsec: 0)
        while true {
            let count = kevent(kq, nil, 0, &events, Int32(events.count), &now)
            guard count > 0 else { return }
            for event in events.prefix(Int(count)) where event.flags & UInt16(EV_EOF) != 0 {
                let token = UInt(bitPattern: event.udata)
                lock.lock()
                let connection = watched.removeValue(forKey: token)?.connection
                lock.unlock()
                connection?.peerLeft()
            }
        }
    }
}

/// One accepted hook connection. Its state lives on the listener's queue;
/// ``respond(_:)``, ``cancel()``, ``onClose(_:)``, ``closeWhenPeerLeaves()``
/// and ``closeIfPeerGone()`` may be called from any thread.
final class HookConnection: @unchecked Sendable {
    /// What the hook sent.
    enum Request {
        /// Everything up to the hook's EOF — or up to a read error, as
        /// NWConnection's receive handed it over.
        case received(Data)
        /// More than the limit; the rest is not read.
        case tooLarge
        /// The connection failed before a single byte.
        case failed
        /// The hook sent nothing for the idle timeout and did not finish:
        /// it stalled, or never half-closed — or its request was still not
        /// complete by the read deadline. What came is not used.
        case stalled
        /// The socket's connections already hold all the unfinished
        /// requests they may (``HookReadBudget``); the rest is not read.
        case overBudget
    }

    /// How long a hook may send nothing before its request is complete (its
    /// EOF). Generous: a hook writes its request at once, but over SSH the
    /// bytes may come slowly. The wait for a held request's answer, which
    /// follows, has no such bound.
    static let readIdleTimeout: TimeInterval = 120

    /// How often a held connection asks its socket whether the hook is gone
    /// when it cannot be watched (``closeWhenPeerLeaves()``).
    static let peerPollInterval: TimeInterval = 1

    private let fd: Int32
    private let queue: DispatchQueue
    private let peerWatch: HookPeerWatch
    // On `queue`:
    private var reader: DispatchSourceRead?
    private var readerIdle: DispatchSourceTimer?
    private var writer: DispatchSourceWrite?
    private var peerWatchToken: UInt?
    private var peerPoll: DispatchSourceTimer?
    /// Sources on `fd` whose cancel handler has not run yet: the descriptor
    /// is closed only once they are gone.
    private var sourcesOnDescriptor = 0
    private var received = Data()
    /// The budget `received` counts against, while it is read.
    private var readBudget: HookReadBudget?
    private var unsent = Data()
    private var answered = false
    private var finishing = false
    private var closed = false
    private var closeHandlers: [@Sendable () -> Void] = []

    /// `peerWatch` is for tests: one whose kqueue cannot be had.
    init(fd: Int32, queue: DispatchQueue, peerWatch: HookPeerWatch = .shared) {
        self.fd = fd
        self.queue = queue
        self.peerWatch = peerWatch
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    deinit {
        // Dropped without an answer or cancel(): the descriptor must not
        // leak, nor its hook wait on a socket nobody holds. No dispatch
        // source can be left — each holds the connection until it is
        // cancelled and done — so the descriptor is closed here, once.
        guard !closed else { return }
        if let peerWatchToken { peerWatch.unwatch(peerWatchToken) }
        if let readBudget, !received.isEmpty {
            let count = received.count
            queue.async { readBudget.give(count) }
        }
        Darwin.close(fd)
        let handlers = closeHandlers
        if !handlers.isEmpty {
            queue.async { handlers.forEach { $0() } }
        }
    }

    /// Reads what the hook sends, to its EOF, and hands it to `completion`
    /// on the queue — ``Request/stalled`` once nothing has come for
    /// `idleTimeout`, or the request is still not complete `deadline` after
    /// the read began; ``Request/overBudget`` once what it sent would pass
    /// what `budget` has left. Called once, on the queue.
    func readRequest(
        limit: Int,
        idleTimeout: TimeInterval = HookConnection.readIdleTimeout,
        deadline: TimeInterval? = nil,
        budget: HookReadBudget? = nil,
        completion: @escaping (Request) -> Void
    ) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let idle = DispatchSource.makeTimerSource(queue: queue)
        reader = source
        readerIdle = idle
        readBudget = budget
        // The idle timer, re-armed by every chunk, never past the deadline:
        // a hook that trickles a byte now and then is still cut off there.
        let cutoff = deadline.map { DispatchTime.now() + $0 }
        let nextCheck = { () -> DispatchTime in
            let idleEnd = DispatchTime.now() + idleTimeout
            guard let cutoff else { return idleEnd }
            return min(idleEnd, cutoff)
        }
        let handOver = { [self] (request: Request) in
            reader?.cancel()
            reader = nil
            readerIdle?.cancel()
            readerIdle = nil
            // Handed over: a held connection, which may wait for hours,
            // keeps none of its request (up to `limit` bytes).
            releaseReadBudget()
            received = Data()
            completion(request)
        }
        source.setEventHandler { [self] in
            guard reader != nil else { return }
            let before = received.count
            if let request = readAvailable(limit: limit) {
                handOver(request)
            } else if received.count > before {
                idle.schedule(deadline: nextCheck())
            }
        }
        idle.setEventHandler { [self] in
            guard reader != nil else { return }
            if let cutoff, DispatchTime.now() >= cutoff {
                log.warning("HookServer: a hook's request was still not complete after \(Int(deadline ?? 0)) s; dropping it")
            } else {
                log.warning("HookServer: a hook sent nothing for \(Int(idleTimeout)) s before its EOF; dropping it")
            }
            handOver(.stalled)
        }
        countOnDescriptor(source)
        idle.schedule(deadline: nextCheck())
        source.resume()
        idle.resume()
    }

    /// Gives back what the request read so far took from its budget.
    private func releaseReadBudget() {
        readBudget?.give(received.count)
        readBudget = nil
    }

    /// The bytes of its request the connection still keeps. For tests.
    var keptRequestBytesForTesting: Int {
        queue.sync { received.count }
    }

    /// Writes `answer` — nothing, when it is empty — then closes. The first
    /// answer is the one: a later one, even while the first is still being
    /// written, is dropped.
    func respond(_ answer: Data) {
        queue.async { [self] in
            guard !answered, !finishing else { return }
            answered = true
            unsent = answer
            writeUnsent()
        }
    }

    /// Closes without an answer.
    func cancel() {
        queue.async { [self] in finish() }
    }

    /// Runs `handler` on the queue once the connection is closed: answered,
    /// cancelled, or its hook gone (``closeWhenPeerLeaves()``).
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if closed {
                handler()
            } else {
                closeHandlers.append(handler)
            }
        }
    }

    /// Closes the connection as soon as the hook at the other end is gone —
    /// killed, or its agent answered without the island (``HookPeerWatch``).
    /// Should no watch be had (no kqueue: the descriptors ran out), the
    /// socket is asked every ``peerPollInterval`` instead: a hook that goes
    /// is noticed a little later, but noticed.
    func closeWhenPeerLeaves() {
        queue.async { [self] in
            guard !finishing, peerWatchToken == nil, peerPoll == nil else { return }
            if let token = peerWatch.watch(fd, for: self) {
                peerWatchToken = token
                return
            }
            let poll = DispatchSource.makeTimerSource(queue: queue)
            peerPoll = poll
            // Held until the hook goes or the connection closes, as a watched
            // connection is held by its hook.
            poll.setEventHandler { [self] in finishIfPeerGone() }
            poll.schedule(deadline: .now() + Self.peerPollInterval, repeating: Self.peerPollInterval)
            poll.resume()
        }
    }

    /// Closes the connection if the hook at the other end is gone; while it
    /// is there — half-closed, waiting for its answer — nothing happens.
    func closeIfPeerGone() {
        queue.async { [self] in finishIfPeerGone() }
    }

    /// The watch saw the hook go. On the watch's queue.
    fileprivate func peerLeft() {
        queue.async { [self] in finish() }
    }

    // MARK: - On the queue

    /// What has arrived; the request once it is complete, else nil.
    private func readAvailable(limit: Int) -> Request? {
        withUnsafeTemporaryAllocation(byteCount: 65_536, alignment: 1) { buffer in
            while true {
                let count = read(fd, buffer.baseAddress, buffer.count)
                if count > 0 {
                    if received.count + count > limit { return .tooLarge }
                    if let readBudget, !readBudget.take(count) { return .overBudget }
                    received.append(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: count)
                    continue
                }
                if count == 0 { return .received(received) }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    return nil
                default:
                    return received.isEmpty ? .failed : .received(received)
                }
            }
        }
    }

    /// Closes the connection if the hook has closed its end for good: nothing
    /// can be sent to it any more (POLLHUP on the write side). Its half-close
    /// is not that.
    private func finishIfPeerGone() {
        guard !finishing else { return }
        var check = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&check, 1, 0) > 0, check.revents & Int16(POLLHUP | POLLERR) != 0 else { return }
        finish()
    }

    private func writeUnsent() {
        while !unsent.isEmpty {
            // A hook may be gone before its answer: EPIPE then, not a SIGPIPE,
            // which the app does not ignore. Per write, not SO_NOSIGPIPE: the
            // kernel takes no option on a socket whose peer closed before it
            // was accepted.
            let written = unsent.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
            if written > 0 {
                unsent.removeFirst(written)
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN {
                waitUntilWritable()
                return
            } else {
                break  // EPIPE: the hook is gone, nobody is left to answer.
            }
        }
        finish()
    }

    private func waitUntilWritable() {
        guard writer == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in writeUnsent() }
        countOnDescriptor(source)
        writer = source
        source.resume()
    }

    /// The descriptor stays open until `source` is cancelled and gone.
    private func countOnDescriptor(_ source: DispatchSourceProtocol) {
        sourcesOnDescriptor += 1
        source.setCancelHandler { [self] in
            sourcesOnDescriptor -= 1
            closeIfDone()
        }
    }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        reader?.cancel()
        reader = nil
        readerIdle?.cancel()
        readerIdle = nil
        releaseReadBudget()
        received = Data()
        writer?.cancel()
        writer = nil
        if let peerWatchToken {
            peerWatch.unwatch(peerWatchToken)
            self.peerWatchToken = nil
        }
        peerPoll?.cancel()
        peerPoll = nil
        closeIfDone()
    }

    private func closeIfDone() {
        guard finishing, !closed, sourcesOnDescriptor == 0 else { return }
        closed = true
        Darwin.close(fd)
        let handlers = closeHandlers
        closeHandlers = []
        handlers.forEach { $0() }
    }
}
