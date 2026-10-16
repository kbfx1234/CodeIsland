import XCTest
@testable import CodeIslandCore

final class CodexRuntimeProfileTests: XCTestCase {
    func testOfficialOAuthProfileEnablesOfficialQuota() {
        let profile = CodexRuntimeProfileReader.profile(
            authJSON: data(#"{"auth_mode":"oauth","tokens":{"access_token":"secret"}}"#),
            configTOML: """
            model_provider = "openai"

            [model_providers.openai]
            base_url = "https://api.openai.com/v1"
            """
        )

        XCTAssertEqual(profile.accessKind, .officialSubscription)
        XCTAssertEqual(profile.quotaCapability, .officialFiveHourAndWeekly)
        XCTAssertEqual(profile.modelProvider, "openai")
        XCTAssertEqual(profile.endpointHost, "api.openai.com")
        XCTAssertEqual(profile.authMode, "oauth")
    }

    func testOAuthTokenStillIdentifiesOfficialProfileWithUnknownModeName() {
        let profile = CodexRuntimeProfileReader.profile(
            authJSON: data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"secret"}}"#),
            configTOML: "model_provider = \"openai\""
        )

        XCTAssertEqual(profile.accessKind, .officialSubscription)
        XCTAssertEqual(profile.quotaCapability, .officialFiveHourAndWeekly)
    }

    func testCompanyRouterWithAPIKeyIsLocalUsageOnly() {
        let profile = CodexRuntimeProfileReader.profile(
            authJSON: data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"secret"}"#),
            configTOML: """
            model_provider = "api-router"

            [model_providers.api-router]
            base_url = "https://api-router.example.test/v1"
            """
        )

        XCTAssertEqual(profile.accessKind, .apiRouter)
        XCTAssertEqual(profile.quotaCapability, .localUsageOnly)
        XCTAssertEqual(profile.endpointHost, "api-router.example.test")
        XCTAssertEqual(profile.authMode, "apikey")
    }

    func testCustomEndpointIsRouterEvenWhenProviderIsNamedOpenAI() {
        let profile = CodexRuntimeProfileReader.profile(
            authJSON: data(#"{"auth_mode":"oauth","tokens":{"access_token":"secret"}}"#),
            configTOML: """
            model_provider = "openai"
            [model_providers.openai]
            base_url = "https://gateway.example.test/openai/v1"
            """
        )

        XCTAssertEqual(profile.accessKind, .apiRouter)
        XCTAssertEqual(profile.quotaCapability, .localUsageOnly)
        XCTAssertEqual(profile.endpointHost, "gateway.example.test")
    }

    func testAPIKeyAgainstOfficialEndpointDoesNotClaimSubscriptionQuota() {
        let profile = CodexRuntimeProfileReader.profile(
            authJSON: data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"secret"}"#),
            configTOML: "model_provider = \"openai\""
        )

        XCTAssertEqual(profile.accessKind, .apiKey)
        XCTAssertEqual(profile.quotaCapability, .localUsageOnly)
    }

    func testParserHandlesCommentsSingleQuotesAndDottedProviderName() {
        let profile = CodexRuntimeProfileReader.profile(
            authJSON: data(#"{"tokens":{"access_token":"secret"}}"#),
            configTOML: """
            model_provider = 'company.router' # selected provider

            [model_providers.'company.router']
            base_url = 'https://router.example.test/v1#stable' # private endpoint
            """
        )

        XCTAssertEqual(profile.accessKind, .apiRouter)
        XCTAssertEqual(profile.modelProvider, "company.router")
        XCTAssertEqual(profile.endpointHost, "router.example.test")
        XCTAssertEqual(profile.authMode, "oauth")
    }

    func testMissingOrMalformedAuthIsUnknown() {
        let missing = CodexRuntimeProfileReader.profile(
            authJSON: nil,
            configTOML: "model_provider = \"openai\""
        )
        XCTAssertEqual(missing.accessKind, .unknown)
        XCTAssertEqual(missing.quotaCapability, .unknown)

        let malformed = CodexRuntimeProfileReader.profile(
            authJSON: data("not-json"),
            configTOML: "model_provider = \"openai\""
        )
        XCTAssertEqual(malformed.accessKind, .unknown)
        XCTAssertNil(malformed.authMode)
    }

    func testReadUsesCodexHomeFilesWithoutExposingSecrets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"secret"}"#)
            .write(to: root.appendingPathComponent("auth.json"))
        try "model_provider = \"api-router\"\n[model_providers.api-router]\nbase_url = \"https://router.example.test\"\n"
            .write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let profile = CodexRuntimeProfileReader.read(codexHome: root.path)
        XCTAssertEqual(profile.accessKind, .apiRouter)
        XCTAssertFalse(String(describing: profile).contains("secret"))
    }

    private func data(_ value: String) -> Data {
        Data(value.utf8)
    }
}
