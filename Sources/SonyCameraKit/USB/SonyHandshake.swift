import Foundation

/// The SDIO connect sequence Sony cameras require before any vendor operation works. Transport-agnostic so it is
/// testable with a closure.
enum SonyHandshake {
    static let v200: UInt32 = 0xC8      // every body so far, newer ones included, when asked for it
    static let v300: UInt32 = 0x12C     // 2020 and later

    /// Asks for protocol 2.00 (what the app's property tables follow) and only if the camera then reports no
    /// properties, for 3.00. Returns the version that answered, or nil when neither did.
    static func run(attempts: Int = 10, wait: Duration = .milliseconds(200),
                    transact: (UInt16, [UInt32]) async throws -> Data) async throws -> UInt32? {
        _ = try await transact(PTP.Op.sonySDIOConnect, [1, 0, 0])
        _ = try await transact(PTP.Op.sonySDIOConnect, [2, 0, 0])
        _ = try await transact(PTP.Op.sonyGetSDIOExtDeviceInfo, [v200])
        _ = try await transact(PTP.Op.sonySDIOConnect, [3, 0, 0])
        if try await ready(attempts, wait, transact) { return v200 }
        guard (try? await transact(PTP.Op.sonyGetSDIOExtDeviceInfo, [v300, 1])) != nil,
              (try? await transact(PTP.Op.sonySDIOConnect, [3, 0, 0])) != nil else { return nil }
        return try await ready(attempts, wait, transact) ? v300 : nil
    }

    /// Some bodies need a moment before property data is populated.
    private static func ready(_ attempts: Int, _ wait: Duration, _ transact: (UInt16, [UInt32]) async throws -> Data) async throws -> Bool {
        for _ in 0 ..< attempts {
            if let d = try? await transact(PTP.Op.sonyGetAllDevicePropData, []), d.count > 8 { return true }
            try await Task.sleep(for: wait)
        }
        return false
    }
}
