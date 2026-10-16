import XCTest
@testable import CodeIslandCore

final class CodexQuotaTests: XCTestCase {
    func testRoutesWindowsByAdvertisedSpan() {
        let windows: [String: Any] = [
            "primary_window": ["used_percent": 61.0, "reset_at": 1_700_000_000.0,
                                "limit_window_seconds": 604_800.0],
            "secondary_window": ["used_percent": 12.0, "reset_at": 1_700_001_000.0,
                                  "limit_window_seconds": 18_000.0],
        ]

        let routed = CodexQuotaClient.routeWindows(windows)
        XCTAssertEqual(routed.weekly?.usedPercent, 0.61)
        XCTAssertEqual(routed.fiveHour?.usedPercent, 0.12)
    }

    func testRoutesWeeklyOnlyPrimaryWindow() {
        let routed = CodexQuotaClient.routeWindows([
            "primary_window": ["used_percent": 37.0, "limit_window_seconds": 604_800.0]
        ])

        XCTAssertNil(routed.fiveHour)
        XCTAssertEqual(routed.weekly?.usedPercent, 0.37)
    }

    func testFetchParsesPlanAndReset() async throws {
        let payload: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": ["used_percent": 25.0, "reset_at": 1_700_000_000.0,
                                    "limit_window_seconds": 18_000.0],
                "secondary_window": ["used_percent": 50.0, "reset_at": 1_700_100_000.0,
                                      "limit_window_seconds": 604_800.0],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let snapshot = try await CodexQuotaClient.fetch(
            accessToken: "redacted",
            now: Date(timeIntervalSince1970: 1_700_000_100)
        ) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer redacted")
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.fiveHour.usedPercent, 0.25)
        XCTAssertEqual(snapshot.weekly.usedPercent, 0.50)
        XCTAssertEqual(snapshot.fiveHour.resetAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testFetchMapsAuthAndRateLimitErrors() async {
        for status in [401, 403] {
            do {
                _ = try await CodexQuotaClient.fetch(accessToken: "x") { request in
                    (Data(), HTTPURLResponse(url: request.url!, statusCode: status,
                                             httpVersion: nil, headerFields: nil)!)
                }
                XCTFail("expected auth error")
            } catch let error as CodexQuotaFetchError {
                XCTAssertEqual(error, .authenticationRequired)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        do {
            _ = try await CodexQuotaClient.fetch(accessToken: "x") { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 429,
                                         httpVersion: nil, headerFields: nil)!)
            }
            XCTFail("expected rate limit error")
        } catch let error as CodexQuotaFetchError {
            XCTAssertEqual(error, .rateLimited)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
