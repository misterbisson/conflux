import Darwin

/// Whether a TCP connection to loopback came from inside this process.
///
/// The host service listens on 127.0.0.1 so apple-iroh can carry peers'
/// streams to it, and apple-iroh opens those connections from this process.
/// Any other process on the Mac can reach loopback too, and the host service
/// has no token, so it accepts a connection only when this process holds the
/// socket at the other end.
enum ProcessSockets {
    /// True if this process has a TCP socket bound to `port` on its side.
    static func ownsLocalPort(_ port: UInt16) -> Bool {
        let pid = getpid()
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for a few more, in case descriptors open between the calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return false }
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let local = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            if UInt16(bigEndian: local) == port { return true }
        }
        return false
    }
}
