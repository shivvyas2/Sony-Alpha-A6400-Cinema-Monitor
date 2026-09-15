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
    public init(_ m: String) { message = m }
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
            let ns = error as NSError
            if ns.code == Int(kIOReturnExclusiveAccess) || ns.code == Int(kIOReturnNotPermitted) {
                throw USBTransportError("Another process holds the camera (usually macOS's Image Capture service). Quit Photos / Image Capture, unplug and replug the camera, then try again.")
            }
            throw USBTransportError("Could not open USB interface: \(ns.localizedDescription)")
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

    func clearStall() {
        try? bulkIn.clearStall()
        try? bulkOut.clearStall()
    }

    func close() {
        interface.destroy()
    }
}
