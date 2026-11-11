import Foundation
import XCTest
@testable import CodeIslandCore

/// The socket a request arrives on names its machine, never the request:
/// a remote host's socket stamps every request with that host, and this
/// Mac's socket refuses a request that claims a remote host.
final class HookOriginTests: XCTestCase {
    private let devbox = HookOrigin.remoteHost(id: "devbox", name: "Dev Box")

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// The object a request goes on as, or nil when it is refused.
    private func admitted(_ data: Data, on origin: HookOrigin) throws -> [String: Any]? {
        switch origin.admit(data) {
        case .admitted(let bytes, let payload):
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            if let payload {
                XCTAssertEqual(NSDictionary(dictionary: payload), NSDictionary(dictionary: parsed),
                               "the parsed payload handed on is the request itself")
            }
            return parsed
        case .refusedRemoteClaim, .refusedUnreadable, .refusedBlankHost:
            return nil
        }
    }

    // MARK: - A remote host's socket

    func testAHostsRequestIsStampedWithTheHostWhateverItClaims() throws {
        let forged = try json([
            "hook_event_name": "Stop", "session_id": "s1",
            "_remote_host_id": "other", "_remote_host_name": "Other Box",
            "_edge": ["v": 1, "source": "claude", "host": ["id": "other", "name": "Other Box"]] as [String: Any],
        ])
        let payload = try XCTUnwrap(admitted(forged, on: devbox))
        XCTAssertEqual(payload["_remote_host_id"] as? String, "devbox")
        XCTAssertEqual(payload["_remote_host_name"] as? String, "Dev Box")
        let host = try XCTUnwrap((payload["_edge"] as? [String: Any])?["host"] as? [String: Any])
        XCTAssertEqual(host["id"] as? String, "devbox")
        XCTAssertEqual(host["name"] as? String, "Dev Box")
        XCTAssertEqual(payload["session_id"] as? String, "s1", "the rest is the request's own")
    }

    func testAHostsRequestThatNamesNoHostIsStillTheHosts() throws {
        let bare = try json(["hook_event_name": "Stop", "session_id": "s1"])
        let payload = try XCTUnwrap(admitted(bare, on: devbox))
        XCTAssertEqual(payload["_remote_host_id"] as? String, "devbox")
        XCTAssertEqual(payload["_remote_host_name"] as? String, "Dev Box")
        XCTAssertNil(payload["_edge"], "no facts are made up")

        let factsWithoutHost = try json([
            "hook_event_name": "Stop", "session_id": "s1",
            "_edge": ["v": 1, "source": "claude"] as [String: Any],
        ])
        let edge = try XCTUnwrap(admitted(factsWithoutHost, on: devbox)?["_edge"] as? [String: Any])
        XCTAssertEqual((edge["host"] as? [String: Any])?["id"] as? String, "devbox")
    }

    /// The facts HookIntake reads then name the socket's host too.
    func testHookIntakeReadsTheSocketsHost() throws {
        let forged = try json([
            "hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": "hi",
            "_edge": ["v": 1, "source": "claude", "waits": false,
                      "host": ["id": "other", "name": "Other Box"]] as [String: Any],
        ])
        guard case .admitted(_, let stamped?) = devbox.admit(forged),
              case .interpreted(let intake)? = HookEdgeFacts.delivery(in: stamped) else {
            return XCTFail("the facts were not read")
        }
        XCTAssertEqual(intake.payload["_remote_host_id"] as? String, "devbox")
        XCTAssertEqual(intake.payload["_remote_host_name"] as? String, "Dev Box")
    }

    /// A host with a blank id is stamped with nothing: every reader takes a
    /// blank `_remote_host_id` for this Mac, so its socket takes nothing at
    /// all — however the request names itself.
    func testTheSocketOfAHostWithoutAnIdTakesNothing() throws {
        for id in ["", " ", "\n\t "] {
            let nameless = HookOrigin.remoteHost(id: id, name: "Dev Box")
            XCTAssertTrue(HookOrigin.isBlankHostId(id))
            for payload in [
                try json(["hook_event_name": "Stop", "session_id": "s1"]),
                try json(["hook_event_name": "Stop", "session_id": "s1", "_remote_host_id": "devbox"]),
            ] {
                guard case .refusedBlankHost = nameless.admit(payload) else {
                    return XCTFail("a request on the socket of a host with id \(id.debugDescription) was taken")
                }
            }
        }
        XCTAssertFalse(HookOrigin.isBlankHostId(" devbox "))
    }

    func testAHostsSocketTakesOnlyAJSONObject() {
        for garbage in [Data("not json".utf8), Data("[1,2]".utf8), Data()] {
            guard case .refusedUnreadable = devbox.admit(garbage) else {
                return XCTFail("\(String(decoding: garbage, as: UTF8.self)) was not refused")
            }
        }
    }

