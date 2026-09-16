#if os(macOS)
import CoreAudio
import Foundation

public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannelNames: [String]
    public let nominalSampleRate: Double
    public let supportedSampleRates: [Double]
    public init(id: AudioDeviceID, uid: String, name: String, inputChannelNames: [String], nominalSampleRate: Double, supportedSampleRates: [Double]) {
        self.id = id; self.uid = uid; self.name = name; self.inputChannelNames = inputChannelNames
        self.nominalSampleRate = nominalSampleRate; self.supportedSampleRates = supportedSampleRates
    }
    /// "SCARLETT 2I2" — what fits in the HUD strip.
    public var shortName: String { name.split(separator: " ").prefix(2).joined(separator: " ").uppercased() }
}

public enum AudioDevices {
    public enum Error: Swift.Error, LocalizedError {
        case osStatus(OSStatus)
        public var errorDescription: String? {
            switch self { case .osStatus(let s): return "Audio hardware error (\(s))" }
        }
    }

    public static func inputs() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard let ids: [AudioDeviceID] = array(AudioObjectID(kAudioObjectSystemObject), &addr) else { return [] }
        return ids.compactMap { device($0) }
    }

    public static func device(uid: String) -> AudioDevice? { inputs().first { $0.uid == uid } }

    static func device(_ id: AudioDeviceID) -> AudioDevice? {
        let channels = inputChannelCount(id)
        guard channels > 0 else { return nil }
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var ratesAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard let name: String = string(id, &nameAddr), let uid: String = string(id, &uidAddr) else { return nil }
        let rate: Double = scalar(id, &rateAddr) ?? 0
        let ranges: [AudioValueRange] = array(id, &ratesAddr) ?? []
        let rates = Set(ranges.flatMap { [$0.mMinimum, $0.mMaximum] }).sorted()
        let names = (1 ... channels).map { ch -> String in
            var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyElementName, mScope: kAudioObjectPropertyScopeInput, mElement: AudioObjectPropertyElement(ch))
            let n: String? = string(id, &a)
            return (n?.isEmpty == false) ? n! : "Ch \(ch)"
        }
        return AudioDevice(id: id, uid: uid, name: name, inputChannelNames: names, nominalSampleRate: rate, supportedSampleRates: rates)
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func setNominalSampleRate(_ rate: Double, on id: AudioDeviceID) throws {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = rate
        let status = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
        guard status == noErr else { throw Error.osStatus(status) }
    }

    /// Fires when devices are added or removed. Finishes when the consumer stops iterating.
    public static func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in continuation.yield(()) }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.global(qos: .utility), block)
            continuation.onTermination = { _ in
                var a = addr
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.global(qos: .utility), block)
            }
        }
    }

    // MARK: HAL helpers

    private static func scalar<T>(_ id: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> T? {
        var size = UInt32(MemoryLayout<T>.size)
        let p = UnsafeMutablePointer<T>.allocate(capacity: 1); defer { p.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, p) == noErr else { return nil }
        return p.pointee
    }
    private static func string(_ id: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> String? {
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }
    private static func array<T>(_ id: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> [T]? {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }   // an empty property (e.g. no supported sample rates listed) would otherwise force-unwrap a nil baseAddress below
        let count = Int(size) / MemoryLayout<T>.size
        var out = [T](unsafeUninitializedCapacity: count) { buf, n in
            n = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf.baseAddress!) == noErr ? count : 0
        }
        if out.count != count { out = [] }
        return out
    }
}
#endif
