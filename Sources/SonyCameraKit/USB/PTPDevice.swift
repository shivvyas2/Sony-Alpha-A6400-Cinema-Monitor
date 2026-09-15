import Foundation

public struct PTPResult: Sendable {
    public let responseCode: UInt16
    public let responseParams: [UInt32]
    public let data: Data
}

/// Serializes PTP transactions over one USB transport.
actor PTPDevice {
    private let transport: PTPUSBTransport
    private var transactionID: UInt32 = 0
    private(set) var sessionOpen = false
    let name: String

    init(transport: PTPUSBTransport) {
        self.transport = transport
        self.name = transport.name
    }

    /// Runs a full transaction. Throws `PTPError` unless the response is OK (or listed in `accept`).
    @discardableResult
    func transaction(_ op: UInt16, params: [UInt32] = [], dataOut: Data? = nil,
                     timeout: TimeInterval = 5, accept: Set<UInt16> = []) throws -> PTPResult {
        transactionID &+= 1
        let tid = transactionID
        try transport.write(PTP.Container(type: .command, code: op, transactionID: tid, params: params).encoded, timeout: timeout)
        if let dataOut {
            try transport.write(PTP.Container(type: .data, code: op, transactionID: tid, payload: dataOut).encoded, timeout: timeout)
        }
        var data = Data()
        var response: PTP.Container?
        while response == nil {
            let c = try readContainer(timeout: timeout)
            switch c.type {
            case .data: data = c.payload
            case .response: response = c
            case .event: continue
            case .command: throw USBTransportError("unexpected command container from device")
            }
        }
        let r = response!
        if ProcessInfo.processInfo.environment["PTP_DEBUG"] == "1" {
            let out = dataOut.map { " data=" + $0.prefix(16).map { String(format: "%02x", $0) }.joined() } ?? ""
            print(String(format: "ptp> op=0x%04X params=%@%@ -> resp=0x%04X rparams=%@ data=%d bytes", op, params.map { String(format: "0x%X", $0) }.joined(separator: ","), out, r.code, r.params.map { String(format: "0x%X", $0) }.joined(separator: ","), data.count))
        }
        guard r.code == PTP.Response.ok || accept.contains(r.code) else {
            if r.code == PTP.Response.deviceBusy { transport.clearStall() }
            throw PTPError(code: r.code, op: op)
        }
        return PTPResult(responseCode: r.code, responseParams: r.params, data: data)
    }

    private func readContainer(timeout: TimeInterval) throws -> PTP.Container {
        var buf = try transport.read(max: 1 << 20, timeout: timeout)
        guard let total = PTP.Container.declaredLength(buf), total >= 12 else { throw USBTransportError("short PTP container") }
        while buf.count < total {
            let more = try transport.read(max: max(1 << 16, total - buf.count), timeout: timeout)
            if more.isEmpty { break }
            buf.append(more)
        }
        guard let c = PTP.Container.decode(buf) else { throw USBTransportError("bad PTP container") }
        return c
    }

    func openSession() throws {
        do {
            try transaction(PTP.Op.openSession, params: [1])
        } catch let e as PTPError where e.code == PTP.Response.sessionAlreadyOpen {
            // fine — reuse
        }
        sessionOpen = true
    }

    func closeSession() {
        if sessionOpen { _ = try? transaction(PTP.Op.closeSession, timeout: 2) }
        sessionOpen = false
        transport.close()
    }

    struct DeviceInfo: Sendable {
        var manufacturer = "", model = "", version = "", serial = ""
        var vendorExtensionDesc = ""
        var operations: [UInt16] = [], properties: [UInt16] = []
    }

    func getDeviceInfo() throws -> DeviceInfo {
        let r = try transaction(PTP.Op.getDeviceInfo)
        var rd = PTPReader(r.data)
        var info = DeviceInfo()
        _ = try rd.u16()               // StandardVersion
        _ = try rd.u32()               // VendorExtensionID
        _ = try rd.u16()               // VendorExtensionVersion
        info.vendorExtensionDesc = try rd.string()
        _ = try rd.u16()               // FunctionalMode
        info.operations = try rd.u16Array()
        _ = try rd.u16Array()          // events
        info.properties = try rd.u16Array()
        _ = try rd.u16Array()          // capture formats
        _ = try rd.u16Array()          // image formats
        info.manufacturer = try rd.string()
        info.model = try rd.string()
        info.version = try rd.string()
        info.serial = try rd.string()
        return info
    }
}
