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
    private static func connects(to info: addrinfo, timeout: TimeInterval) -> Bool {
        let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = connect(fd, info.ai_addr, info.ai_addrlen)
        if rc == 0 { return true }                 // connected immediately
        if errno != EINPROGRESS { return false }

        // Wait for writability (connect completion) up to timeout.
        var writeSet = fd_set()
        fdZero(&writeSet)
        fdSet(fd, &writeSet)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        guard select(fd + 1, nil, &writeSet, nil, &tv) > 0 else { return false }

        // Confirm there was no socket error.
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        return soError == 0
    }
}

// fd_set helpers (Swift can't index the C bitfield directly).
private func fdZero(_ set: inout fd_set) {
    set.fds_bits = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    let mask = Int32(1 << bitOffset)
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            bits[intOffset] |= mask
        }
    }
}
