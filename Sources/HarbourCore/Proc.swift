import Darwin
import Foundation

/// Thin wrappers over libproc and sysctl. Nothing here shells out: `lsof` and `ps`
/// cost hundreds of milliseconds per call, and Harbour refreshes every two seconds.
enum Proc {
    struct BSD: Sendable {
        let pid: pid_t
        let ppid: pid_t
        let pgid: pid_t
        let uid: uid_t
        let comm: String
        let start: Date
    }

    static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return pids.prefix(Int(max(n, 0))).filter { $0 > 0 }
    }

    static func bsd(_ pid: pid_t) -> BSD? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let start = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                         + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        return BSD(pid: pid, ppid: pid_t(info.pbi_ppid), pgid: pid_t(info.pbi_pgid),
                   uid: info.pbi_uid, comm: cString(info.pbi_comm), start: start)
    }

    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return string(buf)
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = cString(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// Physical footprint, the number Activity Monitor shows. RSS undercounts on macOS
    /// because of memory compression (vite read 11 MB RSS on 2026-10-20).
    static func footprint(_ pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }

    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }   // exec path
        while i < size, buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    static func listeners(_ pid: pid_t) -> [Socket] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }

        var out: [Socket] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
                var addr = ini.insi_laddr.ina_6
                out.append(Socket(port: port, family: .v6, address: ntop(AF_INET6, &addr, INET6_ADDRSTRLEN)))
            } else {
                var addr = ini.insi_laddr.ina_46.i46a_addr4
                out.append(Socket(port: port, family: .v4, address: ntop(AF_INET, &addr, INET_ADDRSTRLEN)))
            }
        }
        return out
    }

    private static func ntop<T>(_ family: Int32, _ addr: inout T, _ length: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(length))
        let ok = withUnsafeBytes(of: &addr) { inet_ntop(family, $0.baseAddress, &buf, socklen_t(length)) != nil }
        return ok ? string(buf) : "?"
    }

    private static func string(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
