import Foundation
import AppKit
import CoreServices
import CodeIslandCore

/// FSEventStream context target. Same shape as AppState's projects watcher box:
/// the stream holds an unretained pointer to this box and reaches the watcher
/// only weakly, so a callback already queued when the watcher goes away no-ops.
private final class CoworkStreamBox: @unchecked Sendable {
    weak var watcher: CoworkSessionWatcher?
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Watches Claude Desktop's local-agent-mode session store (Cowork tasks and
/// local Chat sessions) and turns file changes into card updates. See
/// `CoworkPaths` for the layout. Strictly read-only.
///
/// Cost model — the island's idle CPU budget is tight (#299):
/// - Store absent (Claude Desktop not installed, or Cowork never used): no
///   stream at all. A vnode source on Claude's support dir (or, when even that
///   is missing, an NSWorkspace launch observer) notices the store appearing.
/// - Store present: one FSEventStream. Nothing wakes while Claude Desktop is
///   idle; during a turn events are coalesced per `latency` and filtered by a
///   path split, and only the audit log's appended bytes are ever read.
///
/// All mutable state is confined to `queue`; `onOutput` is invoked there too.
final class CoworkSessionWatcher: @unchecked Sendable {
    struct SessionUpdate: Equatable, Sendable {
        /// Store id (`local_<uuid>`).
        let sessionId: String
        let metadata: CoworkSessionMetadata
        let audit: CoworkAuditState
        let transcriptPath: String?
        /// Newest file-derived activity stamp; what a card rebuilt at launch shows.
        let lastActivity: Date?
        /// Audit lines that move a turn were appended since the previous
        /// update — a turn is live.
        let isLive: Bool
        let promptsStarted: Int
        let turnsCompleted: Int
        let permissionsRequested: Int
    }

    enum Output: Sendable {
        /// Sessions that deserve a card right after the watcher started. Always
        /// delivered once (possibly empty) so restored cards can be reconciled.
        case launchSnapshot([SessionUpdate])
        case updates([SessionUpdate])
        /// Store ids whose metadata file disappeared (session deleted).
        case removed([String])
    }

    private struct Tracked {
        let accountDirectory: String
        var metadata: CoworkSessionMetadata?
        var auditOffset: UInt64 = 0
        var auditInode: UInt64?
        var fragment = Data()
        var audit = CoworkAuditState()
        var transcriptPath: String?
    }

    let rootPath: String
    /// FSEvents reports canonical paths (`/var/…` arrives as `/private/var/…`).
    /// Resolved when the stream starts — the store may not exist before that.
    private var resolvedRootPath: String
    private let latency: CFTimeInterval
    private let usesFileSystemEvents: Bool
    private let now: @Sendable () -> Date
    private let onOutput: @Sendable (Output) -> Void
    private let queue = DispatchQueue(label: "com.codeisland.cowork-watch", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()

    private var started = false
    private var stream: FSEventStreamRef?
    private var streamBox: CoworkStreamBox?
    private var storeAppearanceSource: DispatchSourceFileSystemObject?
    private var launchObserver: NSObjectProtocol?
    private var sessions: [String: Tracked] = [:]
    /// Sessions the app side may be showing a card for. Metadata-only changes
    /// (a generated title, an archive) are only forwarded for these.
    private var surfaced: Set<String> = []

    /// Tail read when a session's state has to be rebuilt from history.
    static let tailReadBytes: UInt64 = 256 * 1024

    init(
        rootPath: String = CoworkPaths.defaultRoot(),
        latency: CFTimeInterval = 0.5,
        usesFileSystemEvents: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() },
        onOutput: @escaping @Sendable (Output) -> Void
    ) {
        self.rootPath = rootPath
        self.resolvedRootPath = rootPath
        self.latency = latency
        self.usesFileSystemEvents = usesFileSystemEvents
        self.now = now
        self.onOutput = onOutput
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        // May run on `queue` itself when a queued block held the last reference.
        if DispatchQueue.getSpecific(key: queueKey) == true {
            tearDownOnQueue()
        } else {
            queue.sync { tearDownOnQueue() }
        }
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    /// Synchronous: once this returns no further output is produced.
    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            tearDownOnQueue()
        } else {
            queue.sync { tearDownOnQueue() }
        }
    }

