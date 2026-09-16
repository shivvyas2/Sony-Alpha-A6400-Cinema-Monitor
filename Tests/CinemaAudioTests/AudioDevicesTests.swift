#if os(macOS)
import XCTest
import CoreAudio
@testable import CinemaAudio

final class AudioDevicesTests: XCTestCase {
    func testInputsAreWellFormed() {
        for d in AudioDevices.inputs() {
            XCTAssertFalse(d.name.isEmpty)
            XCTAssertFalse(d.uid.isEmpty)
            XCTAssertGreaterThan(d.inputChannelNames.count, 0)
            XCTAssertGreaterThan(d.nominalSampleRate, 0)
            XCTAssertEqual(AudioDevices.device(uid: d.uid)?.id, d.id)
        }
    }

    func testShortName() {
        let d = AudioDevice(id: 1, uid: "u", name: "Scarlett 2i2 USB", inputChannelNames: ["1"], nominalSampleRate: 48000, supportedSampleRates: [48000])
        XCTAssertEqual(d.shortName, "SCARLETT 2I2")
        XCTAssertEqual(AudioDevice(id: 1, uid: "u", name: "MacBook Pro Microphone", inputChannelNames: ["1"], nominalSampleRate: 48000, supportedSampleRates: []).shortName, "MACBOOK PRO")
    }

    func testSettingRateOnBogusDeviceThrows() {
        XCTAssertThrowsError(try AudioDevices.setNominalSampleRate(48000, on: AudioDeviceID(0xFFFF_FFF0)))
    }

    func testChangesStreamCanBeCancelled() async {
        let task = Task { for await _ in AudioDevices.changes() { break } }
        task.cancel()
        _ = await task.result
    }
}
#endif
