import Foundation
import CodeIslandCore

/// The compact bar's mascot rotation: while more than one session is active,
/// the collapsed island cycles through them on the user's interval, the most
/// urgent first. AppState hands it the sessions after every change
/// (`update(sessions:)`); views read the session on show through
/// `AppState.rotatingSessionId`.
@MainActor
@Observable
final class CompactBarRotation {
    /// The session the compact bar shows while the rotation runs; nil while
    /// one session or none is active.
    private(set) var rotatingSessionId: String?

    /// Cached sorted active session IDs — refreshed by `update(sessions:)`.
    @ObservationIgnored
    private var activeIds: [String] = []
    /// Torn down from `AppState.deinit`, which may run off the main actor
    /// (e.g. async XCTest ARC). Only mutated on the main actor while alive.
    @ObservationIgnored
    nonisolated(unsafe) private var timer: Timer?

    /// Higher = more urgent, shown first in rotation
    nonisolated static func statusPriority(_ status: AgentStatus) -> Int {
        switch status {
        case .waitingApproval: return 5
        case .waitingQuestion: return 4
        case .running:         return 3
        case .processing:      return 2
        case .idle:            return 0
        }
    }

    /// Re-rank the active sessions, then start, steer or stop the rotation.
    /// Returns the session still active once there is nothing to rotate
    /// (nil while rotating, or when none is active), so the collapsed bar
    /// doesn't stick on an idle one.
    func update(sessions: [String: SessionSnapshot]) -> String? {
        refreshActiveIds(sessions)
        guard activeIds.count > 1 else {
            timer?.invalidate()
            timer = nil
            rotatingSessionId = nil
            return activeIds.first
        }
        // If the most urgent session changed, snap to it immediately
        if let top = activeIds.first, top != rotatingSessionId {
            let topStatus = sessions[top]?.status ?? .idle
            let currentStatus = rotatingSessionId.flatMap { sessions[$0]?.status } ?? .idle
            if Self.statusPriority(topStatus) > Self.statusPriority(currentStatus) {
                rotatingSessionId = top
            }
        }
        if rotatingSessionId == nil || !activeIds.contains(rotatingSessionId!) {
            rotatingSessionId = activeIds.first
        }
        if timer == nil {
            let interval = TimeInterval(max(1, SettingsManager.shared.rotationInterval))
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.rotateToNextSession()
                }
            }
        }
        return nil
    }

    /// Stop the timer; the session on show stays (discovery shutdown).
    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Timer teardown for `AppState.deinit`; caller must already be on the
    /// main queue (the run loop the timer was scheduled on).
    nonisolated func tearDownAssumingMain() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshActiveIds(_ sessions: [String: SessionSnapshot]) {
        activeIds = sessions
            .filter { $0.value.status != .idle }
            .sorted { a, b in
                let pa = Self.statusPriority(a.value.status)
                let pb = Self.statusPriority(b.value.status)
                if pa != pb { return pa > pb }
                // Same priority — most recently active first
                return a.value.lastActivity > b.value.lastActivity
            }
            .map(\.key)
    }

    private func rotateToNextSession() {
        guard activeIds.count > 1 else {
            rotatingSessionId = nil
            return
        }
        if let current = rotatingSessionId, let idx = activeIds.firstIndex(of: current) {
            rotatingSessionId = activeIds[(idx + 1) % activeIds.count]
        } else {
            rotatingSessionId = activeIds.first
        }
        ESP32StatePublisher.shared.notifyDirty()
        AppleCompanionPublisher.shared.notifyDirty()
    }
}
