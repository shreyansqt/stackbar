import Foundation
import Darwin

/// Minimal TCP connect check against 127.0.0.1:<port>.
/// Returns true if something accepts the connection within the timeout.
enum PortProbe {
    static func isOpen(port: Int, timeout: TimeInterval = 0.3) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Non-blocking connect so we can bound the wait.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult == 0 { return true } // connected immediately
        if errno != EINPROGRESS { return false }

        // Wait for writability (connect completion) up to timeout.
        var writeSet = fd_set()
        fdZero(&writeSet)
        fdSet(fd, &writeSet)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        let sel = select(fd + 1, nil, &writeSet, nil, &tv)
        guard sel > 0 else { return false }

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
