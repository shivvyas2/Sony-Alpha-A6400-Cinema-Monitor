#if canImport(IOUSBHost)
import Foundation
import IOKit
import IOUSBHost

public struct USBCameraDevice: Sendable, Identifiable, Equatable {
    public let id: UInt64          // IORegistry entry id
    public let vendorID: Int
    public let productID: Int
    public let name: String
    public var isSony: Bool { vendorID == 0x054C }
}

public struct USBTransportError: Error, LocalizedError, Sendable {
    public let message: String
    /// Set when the interface could not be opened because another process has it.
    public let heldBy: USBInterfaceHolder?
    public init(_ m: String, heldBy: USBInterfaceHolder? = nil) { message = m; self.heldBy = heldBy }
    public var errorDescription: String? { message }
}

/// Bulk-pipe transport for PTP over USB via IOUSBHost. Not thread-safe; `PTPDevice` serializes access.
final class PTPUSBTransport: @unchecked Sendable {
    private let interface: IOUSBHostInterface
    private let bulkIn: IOUSBHostPipe
    private let bulkOut: IOUSBHostPipe
    let maxPacketOut: Int
    let name: String

    /// Lists USB devices exposing a PTP "Still Image" interface (class 6, subclass 1, protocol 1).
    static func stillImageInterfaces() -> [(service: io_service_t, info: USBCameraDevice)] {
        let dict = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: nil, productID: nil, bcdDevice: nil, interfaceNumber: nil, configurationValue: nil,
            interfaceClass: 6, interfaceSubclass: 1, interfaceProtocol: 1, speed: nil, productIDArray: nil)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dict.takeRetainedValue(), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [(io_service_t, USBCameraDevice)] = []
        while case let s = IOIteratorNext(iterator), s != 0 {
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(s, &entryID)
            let vid = property(s, "idVendor") as? Int ?? 0
            let pid = property(s, "idProduct") as? Int ?? 0
            let product = property(s, "USB Product Name") as? String ?? property(s, "kUSBProductString") as? String ?? "PTP camera"
            out.append((s, USBCameraDevice(id: entryID, vendorID: vid, productID: pid, name: product)))
        }
        return out
    }

    /// Whoever has this interface open right now. IOUSBHost opens are exclusive, so a holder means
    /// our own open will fail (with a generic "internal error", not "exclusive access").
    static func holder(of service: io_service_t) -> USBInterfaceHolder? {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "IOUserClient") != 0,
                  let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue() as? String,
                  let holder = USBInterfaceHolder.parse(creator: creator) else { continue }
            return holder
        }
        return nil
    }

    /// Stops the Image Capture daemon so the interface can be opened. It ignores SIGTERM, and
    /// launchd brings it back within seconds, so the caller must open the interface immediately.
    static func release(_ holder: USBInterfaceHolder) -> Bool {
        guard holder.isSystemPTPDaemon else { return false }
        return kill(holder.pid, SIGKILL) == 0
    }

    private static func property(_ s: io_service_t, _ key: String) -> Any? {
        // Properties live on the parent device; search upwards.
        IORegistryEntrySearchCFProperty(s, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }

    init(service: io_service_t, name: String) throws {
        self.name = name
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            if let holder = Self.holder(of: service) {
                throw USBTransportError("Another app holds the camera (\(holder.name)). Quit it, then click Connect USB again.", heldBy: holder)
            }
            throw USBTransportError("Could not open USB interface: \((error as NSError).localizedDescription)")
        }
        // Walk endpoints to find the bulk in/out pipes.
        var inAddr: Int?, outAddr: Int?, outMax = 512
        let cfg = interface.configurationDescriptor
        let ifd = interface.interfaceDescriptor
        var ep: UnsafePointer<IOUSBEndpointDescriptor>? = nil
        while let next = IOUSBGetNextEndpointDescriptor(cfg, ifd, ep.map { UnsafeRawPointer($0).assumingMemoryBound(to: IOUSBDescriptorHeader.self) }) {
            ep = next
            let addr = Int(next.pointee.bEndpointAddress)
            let attrs = next.pointee.bmAttributes & 0x03
            if attrs == 2 {
                if addr & 0x80 != 0 { inAddr = addr } else { outAddr = addr; outMax = Int(next.pointee.wMaxPacketSize & 0x7FF) }
            }
        }
        guard let inAddr, let outAddr else { throw USBTransportError("PTP interface has no bulk endpoints") }
        bulkIn = try interface.copyPipe(withAddress: inAddr)
        bulkOut = try interface.copyPipe(withAddress: outAddr)
        maxPacketOut = outMax
    }

    func write(_ data: Data, timeout: TimeInterval) throws {
        let buf = NSMutableData(data: data)
        var n = 0
        try bulkOut.__sendIORequest(with: buf, bytesTransferred: &n, completionTimeout: timeout)
        if data.count % maxPacketOut == 0 {
            // Data phase ending on a packet boundary must be terminated with a zero-length packet.
            try bulkOut.__sendIORequest(with: nil, bytesTransferred: &n, completionTimeout: timeout)
        }
    }

    func read(max: Int, timeout: TimeInterval) throws -> Data {
        let buf = NSMutableData(length: max)!
        var n = 0
        try bulkIn.__sendIORequest(with: buf, bytesTransferred: &n, completionTimeout: timeout)
        return Data(bytes: buf.bytes, count: n)
    }

    /// Discards any bytes left over from an interrupted transaction (e.g. a previous process died mid-read).
    func drain() {
        clearStall()
        for _ in 0 ..< 8 {
            guard let d = try? read(max: 1 << 20, timeout: 0.15), !d.isEmpty else { break }
        }
    }

    func clearStall() {
        try? bulkIn.clearStall()
        try? bulkOut.clearStall()
    }

    func close() {
        interface.destroy()
    }
}

#endif
