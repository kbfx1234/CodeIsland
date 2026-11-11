import XCTest
@testable import CodeIslandCore

/// Credential shapes `HookEvent.sanitizedSummary` must strip before a detail
/// reaches the notch, a companion or a push — and ordinary text it must leave
/// alone, since the same pass runs over every completion reply that is pushed.
final class PushRedactionTests: XCTestCase {
    private func redact(_ text: String) -> String {
        HookEvent.sanitizedSummary(text, limit: Int.max) ?? ""
    }

    private func assertRedacted(
        _ text: String,
        hiding secrets: [String],
        keeping kept: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = redact(text)
        for secret in secrets {
            XCTAssertFalse(result.contains(secret), "\(secret) leaked: \(result)", file: file, line: line)
        }
        for word in kept {
            XCTAssertTrue(result.contains(word), "\(word) lost: \(result)", file: file, line: line)
        }
        XCTAssertTrue(result.contains("[REDACTED]"), result, file: file, line: line)
    }

    // MARK: Shapes that used to go out as is

    func testBasicAuthorizationHeaderValue() {
        assertRedacted(
            "curl -H 'Authorization: Basic dXNlcjpodW50ZXIy' https://api.example.com",
            hiding: ["dXNlcjpodW50ZXIy"],
            keeping: ["Authorization: Basic", "https://api.example.com"]
        )
    }

    func testCurlUserPassword() {
        assertRedacted("curl -u admin:hunter2 https://example.com", hiding: ["hunter2"], keeping: ["admin:", "https://example.com"])
        assertRedacted("curl --user=admin:hunter2 https://example.com", hiding: ["hunter2"])
        assertRedacted("curl -b 'session=abc123' https://example.com", hiding: ["abc123"])
    }

    func testURLUserinfo() {
        assertRedacted("psql postgres://admin:hunter2@db.internal:5432/app", hiding: ["hunter2", "admin:"], keeping: ["@db.internal:5432/app"])
        assertRedacted(
            "git clone https://oauth2:glpat-abcdefghijklmnopqrstu@gitlab.com/team/repo.git",
            hiding: ["glpat-abcdefghijklmnopqrstu"],
            keeping: ["@gitlab.com/team/repo.git"]
        )
    }

    func testQuotedJSONKeys() {
        assertRedacted(
            #"echo '{"api_key":"k-12345","password":"hunter2","user":"ann"}'"#,
            hiding: ["k-12345", "hunter2"],
            keeping: [#""user":"ann""#]
        )
        assertRedacted(#"{'client_secret': 'cs-998877'}"#, hiding: ["cs-998877"])
    }

    func testCookieHeaders() {
        assertRedacted(#"curl -H "Cookie: session=abc123; theme=dark" https://x.example"#, hiding: ["abc123"], keeping: ["https://x.example"])
        assertRedacted("Set-Cookie: sid=zz998877", hiding: ["zz998877"])
    }

    func testQueryKeys() {
        assertRedacted("https://maps.googleapis.com/api?key=AIzaSyA1234567890abcdefghijklmnopqrstuv&v=3", hiding: ["AIzaSyA1234567890abcdefghijklmnopqrstuv"], keeping: ["&v=3"])
        assertRedacted("https://s3.example.com/f?access_key=AK12&x=1", hiding: ["AK12"], keeping: ["&x=1"])
        assertRedacted("https://api.example.com/cb?access_token=tok998", hiding: ["tok998"])
    }

    func testDatabaseAndSSHPasswords() {
        assertRedacted("mysql -u root -phunter2 app", hiding: ["hunter2"], keeping: ["-u root"])
        assertRedacted("sshpass -p hunter2 ssh deploy@host", hiding: ["hunter2"], keeping: ["deploy@host"])
        assertRedacted("PGPASSWORD=hunter2 psql -h db", hiding: ["hunter2"])
    }

    func testPrivateTokenHeaderAndProviderPrefixes() {
        assertRedacted("curl -H 'PRIVATE-TOKEN: glpat-abc' https://gitlab.com/api/v4/projects", hiding: ["glpat-abc"])
        for token in [
            "glpat-abcdefghijklmnopqrst",
            "xoxb-1234567890-abcdefghij",
            "AIzaSyA1234567890abcdefghijklmnopqrstuv",
            "npm_abcdefghijklmnopqrstuvwxyz0123456789",
            "sk_live_abcdefghijklmnop1234",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop",
        ] {
            assertRedacted("export TOKEN_VALUE \(token) now", hiding: [token])
        }
    }

    func testTelegramBotTokenInAURLPath() {
        assertRedacted(
            "curl https://api.telegram.org/bot123456789:AAEabcdefghijklmnopqrstuvwxyz012345/sendMessage",
            hiding: ["AAEabcdefghijklmnopqrstuvwxyz012345"],
            keeping: ["https://api.telegram.org/", "/sendMessage"]
        )
    }

    func testFlagsAndAssignmentsStillRedacted() {
        assertRedacted("deploy --token s3cr3t --password=hunter2", hiding: ["s3cr3t", "hunter2"])
        assertRedacted("GITHUB_TOKEN=abc123 gh release create", hiding: ["abc123"], keeping: ["gh release create"])
    }

    // MARK: Ordinary text

    func testOrdinaryProseAndCommandsAreLeftAlone() {
        let untouched = [
            "Fixed the token refresh bug and cleaned up the auth module.",
            "The password field is required; see https://example.com/docs?page=2&sort=asc.",
            "Secret sauce: tests first.",
            "git push -u origin main && docker run -u 1000:1000 app",
            "mysql -u root -p app_db",
            "ssh git@github.com and clone git@github.com:owner/repo.git",
            "Meeting at 12:30:45, ratio 16:9, port localhost:8080.",
            #"{"max_tokens": 100, "tokenizer": "bpe", "author": "Ann"}"#,
            "Add a cookie banner and a key=value parser.",
            "Updated 3 files: Sources/App.swift, README.md",
            "curl https://example.com/api/v1/items?limit=20",
        ]
        for text in untouched {
            XCTAssertEqual(redact(text), text)
        }
    }
}