    /// HookServer's byte probes read paths as they are written.
    func testStampingKeepsPathsAsWritten() throws {
        let payload = try json(["hook_event_name": "Stop", "session_id": "s", "cwd": "/home/u/.cursor/p"])
        guard case .admitted(let bytes, _) = devbox.admit(payload) else { return XCTFail("refused") }
        XCTAssertNotNil(bytes.range(of: Data("/home/u/.cursor/p".utf8)))
    }

    // MARK: - This Mac's socket

    func testALocalRequestPassesUnparsed() throws {
        let local = Data(#"{"hook_event_name":"Stop","session_id":"s1","cwd":"/Users/me/proj"}"#.utf8)
        guard case .admitted(let bytes, let payload) = HookOrigin.local.admit(local) else {
            return XCTFail("a local hook was refused")
        }
        XCTAssertEqual(bytes, local, "byte for byte")
        XCTAssertNil(payload, "no hook on this Mac names a host, so none is parsed for one")
    }

    func testALocalRequestThatClaimsARemoteHostIsRefused() throws {
        let claims: [String: Data] = [
            "host id": try json(["hook_event_name": "Stop", "session_id": "s", "_remote_host_id": "devbox"]),
            "host name": try json(["hook_event_name": "Stop", "session_id": "s", "_remote_host_name": "Dev Box"]),
            "edge host": try json(["hook_event_name": "Stop", "session_id": "s",
                                   "_edge": ["v": 1, "source": "claude", "host": ["id": "devbox", "name": ""]] as [String: Any]]),
            "a blank edge host": try json(["hook_event_name": "Stop", "session_id": "s",
                                           "_edge": ["v": 1, "host": ["id": "", "name": ""]] as [String: Any]]),
            "a number": try json(["hook_event_name": "Stop", "session_id": "s", "_remote_host_id": 7]),
            // Keys a byte search would miss: JSONSerialization reads them all.
            "an escaped key": Data(#"{"hook_event_name":"Stop","session_id":"s","_remote_host_id":"devbox"}"#.utf8),
            "an escaped edge": Data(#"{"hook_event_name":"Stop","session_id":"s","_edge":{"host":{"id":"devbox"}}}"#.utf8),
            "UTF-16": try XCTUnwrap(#"{"hook_event_name":"Stop","session_id":"s","_remote_host_id":"devbox"}"#.data(using: .utf16LittleEndian)),
            "UTF-32": try XCTUnwrap(#"{"hook_event_name":"Stop","session_id":"s","_remote_host_id":"devbox"}"#.data(using: .utf32BigEndian)),
        ]
        for (name, data) in claims {
            guard case .refusedRemoteClaim = HookOrigin.local.admit(data) else {
                XCTFail("\(name): a local request that claims a remote host was not refused")
                continue
            }
        }
    }

    /// No claim: a blank name names nothing, and facts that say nothing of a
    /// host are no host's.
    func testALocalRequestThatNamesNoHostPasses() throws {
        let unclaimed: [String: Data] = [
            "blank id": try json(["hook_event_name": "Stop", "session_id": "s", "_remote_host_id": "  "]),
            "null id": try json(["hook_event_name": "Stop", "session_id": "s", "_remote_host_id": NSNull()]),
            "facts without a host": try json(["hook_event_name": "Stop", "session_id": "s",
                                              "_edge": ["v": 1, "source": "claude"] as [String: Any]]),
            "an escaped prompt": Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"café"}"#.utf8),
        ]
        for (name, data) in unclaimed {
            guard case .admitted(let bytes, _) = HookOrigin.local.admit(data) else {
                XCTFail("\(name): refused")
                continue
            }
            XCTAssertEqual(bytes, data, "\(name): passed as it came")
        }
    }

    func testTheProbeFindsEveryWayToWriteAClaim() throws {
        XCTAssertFalse(HookOrigin.mayClaimRemoteHost(Data(#"{"hook_event_name":"Stop"}"#.utf8)))
        XCTAssertFalse(HookOrigin.mayClaimRemoteHost(Data()))
        XCTAssertTrue(HookOrigin.mayClaimRemoteHost(Data(#"{"_remote_host_id":"x"}"#.utf8)))
        XCTAssertTrue(HookOrigin.mayClaimRemoteHost(Data(#"{"_edge":{}}"#.utf8)))
        XCTAssertTrue(HookOrigin.mayClaimRemoteHost(Data(#"{"_edge":{}}"#.utf8)))
        XCTAssertTrue(HookOrigin.mayClaimRemoteHost(try XCTUnwrap(#"{"a":1}"#.data(using: .utf16BigEndian))))
    }
}
