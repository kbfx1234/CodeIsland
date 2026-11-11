import Combine
import Foundation
import CodeIslandCore

@MainActor
final class CodexQuotaStore: ObservableObject {
    static let shared = CodexQuotaStore()

    typealias QuotaFetcher = @Sendable (String) async throws -> CodexQuotaSnapshot

    @Published private(set) var profile = CodexRuntimeProfile.unknown
    @Published private(set) var snapshot: CodexQuotaSnapshot?
    @Published private(set) var error: CodexQuotaFetchError?
    @Published private(set) var isLoading = false
    @Published private(set) var lastAttempt: Date?
    @Published private(set) var lastSuccessfulFetch: Date?
    @Published private(set) var localUsage: CodexUsageScanner.Snapshot?
    @Published private(set) var localUsageLoading = false
    @Published private(set) var cooldownUntil: Date?

    private var refreshTask: Task<Void, Never>?
    private var localUsageTask: Task<Void, Never>?
    private var localUsageFileCache = CodexUsageScanner.FileCache()
    private var localUsageGeneration = UUID()
    private var pollTimer: Timer?
    private var isStarted = false
    private let codexHomeProvider: () -> String
    private let quotaFetcher: QuotaFetcher

    init(
        codexHomeProvider: @escaping () -> String = { ConfigInstaller.codexHome() },
        quotaFetcher: @escaping QuotaFetcher = { token in
            try await CodexQuotaClient.fetch(accessToken: token)
        }
    ) {
        self.codexHomeProvider = codexHomeProvider
        self.quotaFetcher = quotaFetcher
    }

    deinit {
        pollTimer?.invalidate()
        refreshTask?.cancel()
        localUsageTask?.cancel()
    }

    func startAutoRefresh() {
        guard !isStarted else { return }
        isStarted = true
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopAutoRefresh() {
        isStarted = false
        pollTimer?.invalidate()
        pollTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        localUsageTask?.cancel()
        localUsageTask = nil
        localUsageGeneration = UUID()
        isLoading = false
        localUsageLoading = false
    }

    func refresh() {
        let codexHome = codexHomeProvider()
        let detected = CodexRuntimeProfileReader.read(codexHome: codexHome)
        profile = detected
        lastAttempt = Date()
        refreshTask?.cancel()
        refreshLocalUsage(codexHome: codexHome, fallbackSource: detected.accessKind)

        guard detected.quotaCapability == .officialFiveHourAndWeekly else {
            snapshot = nil
            error = nil
            cooldownUntil = nil
            isLoading = false
            return
        }

        if let cooldownUntil, cooldownUntil > Date() {
            error = .rateLimited
            isLoading = false
            return
        }

        guard let token = Self.accessToken(codexHome: codexHome) else {
            snapshot = nil
            error = .authenticationRequired
            isLoading = false
            return
        }

        isLoading = true
        error = nil
        let fetch = quotaFetcher
        refreshTask = Task { [weak self] in
            do {
                let fetched = try await fetch(token)
                guard !Task.isCancelled else { return }
                self?.snapshot = fetched
                self?.error = nil
                self?.cooldownUntil = nil
                self?.lastSuccessfulFetch = fetched.fetchedAt
            } catch let fetchError as CodexQuotaFetchError {
                guard !Task.isCancelled else { return }
                self?.error = fetchError
                if fetchError == .rateLimited {
                    self?.cooldownUntil = Date().addingTimeInterval(15 * 60)
                } else if fetchError == .authenticationRequired {
                    self?.snapshot = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.error = .transport(error.localizedDescription)
            }
            self?.isLoading = false
        }
    }

    private func refreshLocalUsage(codexHome: String, fallbackSource: CodexAccessKind) {
        localUsageTask?.cancel()
        let generation = UUID()
        localUsageGeneration = generation
        localUsageLoading = true
        let cache = localUsageFileCache
        localUsageTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                var nextCache = cache
                let snapshot = CodexUsageScanner.scan(
                    codexHome: codexHome,
                    fallbackSource: fallbackSource,
                    cache: &nextCache
                )
                return (snapshot, nextCache)
            }.value
            guard !Task.isCancelled, let self, self.localUsageGeneration == generation else { return }
            self.localUsage = result.0
            self.localUsageFileCache = result.1
            self.localUsageLoading = false
            self.localUsageTask = nil
        }
    }

    var displayProvider: String? {
        profile.modelProvider ?? profile.endpointHost
    }

    private static func accessToken(codexHome: String) -> String? {
        let path = URL(fileURLWithPath: codexHome, isDirectory: true)
            .appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
