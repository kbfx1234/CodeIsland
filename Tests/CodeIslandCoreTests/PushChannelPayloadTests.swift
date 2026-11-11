import XCTest
@testable import CodeIslandCore

/// Request shape per channel, checked against each vendor's documented format
/// (links in PushChannel.swift). Pure construction — nothing is sent.
final class PushChannelPayloadTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private let permission = PushMessage(
        kind: .permission,
        sessionId: "s1",
        title: "🔐 Claude · vibe-notch",
        headline: "Needs approval: Bash",
        body: "git push --force"
    )

    private let completion = PushMessage(
        kind: .completion,
        sessionId: "s1",
        title: "✅ Claude · vibe-notch",
        headline: "Finished",
        body: "All tests pass."
    )

    private func channel(_ kind: PushChannelKind, _ configure: (inout PushChannelConfig) -> Void) -> PushChannelConfig {
        var config = PushChannelConfig(kind: kind)
        config.enabled = true
        configure(&config)
        return config
    }

    private func build(_ message: PushMessage, _ config: PushChannelConfig) throws -> (PushHTTPRequest, [String: Any]) {
        let request = try PushRequestBuilder.request(for: message, channel: config, now: fixedNow)
        return (request, try XCTUnwrap(request.jsonBody))
    }

    // MARK: Bark

    func testBarkPostsToDefaultServerWithTimeSensitiveLevelForApprovals() throws {
        let (request, body) = try build(permission, channel(.bark) { $0.target = "KEY123" })
        XCTAssertEqual(request.url.absoluteString, "https://api.day.app/push")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/json; charset=utf-8")
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertEqual(body["device_key"] as? String, "KEY123")
        XCTAssertEqual(body["title"] as? String, "🔐 Claude · vibe-notch")
        XCTAssertEqual(body["subtitle"] as? String, "Needs approval: Bash")
        XCTAssertEqual(body["body"] as? String, "git push --force")
        XCTAssertEqual(body["level"] as? String, "timeSensitive")
        XCTAssertEqual(body["group"] as? String, "CodeIsland")
        XCTAssertNil(body["icon"])
        XCTAssertNil(body["sound"])
    }

    func testBarkCompletionIsActiveAndCarriesOptionalFields() throws {
        let (_, body) = try build(completion, channel(.bark) {
            $0.target = "KEY123"
            $0.group = "agents"
            $0.icon = "https://example.com/icon.png"
            $0.sound = "minuet"
        })
        XCTAssertEqual(body["level"] as? String, "active")
        XCTAssertEqual(body["group"] as? String, "agents")
        XCTAssertEqual(body["icon"] as? String, "https://example.com/icon.png")
        XCTAssertEqual(body["sound"] as? String, "minuet")
    }

    func testBarkAcceptsTheAppsCopiedURLInTheServerField() throws {
        let (request, body) = try build(permission, channel(.bark) { $0.endpoint = "https://api.day.app/KEY123/" })
        XCTAssertEqual(request.url.absoluteString, "https://api.day.app/push")
        XCTAssertEqual(body["device_key"] as? String, "KEY123")
    }

    func testBarkDoesNotRepeatAKeyGivenInBothPlaces() throws {
        let (request, _) = try build(permission, channel(.bark) {
            $0.endpoint = "https://api.day.app/KEY123"
            $0.target = "KEY123"
        })
        XCTAssertEqual(request.url.absoluteString, "https://api.day.app/push")
    }

    func testBarkSelfHostedServerMovesBasicAuthIntoAHeader() throws {
        let (request, _) = try build(permission, channel(.bark) {
            $0.endpoint = "https://me:p%40ss@bark.example.com:8443/bark"
            $0.target = "KEY123"
        })
        XCTAssertEqual(request.url.absoluteString, "https://bark.example.com:8443/bark/push")
        let expected = "Basic " + Data("me:p@ss".utf8).base64EncodedString()
        XCTAssertEqual(request.headers["Authorization"], expected)
    }

    func testBarkWithoutBodyFallsBackToHeadlineAsBody() throws {
        var message = completion
        message.body = ""
        let (_, body) = try build(message, channel(.bark) { $0.target = "K" })
        XCTAssertEqual(body["body"] as? String, "Finished")
        XCTAssertNil(body["subtitle"])
    }

    /// APNs takes 4096 bytes for the whole payload; an emoji-dense or CJK
    /// body is cut in bytes, well inside it.
    func testBarkBodyIsCutInBytesToFitAPNs() throws {
        var message = completion
        message.body = String(repeating: "😀", count: 1_000)  // 4 000 bytes
        message.headline = String(repeating: "汉", count: 500)
        let (request, body) = try build(message, channel(.bark) { $0.target = "KEY123" })
        let text = try XCTUnwrap(body["body"] as? String)
        XCTAssertLessThanOrEqual(text.utf8.count, PushRequestBuilder.barkBodyBytes)
        XCTAssertTrue(text.hasSuffix("…"))
        XCTAssertLessThanOrEqual((body["subtitle"] as? String)?.count ?? 0, PushRequestBuilder.barkSubtitleLimit)
        XCTAssertLessThan(request.body.count, 4_096, "the whole request body, bark-server adds little")
    }

    func testBarkWithoutKeyIsAConfigProblem() {
        let config = channel(.bark) { _ in }
        XCTAssertEqual(config.problem, .missingDeviceKey)
        XCTAssertFalse(config.accepts(.permission))
    }

    // MARK: ntfy

    func testNtfyPublishesJSONToServerRootWithPriorityByKind() throws {
        let config = channel(.ntfy) { $0.target = "my-topic" }
        let (request, body) = try build(permission, config)
        XCTAssertEqual(request.url.absoluteString, "https://ntfy.sh/")
        XCTAssertEqual(body["topic"] as? String, "my-topic")
        XCTAssertEqual(body["title"] as? String, "🔐 Claude · vibe-notch")
        XCTAssertEqual(body["message"] as? String, "Needs approval: Bash\ngit push --force")
        XCTAssertEqual(body["priority"] as? Int, 4)

        let (_, done) = try build(completion, config)
        XCTAssertEqual(done["priority"] as? Int, 3, "a finished turn goes at default priority")
    }

    func testNtfyLowUserPriorityAlsoLowersCompletions() throws {
        let config = channel(.ntfy) {
            $0.target = "t"
            $0.priority = 2
        }
        XCTAssertEqual(try build(permission, config).1["priority"] as? Int, 2)
        XCTAssertEqual(try build(completion, config).1["priority"] as? Int, 2)
    }

    func testNtfyTokenIsSentAsBearerAndTopicCanComeFromTheURL() throws {
        let (request, body) = try build(permission, channel(.ntfy) {
            $0.endpoint = "https://ntfy.example.com/alerts"
            $0.token = "tk_abc"
        })
        XCTAssertEqual(request.url.absoluteString, "https://ntfy.example.com/")
        XCTAssertEqual(body["topic"] as? String, "alerts")
        XCTAssertEqual(request.headers["Authorization"], "Bearer tk_abc")
    }

    /// JSON POSTed to /<topic> is published as the text of a message there,
    /// with a 200 — so a topic in Server is never kept in the URL.
    func testNtfyTopicInBothPlacesPostsToTheRootOrIsAConfigProblem() throws {
        let (request, body) = try build(permission, channel(.ntfy) {
            $0.endpoint = "https://ntfy.sh/alerts"
            $0.target = "alerts"
        })
        XCTAssertEqual(request.url.absoluteString, "https://ntfy.sh/")
        XCTAssertEqual(body["topic"] as? String, "alerts")

        let prefixed = try build(permission, channel(.ntfy) {
            $0.endpoint = "https://example.com/ntfy/alerts"
            $0.target = "alerts"
        }).0
        XCTAssertEqual(prefixed.url.absoluteString, "https://example.com/ntfy")

        let conflicting = channel(.ntfy) {
            $0.endpoint = "https://ntfy.sh/alerts"
            $0.target = "builds"
        }
        XCTAssertEqual(conflicting.problem, .ntfyTopicMismatch)
        XCTAssertFalse(conflicting.accepts(.permission))
        XCTAssertNil(channel(.ntfy) {
            $0.endpoint = "https://ntfy.sh/"
            $0.target = "builds"
        }.problem)
    }

    func testNtfyCapsTheMessageInBytes() throws {
        var message = completion
        message.body = String(repeating: "汉", count: 3_000)  // 9 000 bytes
        let (_, body) = try build(message, channel(.ntfy) { $0.target = "t" })
        let text = try XCTUnwrap(body["message"] as? String)
        XCTAssertLessThanOrEqual(text.utf8.count, PushRequestBuilder.ntfyMessageBytes)
        XCTAssertTrue(text.hasSuffix("…"))
    }

    // MARK: DingTalk

    func testDingTalkSignsTheURLWithMillisecondTimestampAndEncodedSign() throws {
        let config = channel(.dingtalk) {
            $0.endpoint = "https://oapi.dingtalk.com/robot/send?access_token=abc"
            $0.secret = "SEC1234567890abcdef"
        }
        let (request, body) = try build(permission, config)
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["access_token"], "abc")
        XCTAssertEqual(query["timestamp"], "1700000000000")
        XCTAssertEqual(query["sign"], "RqBq3E1RTBDv3n2QBCh4adZ2WHk9mVklyUoDBLxarjI%3D")

        XCTAssertEqual(body["msgtype"] as? String, "text")
        let content = try XCTUnwrap((body["text"] as? [String: Any])?["content"] as? String)
        XCTAssertEqual(content, "🔐 Claude · vibe-notch\nNeeds approval: Bash\ngit push --force\n— CodeIsland")
    }

    func testDingTalkReplacesAStaleSignatureAndLeavesUnsignedURLsAlone() throws {
        let signed = try build(permission, channel(.dingtalk) {
            $0.endpoint = "https://oapi.dingtalk.com/robot/send?access_token=abc&timestamp=1&sign=old"
            $0.secret = "SEC1234567890abcdef"
        }).0
        let names = (URLComponents(url: signed.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        XCTAssertEqual(names, ["access_token", "timestamp", "sign"])

        let unsigned = try build(permission, channel(.dingtalk) {
            $0.endpoint = "https://oapi.dingtalk.com/robot/send?access_token=abc"
        }).0
        XCTAssertEqual(unsigned.url.absoluteString, "https://oapi.dingtalk.com/robot/send?access_token=abc")
    }

    // MARK: Feishu

    func testFeishuSendsPostWithTitleParagraphsAndBodySignature() throws {
        let config = channel(.feishu) {
            $0.endpoint = "https://open.feishu.cn/open-apis/bot/v2/hook/xyz"
            $0.secret = "abcDEF123"
        }
        let (request, body) = try build(permission, config)
        XCTAssertEqual(request.url.absoluteString, "https://open.feishu.cn/open-apis/bot/v2/hook/xyz")
        XCTAssertEqual(body["msg_type"] as? String, "post")
        XCTAssertEqual(body["timestamp"] as? String, "1700000000", "seconds, as a string")
        XCTAssertEqual(body["sign"] as? String, "qimCYnXKTZRVfEDjgpOq1ke9awsBuC3tn/n151vIck8=")

        let post = try XCTUnwrap(((body["content"] as? [String: Any])?["post"] as? [String: Any])?["zh_cn"] as? [String: Any])
        XCTAssertEqual(post["title"] as? String, "🔐 Claude · vibe-notch")
        let paragraphs = try XCTUnwrap(post["content"] as? [[[String: Any]]])
        let lines = paragraphs.compactMap { $0.first?["text"] as? String }
        XCTAssertEqual(lines, ["Needs approval: Bash", "git push --force", "— CodeIsland"])
        XCTAssertTrue(paragraphs.allSatisfy { $0.first?["tag"] as? String == "text" })
    }

    func testFeishuWithoutSecretOmitsSignatureFields() throws {
        let (_, body) = try build(permission, channel(.feishu) {
            $0.endpoint = "https://open.larksuite.com/open-apis/bot/v2/hook/xyz"
        })
        XCTAssertNil(body["timestamp"])
        XCTAssertNil(body["sign"])
    }

    // MARK: WeCom

    func testWeComSendsTextWithinTheByteLimit() throws {
        var message = completion
        message.body = String(repeating: "长", count: 2_000)
        let (request, body) = try build(message, channel(.wecom) {
            $0.endpoint = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=k"
        })
        XCTAssertEqual(request.url.absoluteString, "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=k")
        XCTAssertEqual(body["msgtype"] as? String, "text")
        let content = try XCTUnwrap((body["text"] as? [String: Any])?["content"] as? String)
        XCTAssertLessThanOrEqual(content.utf8.count, 2_048)
        XCTAssertTrue(content.hasPrefix("✅ Claude · vibe-notch\nFinished\n长"))
    }

    // MARK: Slack

    func testSlackEscapesControlCharactersAndDisablesMrkdwn() throws {
        var message = permission
        message.body = "cat a.txt > b.txt && echo <done>"
        let (_, body) = try build(message, channel(.slack) {
            $0.endpoint = "https://hooks.slack.com/services/T/B/X"
        })
        XCTAssertEqual(
            body["text"] as? String,
            "🔐 Claude · vibe-notch\nNeeds approval: Bash\ncat a.txt &gt; b.txt &amp;&amp; echo &lt;done&gt;"
        )
        XCTAssertEqual(body["mrkdwn"] as? Bool, false)
    }

    // MARK: Telegram

    func testTelegramSendsHTMLWithBoldTitleToSendMessage() throws {
        var message = permission
        message.body = "echo <x> & y"
        let (request, body) = try build(message, channel(.telegram) {
            $0.token = "123:ABC"
            $0.target = "-1001234"
        })
        XCTAssertEqual(request.url.absoluteString, "https://api.telegram.org/bot123:ABC/sendMessage")
        XCTAssertEqual(body["chat_id"] as? String, "-1001234")
        XCTAssertEqual(body["parse_mode"] as? String, "HTML")
        XCTAssertEqual(
            body["text"] as? String,
            "<b>🔐 Claude · vibe-notch</b>\nNeeds approval: Bash\necho &lt;x&gt; &amp; y"
        )
        XCTAssertEqual((body["link_preview_options"] as? [String: Any])?["is_disabled"] as? Bool, true)
    }

    /// Telegram's 4096 are UTF-16 code units: 3 000 emoji are 6 000 of them.
    func testTelegramCapsTheTextInUTF16Units() throws {
        var message = completion
        message.body = String(repeating: "😀", count: 3_000)
        let (_, body) = try build(message, channel(.telegram) {
            $0.token = "123:ABC"
            $0.target = "42"
        })
        let text = try XCTUnwrap(body["text"] as? String)
        let visible = text.replacingOccurrences(of: "<b>", with: "").replacingOccurrences(of: "</b>", with: "")
        XCTAssertLessThanOrEqual(visible.utf16.count, 4_096)
        XCTAssertTrue(text.hasSuffix("😀…"), "never half an emoji")
    }

    func testTelegramAcceptsTheBotPrefixedTokenAndACustomAPIServer() throws {
        let (request, _) = try build(permission, channel(.telegram) {
            $0.token = "bot123:ABC"
            $0.target = "42"
            $0.endpoint = "http://192.168.1.5:8081"
        })
        XCTAssertEqual(request.url.absoluteString, "http://192.168.1.5:8081/bot123:ABC/sendMessage")
    }

    func testTelegramRequiresTokenAndChat() {
        XCTAssertEqual(channel(.telegram) { $0.target = "1" }.problem, .missingBotToken)
        XCTAssertEqual(channel(.telegram) { $0.token = "1:A" }.problem, .missingChatId)
    }

    // MARK: Webhook channels

    func testWebhookChannelsRequireAValidURL() {
        for kind in [PushChannelKind.dingtalk, .feishu, .wecom, .slack] {
            XCTAssertEqual(channel(kind) { _ in }.problem, .missingWebhook, "\(kind)")
            XCTAssertEqual(channel(kind) { $0.endpoint = "ftp://example.com/x" }.problem, .invalidURL, "\(kind)")
            XCTAssertNil(channel(kind) { $0.endpoint = "hooks.example.com/x" }.problem, "scheme-less URL gets https")
        }
    }

    // MARK: Stored settings

    func testChannelListRoundTripsAndFillsInMissingKinds() {
        var bark = PushChannelConfig(kind: .bark)
        bark.enabled = true
        bark.target = "KEY"
        bark.events = [.permission, .question]
        let json = PushChannelConfig.encodeList([bark])

        let decoded = PushChannelConfig.decodeList(json)
        XCTAssertEqual(decoded.map(\.kind), PushChannelKind.allCases)
        XCTAssertEqual(decoded.first, bark)
        XCTAssertTrue(decoded.dropFirst().allSatisfy { !$0.enabled })
    }

    func testCorruptOrForeignSettingsDecodeToDisabledDefaults() {
        XCTAssertTrue(PushChannelConfig.decodeList("not json").allSatisfy { !$0.enabled })
        XCTAssertTrue(PushChannelConfig.decodeList("").allSatisfy { !$0.enabled })

        let json = #"[{"kind":"pager","enabled":true},{"kind":"ntfy","enabled":true,"target":"t","events":["question","teleport"]}]"#
        let decoded = PushChannelConfig.decodeList(json)
        let ntfy = decoded.first { $0.kind == .ntfy }
        XCTAssertEqual(ntfy?.enabled, true)
        XCTAssertEqual(ntfy?.events, [.question], "unknown event names are dropped")
        XCTAssertEqual(ntfy?.endpoint, "https://ntfy.sh", "missing fields keep their defaults")
    }

    /// Team chats start headline-only, personal channels with details — and
    /// so do channels saved before the switch existed.
    func testIncludeDetailsDefaultsByChannelKindAndRoundTrips() {
        for kind in PushChannelKind.allCases {
            XCTAssertEqual(PushChannelConfig(kind: kind).includeDetails, !kind.isGroupChat, kind.rawValue)
        }
        XCTAssertEqual(
            PushChannelKind.allCases.filter(\.isGroupChat),
            [.dingtalk, .feishu, .wecom, .slack]
        )
        let legacy = #"[{"kind":"slack","enabled":true},{"kind":"bark","enabled":true,"target":"k"}]"#
        let decoded = PushChannelConfig.decodeList(legacy)
        XCTAssertEqual(decoded.first { $0.kind == .slack }?.includeDetails, false)
        XCTAssertEqual(decoded.first { $0.kind == .bark }?.includeDetails, true)

        var slack = PushChannelConfig(kind: .slack)
        slack.includeDetails = true
        let roundTripped = PushChannelConfig.decodeList(PushChannelConfig.encodeList([slack]))
        XCTAssertEqual(roundTripped.first { $0.kind == .slack }?.includeDetails, true)
    }

    func testAcceptsNeedsEnabledConfiguredAndSelectedKind() {
        var config = PushChannelConfig(kind: .ntfy)
        config.target = "t"
        XCTAssertFalse(config.accepts(.permission), "disabled")
        config.enabled = true
        XCTAssertTrue(config.accepts(.permission))
        config.events.remove(.permission)
        XCTAssertFalse(config.accepts(.permission))
        XCTAssertTrue(config.accepts(.completion))
    }
}
