import XCTest
@testable import CodeIsland

@MainActor
final class SSHForwarderTests: XCTestCase {

    // MARK: - cleanupArguments

    func testCleanupArgumentsBasic() {
        let host = RemoteHost(name: "test", host: "192.168.1.10", user: "alice")
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-501.sock")

        XCTAssertEqual(args, [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "--", "alice@192.168.1.10", "rm", "-f", "--", "/tmp/codeisland-501.sock",
        ])
    }

    func testCleanupArgumentsIncludesIdentityFile() {
        let host = RemoteHost(
            name: "test",
            host: "192.168.1.10",
            user: "alice",
            identityFile: "~/.ssh/id_ed25519"
        )
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-501.sock")

        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("~/.ssh/id_ed25519"))
        // -i must appear before the target
        let iIndex = args.firstIndex(of: "-i")!
        let targetIndex = args.firstIndex(of: "alice@192.168.1.10")!
        XCTAssertLessThan(iIndex, targetIndex)
    }

    func testCleanupArgumentsIncludesPort() {
        let host = RemoteHost(name: "test", host: "192.168.1.10", user: "alice", port: 2222)
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-501.sock")

        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("2222"))
    }

    func testCleanupArgumentsIncludesPortAndIdentity() {
        let host = RemoteHost(
            name: "test",
            host: "example.com",
            user: "bob",
            port: 2222,
            identityFile: "/Users/bob/.ssh/id_rsa"
        )
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-1000.sock")

        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("2222"))
        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("/Users/bob/.ssh/id_rsa"))
        // The last elements are always: "--", target, "rm", "-f", "--", socketPath
        let suffix = args.suffix(6)
        XCTAssertEqual(Array(suffix), ["--", "bob@example.com", "rm", "-f", "--", "/tmp/codeisland-1000.sock"])
    }

    func testCleanupArgumentsTrimsIdentityWhitespace() {
        let host = RemoteHost(
            name: "test",
            host: "192.168.1.10",
            user: "alice",
            identityFile: "  ~/.ssh/id_ed25519  "
        )
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-501.sock")

        // Should include -i with trimmed value
        let iIndex = args.firstIndex(of: "-i")!
        XCTAssertEqual(args[iIndex + 1], "~/.ssh/id_ed25519")
    }

    func testCleanupArgumentsEmptyIdentityOmitted() {
        let host = RemoteHost(name: "test", host: "192.168.1.10", user: "alice", identityFile: "")
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-501.sock")

        XCTAssertFalse(args.contains("-i"))
    }

    func testCleanupArgumentsEmptyPortOmitted() {
        let host = RemoteHost(name: "test", host: "192.168.1.10", user: "alice")
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-501.sock")

        XCTAssertFalse(args.contains("-p"))
    }

    func testCleanupArgumentsAlwaysIncludesRm() {
        let host = RemoteHost(name: "test", host: "10.0.0.1", user: "root")
        let socketPath = "/tmp/codeisland-0.sock"
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: socketPath)

        // Must contain: rm -f -- <socketPath>
        let rmIndex = args.firstIndex(of: "rm")!
        XCTAssertEqual(args[rmIndex + 1], "-f")
        XCTAssertEqual(args[rmIndex + 2], "--")
        XCTAssertEqual(args[rmIndex + 3], socketPath)
    }

    /// ssh hands the remote command to the host's shell as one line: the
    /// path is one word there, whatever it holds.
    func testTheCleanupPathIsOneWordForTheRemoteShell() {
        let host = RemoteHost(name: "test", host: "10.0.0.1", user: "root")
        let path = "/tmp/it's $(touch x) `y`.sock"
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: path)
        XCTAssertEqual(args.last, #"'/tmp/it'\''s $(touch x) `y`.sock'"#)
        XCTAssertEqual(RemoteInstaller.shellWord("/tmp/codeisland-501/island.sock"), "/tmp/codeisland-501/island.sock")
        XCTAssertEqual(RemoteInstaller.shellWord(""), "''")
    }

    func testCleanupArgumentsBatchModeAlwaysOn() {
        let host = RemoteHost(name: "test", host: "10.0.0.1", user: "root")
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-0.sock")

        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ConnectTimeout=5"))
    }

    // MARK: - tunnelArguments

    /// The host's hooks are forwarded to the socket the island bound for that
    /// host, whatever path it is given — never to a fixed one.
    func testTheTunnelForwardsTheRemoteSocketToTheGivenLocalOne() {
        let host = RemoteHost(name: "test", host: "10.0.0.1", user: "alice")
        let local = "/tmp/codeisland-501-hosts/h-0123456789abcdef.sock"
        let args = SSHForwarder.tunnelArguments(host: host, localSocketPath: local, remoteSocketPath: "/tmp/codeisland-1000.sock")

        let forward = args.firstIndex(of: "-R").map { args[$0 + 1] }
        XCTAssertEqual(forward, "/tmp/codeisland-1000.sock:\(local)")
        XCTAssertFalse(args.contains { $0.contains(HookServer.socketPath) })
        XCTAssertEqual(args.last, "alice@10.0.0.1")
    }

    /// Owner-only by default: only the SSH user may use the socket there.
    func testTheTunnelAsksForAnOwnerOnlySocketByDefault() {
        let args = SSHForwarder.tunnelArguments(
            host: RemoteHost(name: "test", host: "10.0.0.1"),
            localSocketPath: "/tmp/l.sock",
            remoteSocketPath: "/tmp/r.sock"
        )
        XCTAssertTrue(args.contains("StreamLocalBindMask=0177"))
        XCTAssertFalse(args.contains("StreamLocalBindMask=0000"))
    }

    func testAHostWhoseAgentsRunAsOtherUsersAsksForASocketEveryoneCanUse() {
        let args = SSHForwarder.tunnelArguments(
            host: RemoteHost(name: "test", host: "10.0.0.1", agentsRunAsOtherUsers: true),
            localSocketPath: "/tmp/l.sock",
            remoteSocketPath: "/tmp/r.sock"
        )
        XCTAssertTrue(args.contains("StreamLocalBindMask=0000"))
        XCTAssertFalse(args.contains("StreamLocalBindMask=0177"))
    }

    // MARK: - What reaches ssh

    /// A host that starts with `-` would be an option of ssh's own:
    /// `-oProxyCommand=…` runs a command on this Mac. Every ssh the island
    /// runs ends its options (`--`) right before the host.
    func testEverySSHEndsItsOptionsBeforeTheHost() {
        let hosts = [
            RemoteHost(name: "test", host: "-oProxyCommand=touch /tmp/ci-pwned", user: ""),
            RemoteHost(name: "test", host: "10.0.0.1", user: "-oProxyCommand=x"),
            RemoteHost(name: "test", host: "devbox", user: "alice", port: 2222, identityFile: "~/.ssh/id"),
        ]
        for host in hosts {
            let runs = [
                SSHForwarder.tunnelArguments(host: host, localSocketPath: "/tmp/l.sock", remoteSocketPath: "/tmp/r.sock"),
                SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/r.sock"),
                RemoteInstaller.sshArguments(host: host),
            ]
            for args in runs {
                let target = args.firstIndex(of: host.sshTarget)
                XCTAssertNotNil(target, "\(args)")
                XCTAssertEqual(target.map { args[$0 - 1] }, "--", "the host may be read as an option: \(args)")
                XCTAssertEqual(args.firstIndex(of: "--"), target.map { $0 - 1 }, "an option after the end of options: \(args)")
            }
        }
    }

    /// What ssh is never given: a host, user or identity file that starts
    /// with `-` or holds a control character, a host with a space, a port
    /// that is not one.
    func testFieldsSSHWouldMisreadAreFound() {
        let unsafe: [(RemoteHost, String)] = [
            (RemoteHost(name: "t", host: "-oProxyCommand=touch /tmp/x"), "-oProxyCommand=touch /tmp/x"),
            (RemoteHost(name: "t", host: " -p2222 devbox"), "-p2222 devbox"),
            (RemoteHost(name: "t", host: "dev box"), "dev box"),
            (RemoteHost(name: "t", host: "devbox\nProxyCommand x"), "devbox\nProxyCommand x"),
            (RemoteHost(name: "t", host: "devbox", user: "-lroot"), "-lroot"),
            (RemoteHost(name: "t", host: "devbox", user: "al\u{7}ice"), "al\u{7}ice"),
            (RemoteHost(name: "t", host: "devbox", identityFile: "-oProxyCommand=x"), "-oProxyCommand=x"),
            (RemoteHost(name: "t", host: "devbox", port: 0), "0"),
            (RemoteHost(name: "t", host: "devbox", port: 65_536), "65536"),
            (RemoteHost(name: "t", host: "devbox", port: -22), "-22"),
        ]
        for (host, field) in unsafe {
            XCTAssertEqual(host.unsafeSSHField, field)
        }
        let safe = [
            RemoteHost(name: "t", host: "devbox"),
            RemoteHost(name: "t", host: " 192.168.1.10 ", user: "alice", port: 22),
            RemoteHost(name: "t", host: "fe80::1%en0", user: "AD\\John Smith", port: 65_535),
            RemoteHost(name: "t", host: "build-01.example.com", identityFile: "~/My Keys/id_ed25519"),
        ]
        for host in safe {
            XCTAssertNil(host.unsafeSSHField, host.sshTarget)
        }
    }

    /// The forwarder itself starts no ssh for such a host.
    func testTheForwarderStartsNoSSHForAFieldItWouldMisread() {
        let forwarder = SSHForwarder()
        forwarder.connect(
            host: RemoteHost(name: "t", host: "-oProxyCommand=touch /tmp/ci-pwned"),
            localSocketPath: "/tmp/l.sock",
            remoteSocketPath: "/tmp/r.sock"
        )
        XCTAssertEqual(forwarder.status, .failed("invalid host"))
    }
}
