import XCTest
@testable import CodeIslandCore

/// Signature vectors were produced with the vendors' own sample code
/// (Python in open.dingtalk.com customize-robot-security-settings and
/// open.feishu.cn add-custom-bot) for the fixed inputs below.
final class PushSigningAndResponseTests: XCTestCase {

    // MARK: DingTalk 加签

    func testDingTalkSignatureMatchesTheDocumentedAlgorithm() {
        XCTAssertEqual(
            PushSigning.dingTalkSignature(secret: "SEC1234567890abcdef", timestampMillis: 1_700_000_000_000),
            "RqBq3E1RTBDv3n2QBCh4adZ2WHk9mVklyUoDBLxarjI="
        )
        // The doc's own sample secret; its signature contains '+', the
        // character a naive query encoder would leave as a space.
        XCTAssertEqual(
            PushSigning.dingTalkSignature(secret: "this is secret", timestampMillis: 1_577_262_236_757),
            "hmPWwU+7lVdm3ZZz0r9tSfx0L4Q26jWOZr9+Gs6EZQM="
        )
    }

    func testDingTalkSignIsFormEncodedLikeQuotePlus() {
        XCTAssertEqual(
            PushSigning.formURLEncoded("hmPWwU+7lVdm3ZZz0r9tSfx0L4Q26jWOZr9+Gs6EZQM="),
            "hmPWwU%2B7lVdm3ZZz0r9tSfx0L4Q26jWOZr9%2BGs6EZQM%3D"
        )
        XCTAssertEqual(PushSigning.formURLEncoded("a/b c"), "a%2Fb+c")
        XCTAssertEqual(PushSigning.formURLEncoded("é"), "%C3%A9")
    }

    func testDingTalkEncodedSignSurvivesIntoTheURL() throws {
        var config = PushChannelConfig(kind: .dingtalk)
        config.endpoint = "https://oapi.dingtalk.com/robot/send?access_token=abc"
        config.secret = "this is secret"
        let message = PushMessage(kind: .completion, sessionId: "s", title: "t", headline: "h", body: "")
        let request = try PushRequestBuilder.request(
            for: message,
            channel: config,
            now: Date(timeIntervalSince1970: 1_577_262_236.757)
        )
        XCTAssertTrue(
            request.url.absoluteString.hasSuffix("&timestamp=1577262236757&sign=hmPWwU%2B7lVdm3ZZz0r9tSfx0L4Q26jWOZr9%2BGs6EZQM%3D"),
            request.url.absoluteString
        )
    }

    // MARK: Feishu signature

    func testFeishuSignatureKeysTheMACWithTheStringToSign() {
        XCTAssertEqual(
            PushSigning.feishuSignature(secret: "demo-secret", timestampSeconds: 1_599_360_473),
            "3/MaVZ8JLIy4TUG+7KSFJqvUkTKd+HWY8g+56DZWq8s="
        )
        XCTAssertEqual(
            PushSigning.feishuSignature(secret: "abcDEF123", timestampSeconds: 1_700_000_000),
            "qimCYnXKTZRVfEDjgpOq1ke9awsBuC3tn/n151vIck8="
        )
        XCTAssertNotEqual(
            PushSigning.feishuSignature(secret: "abcDEF123", timestampSeconds: 1_700_000_000),
            PushSigning.dingTalkSignature(secret: "abcDEF123", timestampMillis: 1_700_000_000),
            "same inputs, different construction"
        )
    }

    // MARK: Response interpretation

    private func verdict(_ kind: PushChannelKind, _ status: Int, _ body: String) -> (ok: Bool, message: String) {
        PushResponseInterpreter.interpret(kind: kind, statusCode: status, body: Data(body.utf8))
    }

