import Foundation

/// Sony camera in USB "PC Remote" mode, driven with PTP + Sony's SDIO vendor extension.
public final class SonyUSBBackend: CameraBackend, @unchecked Sendable {
    public let kind: CameraTransportKind = .usb
    public let usbDevice: USBCameraDevice
    private var device: PTPDevice?
    private var model = ""
    private let stateBox = StateBox()
    private let propsLock = NSLock()
    private var props: [UInt16: SonyPropDesc] = [:]
    private var recording = false
    public var saveDirectory: URL
    let captures = CaptureBroadcaster()
    public func captureEvents() -> AsyncStream<CaptureEvent> { captures.stream() }

    public var displayName: String { model.isEmpty ? usbDevice.name : model }

    public init(device: USBCameraDevice, saveDirectory: URL? = nil) {
        self.usbDevice = device
        self.saveDirectory = saveDirectory
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("CinemaHUD")
    }

    /// Cameras currently plugged in that expose a PTP interface.
    public static func availableDevices() -> [USBCameraDevice] {
        PTPUSBTransport.stillImageInterfaces().map(\.info)
    }

    // MARK: Connection

    public func connect() async throws -> CameraState {
        guard let entry = PTPUSBTransport.stillImageInterfaces().first(where: { $0.info.id == usbDevice.id }) else {
            throw USBTransportError("Camera not found on USB. Set the camera's USB Connection to “PC Remote” and reconnect the cable.")
        }
        let transport = try PTPUSBTransport(service: entry.service, name: usbDevice.name)
        transport.drain()
        let dev = PTPDevice(transport: transport)
        device = dev
        try await dev.openSession()
        if let info = try? await dev.getDeviceInfo() { model = info.model }
        try await sonyHandshake(dev)
        let s = try await refreshState()
        return s
    }

