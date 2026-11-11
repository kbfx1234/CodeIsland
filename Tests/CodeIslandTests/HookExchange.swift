import Darwin
import Foundation

// Raw hook clients and socket files for the tests that talk to HookServer's
// sockets as hooks do.

/// A socket file at `path`, bound and closed again: what a crash leaves.
func leaveSocket(at path: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
}

/// One hook's round trip on another thread, as a hook makes it: connect,
/// write, half-close, read the answer to EOF. The test pumps the main run
/// loop HookServer answers on until it is done.
final class HookExchange: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var received: Data?

    /// Done: the island answered (or closed), or nothing listened.
    var isDone: Bool { lock.withLock { finished } }
    /// What the island answered — empty for nothing; nil when nothing listened.
    var answer: Data? { lock.withLock { received } }

    static func send(_ payload: Data, to path: String) -> HookExchange {
        let exchange = HookExchange()
        DispatchQueue.global().async {
            let answer = roundTrip(payload, path)
            exchange.lock.withLock {
                exchange.received = answer
                exchange.finished = true
            }
        }
        return exchange
    }

    private static func roundTrip(_ payload: Data, _ path: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count, let base = raw.baseAddress {
                let written = Darwin.send(fd, base + offset, raw.count - offset, 0)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
        shutdown(fd, SHUT_WR)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                answer.append(contentsOf: buffer[..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return answer
            }
        }
    }
}
