import Foundation
import Darwin

/// Minimal TCP connect check against localhost:<port>.
/// Resolves `localhost` to all its addresses (IPv4 127.0.0.1 *and* IPv6 ::1)
/// and returns true if any of them accepts a connection within the timeout.
/// This matters because some dev servers (e.g. Vite) bind IPv6-only by default,
/// so an IPv4-only probe would report them as down when they're actually up.
enum PortProbe {
    static func isOpen(port: Int, timeout: TimeInterval = 0.3) -> Bool {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,            // both IPv4 and IPv6
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("localhost", String(port), &hints, &result) == 0 else { return false }
        defer { freeaddrinfo(result) }

        var node = result
        while let addr = node {
            if connects(to: addr.pointee, timeout: timeout) { return true }
            node = addr.pointee.ai_next
        }
        return false
    }

    /// Attempt a non-blocking, time-bounded connect to a single resolved address.
    /// Uses poll() rather than select()/fd_set — select's fd_set is a fixed 1024-bit
    /// bitmap, and indexing it with a file descriptor >= 1024 (which a long-running
    /// process with many open fds can hit) is out of bounds and crashes.
    private static func connects(to info: addrinfo, timeout: TimeInterval) -> Bool {
        let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = connect(fd, info.ai_addr, info.ai_addrlen)
        if rc == 0 { return true }                 // connected immediately
        if errno != EINPROGRESS { return false }

        // Wait for the connect to complete (socket becomes writable) up to timeout.
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = Int32(timeout * 1000)
        let ready = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, ms) }
        guard ready > 0, (pfd.revents & Int16(POLLOUT)) != 0 else { return false }

        // Confirm there was no socket error on the completed connect.
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        return soError == 0
    }
}