    /// The SDIO connect sequence Sony cameras require before any vendor operation works.
    private func sonyHandshake(_ dev: PTPDevice) async throws {
        do {
            try await dev.transaction(PTP.Op.sonySDIOConnect, params: [1, 0, 0])
            try await dev.transaction(PTP.Op.sonySDIOConnect, params: [2, 0, 0])
            _ = try await dev.transaction(PTP.Op.sonyGetSDIOExtDeviceInfo, params: [0xC8])
            try await dev.transaction(PTP.Op.sonySDIOConnect, params: [3, 0, 0])
        } catch let e as PTPError where e.code == PTP.Response.operationNotSupported {
            throw USBTransportError("The camera is not in PC Remote mode (USB Connection → PC Remote), or it is in MTP/Mass Storage mode.")
        }
        // Give the PC priority over the body's own controls (ignored by cameras that lack it).
        _ = try? await dev.transaction(PTP.Op.sonySetControlDeviceA, params: [UInt32(SonyProp.priorityMode)], dataOut: .ptpValue(1, as: .int8))
        // Some bodies need a moment before property data is populated.
        for _ in 0 ..< 10 {
            if let d = try? await dev.transaction(PTP.Op.sonyGetAllDevicePropData), d.data.count > 8 { return }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    public func disconnect() async {
        await device?.closeSession()
        device = nil
    }

    // MARK: Properties → state

    @discardableResult
    private func refreshState() async throws -> CameraState {
        guard let dev = device else { throw USBTransportError("not connected") }
        let r = try await dev.transaction(PTP.Op.sonyGetAllDevicePropData)
        let list = try SonyPropDesc.parseAll(r.data)
        let snapshot = propsLock.withLock {
            for d in list { props[d.code] = d }
            return props
        }
        let s = Self.makeState(from: snapshot, recording: recording)
        stateBox.set(s)
        return s
    }

    private func prop(_ code: UInt16) -> SonyPropDesc? { propsLock.withLock { props[code] } }

    /// All raw property descriptors (for diagnostics).
    public func allProperties() -> [SonyPropDesc] {
        propsLock.withLock { props.values.sorted { $0.code < $1.code } }
    }

    static func makeState(from p: [UInt16: SonyPropDesc], recording: Bool) -> CameraState {
        var s = CameraState()
        var apis: Set<String> = ["actHalfPressShutter", "actTakePicture", "startMovieRec", "stopMovieRec"]
        func candidates(_ d: SonyPropDesc?) -> [Int64] {
            guard let d else { return [] }
            return d.enumValues.isEmpty ? d.enumAllValues : d.enumValues
        }
        if let d = p[SonyProp.shutterSpeed] {
            s.shutterSpeed = SonyValue.shutter(d.current)
            var list = candidates(d).isEmpty ? SonyValue.fullShutterTable : candidates(d)
            if !list.contains(d.current), SonyValue.shutterSeconds(d.current) != nil {
                list.append(d.current)
                list.sort { (SonyValue.shutterSeconds($0) ?? 0) > (SonyValue.shutterSeconds($1) ?? 0) }
            }
            s.shutterSpeedCandidates = list.map(SonyValue.shutter)
            if d.settable && d.current != 0xFFFF_FFFF { apis.insert("setShutterSpeed") }
        }
        if let d = p[SonyProp.fNumber] {
            s.fNumber = SonyValue.fNumber(d.current)
            var list = candidates(d).isEmpty ? SonyValue.fNumberTable : candidates(d)
            if !list.contains(d.current), d.current > 0 { list.append(d.current); list.sort() }
            s.fNumberCandidates = list.map(SonyValue.fNumber)
            if d.settable && d.current != 0 { apis.insert("setFNumber") }
        }
        if let d = p[SonyProp.iso] {
            s.iso = SonyValue.iso(d.current)
            s.isoCandidates = candidates(d).map(SonyValue.iso)
            if d.settable { apis.insert("setIsoSpeedRate") }
        }
        if let d = p[SonyProp.exposureBias] {
            s.exposureCompensation = SonyValue.ev(d.current)
            if let lo = candidates(d).min(), let hi = candidates(d).max() {
                s.exposureCompensation?.minIndex = SonyValue.ev(lo).index
                s.exposureCompensation?.maxIndex = SonyValue.ev(hi).index
            }
            if d.settable { apis.insert("setExposureCompensation") }
        }
        if let d = p[SonyProp.whiteBalance] {
            s.whiteBalanceMode = SonyValue.label(d.current, in: SonyValue.whiteBalances)
            s.whiteBalanceCandidates = candidates(d).map { SonyValue.label($0, in: SonyValue.whiteBalances) }
            if d.settable { apis.insert("setWhiteBalance") }
        }
        if let d = p[SonyProp.colorTemperature] { s.colorTemperature = Int(d.current) }
        if let d = p[SonyProp.focusMode] {
            s.focusMode = SonyValue.label(d.current, in: SonyValue.focusModes)
            s.focusModeCandidates = candidates(d).map { SonyValue.label($0, in: SonyValue.focusModes) }
            // Sony marks focus mode "display only" in the old protocol even though it is settable.
            if d.isEnabled != 0 { apis.insert("setFocusMode") }
        }
        if let d = p[SonyProp.exposureProgramMode] {
            s.exposureMode = SonyValue.label(d.current, in: SonyValue.exposurePrograms)
            s.exposureModeCandidates = candidates(d).map { SonyValue.label($0, in: SonyValue.exposurePrograms) }
            s.shootMode = d.current >= 0x8050 ? "movie" : "still"
            if d.settable { apis.insert("setExposureMode") }
        }
        if let d = p[SonyProp.focusFound] {
            switch d.current {
            case 2: s.focusStatus = "Focused"
            case 3: s.focusStatus = "Failed"
            default: s.focusStatus = "Not Focusing"
            }
        }
        if let d = p[SonyProp.zoom], d.current > 0 { s.focalLengthMM = Double(d.current) / 1_000_000 }
        if let d = p[SonyProp.ccFilter] { s.ccShift = Int(d.current) - 192 }
        if let d = p[SonyProp.abFilter] { s.abShift = Int(d.current) - 192 }
        if let d = p[SonyProp.batteryLevel] {
            s.battery = BatteryInfo(status: "Active", additionalStatus: "", levelNumer: Int(d.current), levelDenom: 100)
        }
        s.liveviewStatus = true
        let rec = p[SonyProp.movieRecordingState].map { $0.current != 0 } ?? recording
        s.cameraStatus = rec ? "MovieRecording" : "IDLE"
        s.availableAPIs = apis
        return s
    }

    public func stateUpdates() -> AsyncThrowingStream<CameraState, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                var last = stateBox.get()
                var failures = 0
                var recStart: Date?
                while !Task.isCancelled {
                    do {
                        var s = try await refreshState()
                        if s.isRecording { if recStart == nil { recStart = Date() }; s.recordingTimeSeconds = Int(Date().timeIntervalSince(recStart!)) }
                        else { recStart = nil }
                        if s != last { last = s; cont.yield(s) }
                        failures = 0
                    } catch {
                        failures += 1
                        if failures > 8 { cont.finish(throwing: error); return }
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Liveview

    public func liveviewFrames() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { cont in
            let task = Task {
                var failures = 0
                while !Task.isCancelled {
                    do {
                        if let jpeg = try await fetchLiveviewFrame() { cont.yield(jpeg); failures = 0 }
                        else { try await Task.sleep(for: .milliseconds(8)) }
                    } catch {
                        failures += 1
                        if failures > 40 { cont.finish(throwing: error); return }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Pulls one JPEG from the camera's liveview object, or nil if the camera has nothing yet.
    public func fetchLiveviewFrame() async throws -> Data? {
        guard let dev = device else { throw USBTransportError("not connected") }
        let r = try await dev.transaction(PTP.Op.getObject, params: [SonyProp.liveviewObjectHandle], timeout: 5,
                                          accept: [PTP.Response.deviceBusy, PTP.Response.invalidObjectHandle, PTP.Response.accessDenied])
        guard r.responseCode == PTP.Response.ok else { return nil }
        return Self.extractJPEG(r.data)
    }

    /// Sony wraps the liveview JPEG in a small header; find SOI…EOI.
    static func extractJPEG(_ d: Data) -> Data? {
        guard d.count > 4 else { return nil }
        let bytes = [UInt8](d)
        var start: Int?
        for i in 0 ..< bytes.count - 1 where bytes[i] == 0xFF && bytes[i + 1] == 0xD8 { start = i; break }
        guard let s = start else { return nil }
        var end = bytes.count
        var i = bytes.count - 1
        while i > s + 1 { if bytes[i - 1] == 0xFF && bytes[i] == 0xD9 { end = i + 1; break }; i -= 1 }
        return Data(bytes[s ..< end])
    }

    // MARK: Setting values

    private func controlA(_ code: UInt16, _ value: Int64, type: PTP.DataType) async throws {
        guard let dev = device else { throw USBTransportError("not connected") }
        try await dev.transaction(PTP.Op.sonySetControlDeviceA, params: [UInt32(code)], dataOut: .ptpValue(value, as: type))
    }

    private func controlB(_ code: UInt16, _ value: Int64, type: PTP.DataType) async throws {
        guard let dev = device else { throw USBTransportError("not connected") }
        try await dev.transaction(PTP.Op.sonySetControlDeviceB, params: [UInt32(code)], dataOut: .ptpValue(value, as: type))
    }

    /// Sets a property to `target`: absolute first, then Sony's relative "notch" stepping (old protocol).
    /// `metric` maps a raw value onto the dial's axis (increasing = +1 notch). Enum props use their index.
    private func setValue(_ code: UInt16, target: Int64, metric explicitMetric: ((Int64) -> Double?)? = nil) async throws {
        guard let d = prop(code) else { throw UnsupportedOperation(SonyProp.name(code)) }
        guard d.isEnabled != 0 else { throw UnsupportedOperation(SonyProp.name(code)) }
        if d.current == target { return }
        if (try? await controlA(code, target, type: d.type)) != nil {
            try await Task.sleep(for: .milliseconds(150))
            try await refreshState()
            if prop(code)?.current == target { return }
        }
        let order = d.enumValues.isEmpty ? d.enumAllValues : d.enumValues
        let metric: (Int64) -> Double? = explicitMetric ?? { v in order.firstIndex(of: v).map(Double.init) }
        guard let t = metric(target) else {
            throw PTPError(code: PTP.Response.invalidDevicePropValue, op: PTP.Op.sonySetControlDeviceA)
        }
        var lastDistance = Double.infinity
        for _ in 0 ..< 64 {
            guard let cur = prop(code)?.current, let m = metric(cur) else { break }
            if cur == target || m == t { return }
            let distance = abs(t - m)
            if distance >= lastDistance { return }      // not getting closer: target unavailable, stay at nearest
            lastDistance = distance
            let step: Int64 = t > m ? 1 : -1
            try await controlB(code, step, type: .uint8)   // 0x01 = +1 notch, 0xFF = -1 notch
            var changed = false
            for _ in 0 ..< 12 {
                try await Task.sleep(for: .milliseconds(120))
                try await refreshState()
                if let now = prop(code)?.current, now != cur { changed = true; break }
            }
            if !changed { throw USBTransportError("Camera did not accept \(SonyProp.name(code)) change (end of range or locked by the mode dial)") }
            var settled = prop(code)?.current
            for _ in 0 ..< 5 {
                try await Task.sleep(for: .milliseconds(150))
                try await refreshState()
                let again = prop(code)?.current
                if again == settled { break }
                settled = again
            }
            // Overshot past the target: the exact value is not on this lens/mode. Step back if that is closer.
            if let now = prop(code)?.current, let m2 = metric(now), (t - m2).sign != (t - m).sign, m2 != t {
                if abs(t - m2) > abs(t - m) {
                    try await controlB(code, -step, type: .uint8)
                    try await Task.sleep(for: .milliseconds(400))
                    try await refreshState()
                }
                return
            }
        }
    }

    private func candidateValue(_ code: UInt16, matching label: String, format: (Int64) -> String) -> Int64? {
        guard let d = prop(code) else { return nil }
        let list = d.enumValues.isEmpty ? d.enumAllValues : d.enumValues
        return list.first { format($0) == label }
    }

    public func setShutterSpeed(_ v: String) async throws {
        guard let val = SonyValue.fullShutterTable.first(where: { SonyValue.shutter($0) == v }) else { throw UnsupportedOperation("shutter \(v)") }
        // +1 notch = faster shutter, so the axis is -log(exposure time).
        try await setValue(SonyProp.shutterSpeed, target: val) { SonyValue.shutterSeconds($0).map { -log2($0) } }
    }
    public func setFNumber(_ v: String) async throws {
        guard let val = SonyValue.fNumberTable.first(where: { SonyValue.fNumber($0) == v }) else { throw UnsupportedOperation("iris \(v)") }
        try await setValue(SonyProp.fNumber, target: val) { $0 > 0 ? log2(Double($0)) : nil }
    }
    public func setISO(_ v: String) async throws {
        guard let val = candidateValue(SonyProp.iso, matching: v, format: SonyValue.iso) else { throw UnsupportedOperation("ISO \(v)") }
        try await setValue(SonyProp.iso, target: val)
    }
    public func setWhiteBalance(mode: String, colorTemp: Int?) async throws {
        guard let val = SonyValue.value(for: mode, in: SonyValue.whiteBalances) else { throw UnsupportedOperation("WB \(mode)") }
        try await setValue(SonyProp.whiteBalance, target: val)
        if let k = colorTemp, prop(SonyProp.colorTemperature)?.settable == true {
            try await setValue(SonyProp.colorTemperature, target: Int64(k))
        }
    }
    public func setExposureCompensation(index: Int) async throws {
        try await setValue(SonyProp.exposureBias, target: SonyValue.evValue(index: index))
    }
    public func setFocusMode(_ v: String) async throws {
        guard let val = SonyValue.value(for: v, in: SonyValue.focusModes) else { throw UnsupportedOperation("focus \(v)") }
        try await setValue(SonyProp.focusMode, target: val)
    }
    public func setExposureMode(_ v: String) async throws {
        guard let val = SonyValue.value(for: v, in: SonyValue.exposurePrograms) else { throw UnsupportedOperation("mode \(v)") }
        try await setValue(SonyProp.exposureProgramMode, target: val)
    }
    public func setShootMode(_ v: String) async throws { throw UnsupportedOperation("Shoot mode (use the mode dial)") }

    // MARK: Generic settings menu

    public func settings() async -> [CameraSetting] {
        SonyTables.menu.compactMap { e in
            guard let d = prop(e.code) else { return nil }
            let list = d.enumValues.isEmpty ? d.enumAllValues : d.enumValues
            return CameraSetting(id: String(format: "0x%04X", e.code), name: e.name, group: e.group,
                                 current: SonyTables.name(d.current, in: e.values),
                                 candidates: list.map { SonyTables.name($0, in: e.values) },
                                 settable: d.isEnabled == 1 || (d.isEnabled == 2 && e.code == 0x500B))
        }
    }

    public func setSetting(id: String, value: String) async throws {
        guard let code = UInt16(id.dropFirst(2), radix: 16), let e = SonyTables.menu.first(where: { $0.code == code }),
              let d = prop(code) else { throw UnsupportedOperation(id) }
        let list = d.enumValues.isEmpty ? d.enumAllValues : d.enumValues
        guard let target = list.first(where: { SonyTables.name($0, in: e.values) == value }) else { throw UnsupportedOperation("\(e.name) \(value)") }
        try await setValue(code, target: target)
    }

    public func focusDrive(steps: Int) async throws {
        guard prop(SonyProp.nearFar) != nil else { throw UnsupportedOperation("Focus drive") }
        try await controlB(SonyProp.nearFar, Int64(max(-7, min(7, steps))), type: .int16)
    }

    public func press(_ button: CameraButton) async throws {
        let code: UInt16
        switch button {
        case .aeLock: code = SonyProp.aelButton
        case .feLock: code = SonyProp.felButton
        case .oneShot: code = SonyProp.oneShotButton
        }
        try await press(code, holdMillis: 150)
    }

    // MARK: Buttons

    /// Low-level button access (down = true presses, false releases). Used by diagnostics.
    public func button(_ code: UInt16, down: Bool) async throws {
        try await controlB(code, down ? 2 : 1, type: .uint16)
    }

    /// Re-reads all properties and returns the current raw value of one (diagnostics).
    public func rawValue(_ code: UInt16) async -> Int64? {
        try? await refreshState()
        return prop(code)?.current
    }

    private func press(_ button: UInt16, holdMillis: Int) async throws {
        try await controlB(button, 2, type: .uint16)
        try await Task.sleep(for: .milliseconds(holdMillis))
        try await controlB(button, 1, type: .uint16)
    }

    public func autofocus() async throws {
        try await press(SonyProp.autoFocusButton, holdMillis: 1200)
    }

    public func takePicture() async throws {
        try await controlB(SonyProp.autoFocusButton, 2, type: .uint16)
        // wait briefly for focus confirmation
        for _ in 0 ..< 15 {
            try await Task.sleep(for: .milliseconds(100))
            try? await refreshState()
            if let f = prop(SonyProp.focusFound)?.current, f == 2 || f == 3 { break }
        }
        try await controlB(SonyProp.captureButton, 2, type: .uint16)
        try await Task.sleep(for: .milliseconds(80))
        try await controlB(SonyProp.captureButton, 1, type: .uint16)
        try await controlB(SonyProp.autoFocusButton, 1, type: .uint16)
        Task { await self.downloadCapturedImages() }
    }

    /// When the camera is set to save stills to the PC, they wait in memory until fetched.
    private func downloadCapturedImages() async {
        guard let dev = device else { return }
        for _ in 0 ..< 60 {
            try? await Task.sleep(for: .milliseconds(200))
            try? await refreshState()
            guard let flag = prop(SonyProp.objectInMemory)?.current, flag >= 0x8000 else { continue }
            guard let info = try? await dev.transaction(PTP.Op.getObjectInfo, params: [SonyProp.capturedImageHandle]),
                  let obj = try? await dev.transaction(PTP.Op.getObject, params: [SonyProp.capturedImageHandle], timeout: 30) else { return }
            var rd = PTPReader(info.data)
            // ObjectInfo: StorageID u32, ObjectFormat u16, ProtectionStatus u16, ObjectCompressedSize u32, ... filename string at a known position
            let filename: String = {
                guard (try? rd.skip(52)) != nil, let name = try? rd.string(), !name.isEmpty else { return "capture-\(Int(Date().timeIntervalSince1970)).jpg" }
                return name
            }()
            try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
            try? obj.data.write(to: saveDirectory.appendingPathComponent(filename))
            return
        }
    }

    // 0xD2C8: 2 = start recording, 1 = stop. 0xD21D reflects the state, with a ~2 s lag on stop
    // while the camera finalizes the clip.
    public func startMovie() async throws { try await setMovie(recording: true) }
    public func stopMovie() async throws { try await setMovie(recording: false) }

    private func setMovie(recording want: Bool) async throws {
        try await controlB(SonyProp.movieButton, want ? 2 : 1, type: .uint16)
        recording = want
        for _ in 0 ..< 30 {
            try await Task.sleep(for: .milliseconds(200))
            try await refreshState()
            if let st = prop(SonyProp.movieRecordingState)?.current, (st != 0) == want { return }
        }
        throw USBTransportError(want ? "Camera did not start recording" : "Camera did not stop recording")
    }
    public func touchAF(x: Double, y: Double) async throws { throw UnsupportedOperation("Touch AF") }
    public func cancelTouchAF() async throws {}
}