    func testBarkVerdicts() {
        XCTAssertEqual(verdict(.bark, 200, #"{"code":200,"message":"success","timestamp":1}"#).ok, true)
        let failed = verdict(.bark, 400, #"{"code":400,"message":"failed to get device token: record not found","timestamp":1}"#)
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.message, "failed to get device token: record not found")
    }

    func testNtfyVerdicts() {
        XCTAssertTrue(verdict(.ntfy, 200, #"{"id":"x","event":"message"}"#).ok)
        let failed = verdict(.ntfy, 403, #"{"code":40301,"http":403,"error":"forbidden","link":"https://ntfy.sh/docs/publish/#authentication"}"#)
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.message, "forbidden (40301)")
    }

    func testDingTalkAndWeComReadErrcodeEvenOnHTTP200() {
        XCTAssertTrue(verdict(.dingtalk, 200, #"{"errcode":0,"errmsg":"ok"}"#).ok)
        XCTAssertTrue(verdict(.dingtalk, 200, #"{"errcode":"0","errmsg":"ok"}"#).ok, "the docs show errcode as a string")
        let signFailed = verdict(.dingtalk, 200, #"{"errcode":310000,"errmsg":"sign not match, more: [https://ding-doc.dingtalk.com/doc#/serverapi2/qf2nxq]"}"#)
        XCTAssertFalse(signFailed.ok)
        XCTAssertTrue(signFailed.message.hasPrefix("errcode 310000: sign not match"))

        XCTAssertTrue(verdict(.wecom, 200, #"{"errcode":0,"errmsg":"ok"}"#).ok)
        XCTAssertEqual(verdict(.wecom, 200, #"{"errcode":93000,"errmsg":"invalid webhook url"}"#).message, "errcode 93000: invalid webhook url")
    }

    func testFeishuReadsCodeAndLegacyStatusCode() {
        XCTAssertTrue(verdict(.feishu, 200, #"{"StatusCode":0,"StatusMessage":"success","code":0,"data":{},"msg":"success"}"#).ok)
        XCTAssertTrue(verdict(.feishu, 200, #"{"StatusCode":0,"StatusMessage":"success"}"#).ok)
        let failed = verdict(.feishu, 200, #"{"code":19021,"msg":"sign match fail or timestamp is not within one hour from current time"}"#)
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.message, "code 19021: sign match fail or timestamp is not within one hour from current time")
    }

    func testSlackPlainTextVerdicts() {
        XCTAssertEqual(verdict(.slack, 200, "ok").ok, true)
        let failed = verdict(.slack, 404, "no_service")
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.message, "no_service")
    }

    func testTelegramDescription() {
        XCTAssertTrue(verdict(.telegram, 200, #"{"ok":true,"result":{}}"#).ok)
        let failed = verdict(.telegram, 400, #"{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}"#)
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.message, "400: Bad Request: chat not found")
    }

    func testNonJSONErrorPagesStillFailVisibly() {
        let failed = verdict(.dingtalk, 502, "<html>Bad Gateway</html>")
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.message, "<html>Bad Gateway</html>")
    }

    func testDeliveryResultFromTransport() {
        let url = URL(string: "https://api.day.app/push")!
        let noResponse = PushDeliveryResult.from(
            PushTransportResponse(statusCode: nil, errorDescription: "The request timed out."),
            kind: .bark,
            requestURL: url
        )
        XCTAssertFalse(noResponse.ok)
        XCTAssertEqual(noResponse.summary, "The request timed out.")

        let redirected = PushDeliveryResult.from(
            PushTransportResponse(
                statusCode: 200,
                body: Data(#"{"code":200,"message":"success"}"#.utf8),
                finalURL: URL(string: "https://bark.example.com:8443/secret-prefix/push?x=1")!
            ),
            kind: .bark,
            requestURL: url
        )
        XCTAssertTrue(redirected.ok)
        XCTAssertEqual(redirected.summary, "HTTP 200 · success")
        XCTAssertEqual(redirected.redirectedTo, "https://bark.example.com:8443/…", "path and query can be credentials")
    }

    // MARK: Retry

    func testRetryOnlyAfterNetworkFailures5xxAnd429() {
        func delay(_ response: PushTransportResponse) -> TimeInterval? { PushRetryPolicy.delay(after: response) }
        XCTAssertEqual(delay(PushTransportResponse(statusCode: nil, errorDescription: "The network connection was lost.")), 5)
        XCTAssertEqual(delay(PushTransportResponse(statusCode: 503)), 5)
        XCTAssertEqual(delay(PushTransportResponse(statusCode: 429, retryAfter: 12)), 12)
        XCTAssertEqual(delay(PushTransportResponse(statusCode: 429, retryAfter: 600)), 30, "capped")
        XCTAssertEqual(delay(PushTransportResponse(statusCode: 429)), 5)
        XCTAssertEqual(
            delay(PushTransportResponse(
                statusCode: 429,
                body: Data(#"{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 7","parameters":{"retry_after":7}}"#.utf8)
            )),
            7,
            "Telegram says it in the body"
        )
        XCTAssertNil(delay(PushTransportResponse(statusCode: 400)))
        XCTAssertNil(delay(PushTransportResponse(statusCode: 403)))
        XCTAssertNil(delay(PushTransportResponse(statusCode: 301, refusedRedirect: URL(string: "https://x.example")!)))

        for kind in [PushEventKind.permission, .question, .error] {
            XCTAssertTrue(PushRetryPolicy.retries(kind))
        }
        XCTAssertFalse(PushRetryPolicy.retries(.completion))
        XCTAssertFalse(PushRetryPolicy.retries(.reminder))
    }

    // MARK: Logging

    /// Server errors echo what they were sent; the log (exported with
    /// diagnostics) gets them without the channel's credentials or any IP.
    func testLoggableSummaryScrubsTheChannelsSecretsAndAddresses() {
        var bark = PushChannelConfig(kind: .bark)
        bark.target = "Abc123DeviceKeyXyz"
        let barkFailure = PushDeliveryResult(ok: false, statusCode: 400, message: "failed to push: device key Abc123DeviceKeyXyz not registered")
        XCTAssertEqual(barkFailure.loggableSummary(for: bark), "HTTP 400 · failed to push: device key [REDACTED] not registered")

        var wecom = PushChannelConfig(kind: .wecom)
        wecom.endpoint = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=693a91f6-7xxx-4bc4-97a0-0ec2sifa5aaa"
        let wecomFailure = PushDeliveryResult(
            ok: false,
            statusCode: 200,
            message: "errcode 93000: invalid webhook url, key 693a91f6-7xxx-4bc4-97a0-0ec2sifa5aaa, from ip: 203.0.113.9 / 2001:db8::1"
        )
        let logged = wecomFailure.loggableSummary(for: wecom)
        XCTAssertFalse(logged.contains("693a91f6"), logged)
        XCTAssertFalse(logged.contains("203.0.113.9"), logged)
        XCTAssertFalse(logged.contains("2001:db8"), logged)
        XCTAssertTrue(logged.hasPrefix("HTTP 200 · errcode 93000: invalid webhook url"), logged)

        var telegram = PushChannelConfig(kind: .telegram)
        telegram.token = "bot123456:ABCdefGHI"
        let telegramFailure = PushDeliveryResult(ok: false, statusCode: 401, message: "401: Unauthorized for 123456:ABCdefGHI")
        XCTAssertFalse(telegramFailure.loggableSummary(for: telegram).contains("ABCdefGHI"))

        let plain = PushDeliveryResult(ok: false, statusCode: 502, message: "Bad Gateway at 12:30")
        XCTAssertEqual(plain.loggableSummary(for: bark), "HTTP 502 · Bad Gateway at 12:30")
    }

    // MARK: Redirects

    private func post(_ url: String, auth: String? = "Basic abc") -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        return request
    }

    func testRedirectKeepsMethodBodyAndSameHostCredentials() throws {
        let original = post("http://bark.example.com/push")
        let next = try XCTUnwrap(PushRedirectPolicy.follow(
            original: original,
            to: URL(string: "https://bark.example.com/push")!,
            redirectCount: 0
        ))
        XCTAssertEqual(next.httpMethod, "POST")
        XCTAssertEqual(next.httpBody, Data("{}".utf8))
        XCTAssertEqual(next.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(next.value(forHTTPHeaderField: "Authorization"), "Basic abc")
        XCTAssertEqual(next.url?.absoluteString, "https://bark.example.com/push")
    }

    /// The body carries the Bark device key, the ntfy topic or the chat's
    /// content, and the Authorization header the basic-auth password: none
    /// of it follows a redirect to another host or down to plain http.
    func testRedirectToAnotherHostOrDownToHTTPIsRefused() {
        let original = post("https://bark.example.com/push")
        let elsewhere = URL(string: "https://elsewhere.example.net/push")!
        XCTAssertNil(PushRedirectPolicy.follow(original: original, to: elsewhere, redirectCount: 0))
        XCTAssertEqual(PushRedirectPolicy.refusal(from: original.url, to: elsewhere, redirectCount: 0), .otherHost)

        let plain = URL(string: "http://bark.example.com/push")!
        XCTAssertNil(PushRedirectPolicy.follow(original: original, to: plain, redirectCount: 0))
        XCTAssertEqual(PushRedirectPolicy.refusal(from: original.url, to: plain, redirectCount: 0), .downgrade)
        XCTAssertTrue(PushRedirectPolicy.Refusal.downgrade.namesANewAddress)
        XCTAssertFalse(PushRedirectPolicy.Refusal.tooManyHops.namesANewAddress)

        XCTAssertNil(PushRedirectPolicy.refusal(
            from: URL(string: "https://Bark.Example.com/push"),
            to: URL(string: "https://bark.example.com:8443/push/")!,
            redirectCount: 0
        ), "same host, another port or path is followed")
    }

    /// A refused redirect fails the delivery and names the address to save,
    /// without the path or query that may be the credential.
    func testRefusedRedirectIsReportedWithTheNewAddress() {
        let result = PushDeliveryResult.from(
            PushTransportResponse(
                statusCode: 301,
                body: Data("<html>Moved</html>".utf8),
                refusedRedirect: URL(string: "https://push.example.org/bark/push?key=secret")!
            ),
            kind: .bark,
            requestURL: URL(string: "https://bark.example.com/push")!
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.statusCode, 301)
        XCTAssertEqual(result.redirectRefusedTo, "https://push.example.org/…")
        XCTAssertNil(result.redirectedTo)
    }

    func testRetryAfterHeaderReadsSecondsAndHTTPDates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)  // Tue, 14 Nov 2023 22:13:20 GMT
        XCTAssertEqual(URLSessionPushTransport.retryAfter("12", now: now), 12)
        XCTAssertEqual(URLSessionPushTransport.retryAfter("Tue, 14 Nov 2023 22:13:50 GMT", now: now), 30)
        XCTAssertNil(URLSessionPushTransport.retryAfter(nil, now: now))
        XCTAssertNil(URLSessionPushTransport.retryAfter("soon", now: now))
    }

    func testRedirectChainIsBoundedAndHTTPOnly() {
        let original = post("https://a.example.com/push")
        XCTAssertNil(PushRedirectPolicy.follow(
            original: original,
            to: URL(string: "https://a.example.com/x")!,
            redirectCount: PushRedirectPolicy.maxRedirects
        ))
        XCTAssertNil(PushRedirectPolicy.follow(
            original: original,
            to: URL(string: "ftp://a.example.com/x")!,
            redirectCount: 0
        ))
    }

    // MARK: Endpoint parsing

    func testEndpointParsing() throws {
        let plain = try XCTUnwrap(PushEndpoint.parse("  api.day.app  "))
        XCTAssertEqual(plain.url.absoluteString, "https://api.day.app")
        XCTAssertNil(plain.authorization)

        let userOnly = try XCTUnwrap(PushEndpoint.parse("https://token@ntfy.example.com"))
        XCTAssertEqual(userOnly.url.absoluteString, "https://ntfy.example.com")
        XCTAssertEqual(userOnly.authorization, "Basic " + Data("token:".utf8).base64EncodedString())

        XCTAssertNil(PushEndpoint.parse(""))
        XCTAssertNil(PushEndpoint.parse("ftp://example.com/push"))
    }
}
