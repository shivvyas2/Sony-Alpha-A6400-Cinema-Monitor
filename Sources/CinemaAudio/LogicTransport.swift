#if os(macOS)
import CoreMIDI
import Foundation

/// A virtual MIDI source Logic can chase: MIDI Timecode at the project rate plus MMC record/stop.
public final class LogicTransport {
    public enum Error: Swift.Error, LocalizedError {
        case midi(OSStatus)
        public var errorDescription: String? {
            switch self { case .midi(let s): return "MIDI error (\(s))" }
        }
    }

    public private(set) var isRunning = false
    public private(set) var rate: MTCRate?

    private let send: ([UInt8]) -> Void
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "CinemaHUD.mtc", qos: .userInteractive)

    public init(sourceName: String = "CinemaHUD", send: (([UInt8]) -> Void)? = nil) throws {
        if let send { self.send = send; return }
        var client = MIDIClientRef(), source = MIDIEndpointRef()
        var status = MIDIClientCreateWithBlock(sourceName as CFString, &client) { _ in }
        guard status == noErr else { throw Error.midi(status) }
        status = MIDISourceCreate(client, sourceName as CFString, &source)
        guard status == noErr else { MIDIClientDispose(client); throw Error.midi(status) }
        self.client = client; self.source = source
        self.send = { bytes in
            var list = MIDIPacketList()
            var packet = MIDIPacketListInit(&list)
            packet = MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)
            MIDIReceived(source, &list)
        }
    }

    deinit {
        stopTimecode()
        timerQueue.sync {}   // drain any queued MMC sends before disposing
        if source != 0 { MIDIEndpointDispose(source) }
        if client != 0 { MIDIClientDispose(client) }
    }

    public func startTimecode(rate: MTCRate, clock: @escaping () -> Date) {
        stopTimecode()
        self.rate = rate
        let sequencer = MTCSequencer(rate: rate, clock: clock)
        let interval = 1.0 / (4.0 * Double(rate.framesPerSecond))
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(200))
        t.setEventHandler { [send] in send(sequencer.next()) }
        t.resume()
        timer = t
        isRunning = true
    }

    public func stopTimecode() {
        dispatchPrecondition(condition: .notOnQueue(timerQueue))
        timer?.cancel(); timer = nil
        isRunning = false
        timerQueue.sync {}   // let any in-flight tick finish before we return
    }

    public func recordStrobe() { timerQueue.sync { [send] in send(MIDIMessages.mmcRecordStrobe) } }
    public func stop() { timerQueue.sync { [send] in send(MIDIMessages.mmcStop) } }
    public func play() { timerQueue.sync { [send] in send(MIDIMessages.mmcPlay) } }
}
#endif