    private func startOnQueue() {
        guard !started else { return }
        started = true
        guard isDirectory(rootPath) else {
            onOutput(.launchSnapshot([]))
            watchForStoreAppearance()
            return
        }
        // Stream first: anything appended while the baseline is taken queues up
        // behind this block and is then read from the baseline offset.
        startStream()
        onOutput(.launchSnapshot(enumerateStore(baselineAtEnd: true, collectLaunchCandidates: true)))
    }

    private func tearDownOnQueue() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if let box = streamBox {
            box.cancel()
            streamBox = nil
            // Invalidate does not flush callbacks already queued — keep the box
            // alive until they have drained.
            queue.async { _ = box }
        }
        storeAppearanceSource?.cancel()
        storeAppearanceSource = nil
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        sessions.removeAll()
        surfaced.removeAll()
        started = false
    }

    // MARK: - Store appearance (store absent at start)

    /// The store directory is created the first time the user opens Cowork.
    /// Until then watch the one directory it will appear in — a vnode source
    /// that only fires when an entry of Claude's support dir is added or removed.
    /// Without Claude Desktop installed there is no such dir either; then only a
    /// launch observer remains, which costs nothing until an app launches.
    private func watchForStoreAppearance() {
        let parent = (rootPath as NSString).deletingLastPathComponent
        if storeAppearanceSource == nil {
            let fd = open(parent, O_EVTONLY)
            if fd >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .link, .rename],
                    queue: queue
                )
                source.setEventHandler { [weak self] in self?.storeMayHaveAppeared() }
                source.setCancelHandler { close(fd) }
                storeAppearanceSource = source
                source.resume()
            }
        }
        if launchObserver == nil {
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == AppState.claudeDesktopBundleId else { return }
                self?.queue.async { [weak self] in self?.storeMayHaveAppeared() }
            }
        }
    }

    private func storeMayHaveAppeared() {
        guard started, stream == nil else { return }
        guard isDirectory(rootPath) else {
            // Claude Desktop was just installed: its support dir exists now.
            watchForStoreAppearance()
            return
        }
        storeAppearanceSource?.cancel()
        storeAppearanceSource = nil
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        startStream()
        // Everything in a store that did not exist a moment ago is new, so read
        // it all as live activity — a first Cowork turn may already be running.
        _ = enumerateStore(baselineAtEnd: false, collectLaunchCandidates: false)
        rescan()
    }

    // MARK: - FSEvents

    private func startStream() {
        // NSString.resolvingSymlinksInPath deliberately strips `/private`, which
        // is exactly the spelling FSEvents uses — ask the kernel instead.
        if let resolved = realpath(rootPath, nil) {
            resolvedRootPath = String(cString: resolved)
            free(resolved)
        }
        guard usesFileSystemEvents, stream == nil else { return }
        let box = CoworkStreamBox()
        box.watcher = self
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(box).toOpaque()

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let box = Unmanaged<CoworkStreamBox>.fromOpaque(info).takeUnretainedValue()
            guard !box.isCancelled, let watcher = box.watcher else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)
            let rescanFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagRootChanged
            )
            var list: [String] = []
            list.reserveCapacity(count)
            var needsRescan = false
            for index in 0..<count {
                if eventFlags[index] & rescanFlags != 0 { needsRescan = true }
                if let path = paths[index] as? String { list.append(path) }
            }
            watcher.ingest(paths: list, needsRescan: needsRescan)
        }

        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot
            )
        ) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
        streamBox = box
    }

    // MARK: - Ingest (queue-confined)

    /// Entry point for one coalesced FSEvents batch. Internal so tests can feed
    /// paths directly instead of waiting on FSEvents timing.
    func ingest(paths: [String], needsRescan: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard started else { return }
        if needsRescan {
            rescan()
            return
        }
        var auditIds: Set<String> = []
        var metadataIds: Set<String> = []
        var transcriptIds: Set<String> = []
        var accountDirectories: [String: String] = [:]
        for path in paths {
            guard let classified = CoworkPaths.classify(path: path, root: rootPath)
                ?? CoworkPaths.classify(path: path, root: resolvedRootPath) else { continue }
            let id = classified.sessionId
            accountDirectories[id] = rebasedAccountDirectory(classified.accountDirectory)
            switch classified.kind {
            case .audit: auditIds.insert(id)
            case .metadata: metadataIds.insert(id)
            case .transcript: transcriptIds.insert(id)
            }
        }
        process(
            auditIds: auditIds,
            metadataIds: metadataIds,
            transcriptIds: transcriptIds,
            accountDirectories: accountDirectories
        )
    }

    /// Test seam: run `ingest` on the watcher's queue and wait for it.
    func ingestAndWait(paths: [String], needsRescan: Bool = false) {
        queue.sync { ingest(paths: paths, needsRescan: needsRescan) }
    }

    /// Test seam: start without FSEvents timing and wait for the launch scan.
    func startAndWait() {
        queue.sync { startOnQueue() }
    }

    private func process(
        auditIds: Set<String>,
        metadataIds: Set<String>,
        transcriptIds: Set<String>,
        accountDirectories: [String: String]
    ) {
        var updates: [SessionUpdate] = []
        var removed: [String] = []

        for id in auditIds.union(metadataIds).union(transcriptIds).sorted() {
            guard let accountDirectory = sessions[id]?.accountDirectory ?? accountDirectories[id] else { continue }
            let isNew = sessions[id] == nil
            let hasAudit = auditIds.contains(id)
            let hasMetadata = metadataIds.contains(id)
            // Transcript appends fire on every streamed line; they only matter
            // until the transcript path is known.
            if !isNew, !hasAudit, !hasMetadata, sessions[id]?.transcriptPath != nil {
                continue
            }
            let metadataPath = CoworkPaths.metadataPath(accountDirectory: accountDirectory, sessionId: id)
            guard FileManager.default.fileExists(atPath: metadataPath) else {
                // Atomic saves rename over the old file, so a live session's
                // metadata path never goes missing — this is a delete.
                sessions.removeValue(forKey: id)
                if surfaced.remove(id) != nil { removed.append(id) }
                continue
            }
            // Off screen with no new audit lines: nothing to report. Claude
            // Desktop re-saves metadata (system prompt and MCP config included)
            // often, so just drop the cached copy for the next live turn to
            // re-read instead of parsing every save of every session.
            if !isNew, !hasAudit, !surfaced.contains(id) {
                if hasMetadata { sessions[id]?.metadata = nil }
                continue
            }

            var tracked = sessions[id] ?? Tracked(accountDirectory: accountDirectory)
            let events = (isNew || hasAudit) ? readAppendedAudit(&tracked, sessionId: id) : []
            let previousMetadata = tracked.metadata
            if isNew || hasMetadata || tracked.metadata == nil {
                tracked.metadata = loadMetadata(metadataPath) ?? tracked.metadata
            }
            guard let metadata = tracked.metadata else {
                sessions[id] = tracked
                continue
            }

            let before = tracked.audit
            tracked.audit.apply(events)
            let previousTranscript = tracked.transcriptPath
            if tracked.transcriptPath == nil || previousMetadata?.cliSessionId != metadata.cliSessionId {
                tracked.transcriptPath = metadata.cliSessionId.flatMap {
                    CoworkPaths.transcriptPath(
                        sessionDirectory: CoworkPaths.sessionDirectory(accountDirectory: accountDirectory, sessionId: id),
                        cliSessionId: $0
                    )
                }
            }
            sessions[id] = tracked

            // Bookkeeping lines (auto-approved permissions, compact
            // boundaries, status pings) can land after a turn ended; they are
            // not a turn, and must not reopen a card the idle sweep collected.
            let isLive = events.contains { $0 != .ignored }
            let changed = isLive
                || previousMetadata != metadata
                || previousTranscript != tracked.transcriptPath
            guard changed, isLive || surfaced.contains(id) else { continue }
            if CoworkSessionPolicy.isTrackable(metadata) {
                if isLive { surfaced.insert(id) }
            } else {
                surfaced.remove(id)
            }
            updates.append(SessionUpdate(
                sessionId: id,
                metadata: metadata,
                audit: tracked.audit,
                transcriptPath: tracked.transcriptPath,
                lastActivity: CoworkSessionPolicy.lastActivity(
                    metadata: metadata,
                    auditModifiedAt: fileStat(CoworkPaths.auditPath(accountDirectory: accountDirectory, sessionId: id))?.modifiedAt
                ),
                isLive: isLive,
                promptsStarted: tracked.audit.promptCount - before.promptCount,
                turnsCompleted: tracked.audit.completedTurnCount - before.completedTurnCount,
                permissionsRequested: tracked.audit.permissionRequestCount - before.permissionRequestCount
            ))
        }

        if !removed.isEmpty { onOutput(.removed(removed)) }
        if !updates.isEmpty { onOutput(.updates(updates)) }
    }

    /// Dropped/coalesced-away events: diff the whole store against what we track.
    private func rescan() {
        var found: [String: String] = [:]
        forEachSession { id, accountDirectory in found[id] = accountDirectory }

        var auditIds: Set<String> = []
        for (id, accountDirectory) in found {
            guard let tracked = sessions[id] else {
                auditIds.insert(id)
                continue
            }
            let size = fileStat(CoworkPaths.auditPath(accountDirectory: accountDirectory, sessionId: id))?.size ?? 0
            if size != tracked.auditOffset { auditIds.insert(id) }
        }
        let metadataIds = surfaced.intersection(found.keys)
        // Gone from disk entirely: let `process` report the delete.
        let vanished = Set(sessions.keys).subtracting(found.keys)
        var accountDirectories = found
        for id in vanished {
            accountDirectories[id] = sessions[id]?.accountDirectory
        }
        process(
            auditIds: auditIds,
            metadataIds: metadataIds.union(vanished),
            transcriptIds: [],
            accountDirectories: accountDirectories
        )
    }

    // MARK: - Store enumeration

    /// Record a baseline offset for every session and, at launch, collect the
    /// ones that qualify for a card. Only stats files; a metadata file is parsed
    /// only when its session was touched within the launch freshness window.
    private func enumerateStore(baselineAtEnd: Bool, collectLaunchCandidates: Bool) -> [SessionUpdate] {
        let current = now()
        var candidates: [SessionUpdate] = []
        forEachSession { id, accountDirectory in
            let auditPath = CoworkPaths.auditPath(accountDirectory: accountDirectory, sessionId: id)
            let audit = fileStat(auditPath)
            var tracked = Tracked(accountDirectory: accountDirectory)
            tracked.auditOffset = baselineAtEnd ? (audit?.size ?? 0) : 0
            tracked.auditInode = audit?.inode

            if collectLaunchCandidates, let audit, audit.size > 0 {
                let metadataPath = CoworkPaths.metadataPath(accountDirectory: accountDirectory, sessionId: id)
                let touched = max(audit.modifiedAt, fileStat(metadataPath)?.modifiedAt ?? .distantPast)
                if current.timeIntervalSince(touched) <= CoworkSessionPolicy.launchFreshness,
                   let metadata = loadMetadata(metadataPath) {
                    let lastActivity = CoworkSessionPolicy.lastActivity(
                        metadata: metadata,
                        auditModifiedAt: audit.modifiedAt
                    )
                    if CoworkSessionPolicy.shouldSurfaceOnLaunch(
                        metadata: metadata,
                        auditSize: audit.size,
                        lastActivity: lastActivity,
                        now: current
                    ) {
                        tracked.metadata = metadata
                        let tail = readTail(path: auditPath, size: audit.size)
                        tracked.audit.apply(tail.events)
                        tracked.fragment = tail.fragment
                        tracked.transcriptPath = metadata.cliSessionId.flatMap {
                            CoworkPaths.transcriptPath(
                                sessionDirectory: CoworkPaths.sessionDirectory(
                                    accountDirectory: accountDirectory,
                                    sessionId: id
                                ),
                                cliSessionId: $0
                            )
                        }
                        surfaced.insert(id)
                        candidates.append(SessionUpdate(
                            sessionId: id,
                            metadata: metadata,
                            audit: tracked.audit,
                            transcriptPath: tracked.transcriptPath,
                            lastActivity: lastActivity,
                            isLive: false,
                            promptsStarted: 0,
                            turnsCompleted: 0,
                            permissionsRequested: 0
                        ))
                    }
                }
            }
            sessions[id] = tracked
        }
        return candidates
    }

    private func forEachSession(_ body: (_ id: String, _ accountDirectory: String) -> Void) {
        let fm = FileManager.default
        guard let accounts = try? fm.contentsOfDirectory(atPath: rootPath) else { return }
        for account in accounts where account != "skills-plugin" && !account.hasPrefix(".") {
            let accountPath = "\(rootPath)/\(account)"
            guard let orgs = try? fm.contentsOfDirectory(atPath: accountPath) else { continue }
            for org in orgs where !org.hasPrefix(".") {
                let accountDirectory = "\(accountPath)/\(org)"
                guard let entries = try? fm.contentsOfDirectory(atPath: accountDirectory) else { continue }
                for entry in entries where entry.hasSuffix(".json") {
                    let id = String(entry.dropLast(".json".count))
                    guard CoworkPaths.isValidSessionId(id) else { continue }
                    body(id, accountDirectory)
                }
            }
        }
    }

    /// FSEvents may hand back the symlink-resolved spelling of the root; keep
    /// every stored path in the configured spelling so both lookups agree.
    private func rebasedAccountDirectory(_ directory: String) -> String {
        guard resolvedRootPath != rootPath, directory.hasPrefix(resolvedRootPath + "/") else { return directory }
        return rootPath + directory.dropFirst(resolvedRootPath.count)
    }

    // MARK: - File reading

    private func loadMetadata(_ path: String) -> CoworkSessionMetadata? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return CoworkSessionMetadata.parse(data)
    }

    /// Read what was appended to the audit log since the last read. A session
    /// first seen after launch starts at 0 — it did not exist at baseline time —
    /// unless its log is already large, which only happens after a lost baseline;
    /// then the tail is enough to rebuild the state.
    private func readAppendedAudit(_ tracked: inout Tracked, sessionId: String) -> [CoworkAuditEvent] {
        let path = CoworkPaths.auditPath(accountDirectory: tracked.accountDirectory, sessionId: sessionId)
        guard let stat = fileStat(path) else { return [] }
        if let inode = tracked.auditInode, inode != stat.inode || stat.size < tracked.auditOffset {
            // Replaced or truncated underneath us: start over from the new file.
            tracked.auditOffset = 0
            tracked.fragment.removeAll()
            tracked.audit = CoworkAuditState()
        }
        tracked.auditInode = stat.inode
        guard stat.size > tracked.auditOffset else { return [] }

        var start = tracked.auditOffset
        var dropsPartialFirstLine = false
        if stat.size - start > Self.tailReadBytes * 8 {
            start = stat.size - Self.tailReadBytes
            dropsPartialFirstLine = true
            tracked.fragment.removeAll()
        }
        guard var data = readBytes(path: path, from: start, to: stat.size) else { return [] }
        tracked.auditOffset = start + UInt64(data.count)
        if dropsPartialFirstLine, let newline = data.firstIndex(of: 0x0A) {
            data = Data(data[data.index(after: newline)...])
        }
        let parsed = CoworkAuditParser.events(in: tracked.fragment + data)
        tracked.fragment = parsed.trailingFragment
        return parsed.events
    }

    private func readTail(path: String, size: UInt64) -> (events: [CoworkAuditEvent], fragment: Data) {
        let start = size > Self.tailReadBytes ? size - Self.tailReadBytes : 0
        guard var data = readBytes(path: path, from: start, to: size) else { return ([], Data()) }
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data = Data(data[data.index(after: newline)...])
        }
        let parsed = CoworkAuditParser.events(in: data)
        return (parsed.events, parsed.trailingFragment)
    }

    private func readBytes(path: String, from start: UInt64, to end: UInt64) -> Data? {
        guard end > start, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            return try handle.read(upToCount: Int(end - start)) ?? Data()
        } catch {
            return nil
        }
    }

    private struct FileStat {
        let size: UInt64
        let inode: UInt64
        let modifiedAt: Date
    }

    private func fileStat(_ path: String) -> FileStat? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let mtime = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return FileStat(size: UInt64(info.st_size), inode: UInt64(info.st_ino), modifiedAt: mtime)
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
