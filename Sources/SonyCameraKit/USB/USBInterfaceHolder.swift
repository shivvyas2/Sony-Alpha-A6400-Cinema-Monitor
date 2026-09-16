import Foundation

/// The process that currently has a USB interface open, as the kernel records it on the
/// interface's user client (`IOUserClientCreator = "pid 905, ptpcamerad"`).
public struct USBInterfaceHolder: Equatable, Sendable {
    public let pid: Int32
    public let name: String

    public init(pid: Int32, name: String) { self.pid = pid; self.name = name }

    /// macOS's Image Capture daemon claims every PTP camera the moment it is plugged in, whether
    /// or not Photos or Image Capture is open. It is safe to stop: launchd restarts it on demand.
    public var isSystemPTPDaemon: Bool { name == "ptpcamerad" }

    public static func parse(creator: String) -> USBInterfaceHolder? {
        guard creator.hasPrefix("pid ") else { return nil }
        let rest = creator.dropFirst(4)
        guard let comma = rest.firstIndex(of: ",") else { return nil }
        guard let pid = Int32(rest[..<comma]), pid > 0 else { return nil }
        let name = rest[rest.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return USBInterfaceHolder(pid: pid, name: name)
    }
}
