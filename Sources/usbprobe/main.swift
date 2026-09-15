import Foundation
import SonyCameraKit

// Dumps what a USB-connected Sony camera reports: device info, every property, and one liveview frame.
// Usage: swift run usbprobe [--frame /path/out.jpg] [--watch]

let args = CommandLine.arguments
func flag(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }

let devices = SonyUSBBackend.availableDevices()
print("PTP devices on USB: \(devices.count)")
for d in devices { print(String(format: "  %@  vid=0x%04X pid=0x%04X%@", d.name, d.vendorID, d.productID, d.isSony ? "  (Sony)" : "")) }
guard let dev = devices.first(where: \.isSony) ?? devices.first else {
    print("No PTP camera found. On the camera set USB Connection → PC Remote and reconnect.")
    exit(1)
}

let backend = SonyUSBBackend(device: dev)
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        let t0 = Date()
        let state = try await backend.connect()
        print(String(format: "Connected to %@ in %.2fs", await backend.displayName, Date().timeIntervalSince(t0)))
        print("\n== Properties (\(backend.allProperties().count))")
        for p in backend.allProperties() {
            let vals = (p.enumValues.isEmpty ? p.enumAllValues : p.enumValues)
            var line = String(format: "  0x%04X %-18@ type=%-6@ en=%d cur=%lld", p.code, SonyProp.name(p.code), "\(p.type)", p.isEnabled, p.current)
            switch p.code {
            case SonyProp.shutterSpeed: line += "  [\(SonyValue.shutter(p.current))]"
            case SonyProp.fNumber: line += "  [F\(SonyValue.fNumber(p.current))]"
            case SonyProp.iso: line += "  [ISO \(SonyValue.iso(p.current))]"
            case SonyProp.exposureBias: line += "  [EV \(SonyValue.ev(p.current).label)]"
            default: break
            }
            if p.formFlag == 1 { line += "  range \(p.rangeMin)…\(p.rangeMax) step \(p.rangeStep)" }
            if !vals.isEmpty { line += "  enum(\(vals.count))\(p.enumAllValues.isEmpty ? "" : "+all(\(p.enumAllValues.count))"): \(vals.prefix(12).map(String.init).joined(separator: ","))\(vals.count > 12 ? ",…" : "")" }
            print(line)
        }
        print("\n== Derived HUD state")
        print("  shutter \(state.shutterSpeed ?? "-")  iris \(state.fNumber ?? "-")  iso \(state.iso ?? "-")  ev \(state.exposureCompensation?.label ?? "-")  wb \(state.whiteBalanceMode ?? "-")  focus \(state.focusMode ?? "-")  mode \(state.exposureMode ?? "-")  battery \(state.battery.map { "\($0.levelNumer)%" } ?? "-")")
        print("  settable: \(state.availableAPIs.sorted().joined(separator: " "))")

        print("\n== Liveview")
        var got: Data?
        let t1 = Date()
        for _ in 0 ..< 30 {
            if let f = try await backend.fetchLiveviewFrame() { got = f; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let got {
            print(String(format: "  frame: %d bytes after %.2fs", got.count, Date().timeIntervalSince(t1)))
            let out = flag("--frame") ?? NSTemporaryDirectory() + "usbprobe-frame.jpg"
            try got.write(to: URL(fileURLWithPath: out))
            print("  saved \(out)")
            // measure frame rate over 2 seconds
            var n = 0, polls = 0; let t2 = Date()
            while Date().timeIntervalSince(t2) < 3 { polls += 1; if try await backend.fetchLiveviewFrame() != nil { n += 1 } }
            print(String(format: "  ~%.1f fps (%d polls in 3s, tight loop)", Double(n) / 3, polls))
        } else {
            print("  no liveview frame (camera may need liveview enabled / a moment after connecting)")
        }

        if args.contains("--af") {
            print("\n== Half-press AF (hold 2s, watching FocusFound 0xD213)")
            try await backend.button(SonyProp.autoFocusButton, down: true)
            for i in 0 ..< 10 {
                try await Task.sleep(for: .milliseconds(200))
                print("  t=\(Double(i + 1) * 0.2)s focusFound=\(await backend.rawValue(SonyProp.focusFound) ?? -1)")
            }
            try await backend.button(SonyProp.autoFocusButton, down: false)
            try await Task.sleep(for: .milliseconds(300))
            print("  released: focusFound=\(await backend.rawValue(SonyProp.focusFound) ?? -1)")
        }
        if args.contains("--shoot") {
            print("\n== Take picture (watching ObjectInMemory 0xD215 and 0xD2C2)")
            try await backend.button(SonyProp.autoFocusButton, down: true)
            try await Task.sleep(for: .milliseconds(800))
            try await backend.button(SonyProp.captureButton, down: true)
            for i in 0 ..< 15 {
                try await Task.sleep(for: .milliseconds(200))
                print("  t=\(Double(i + 1) * 0.2)s objectInMemory=\(await backend.rawValue(SonyProp.objectInMemory) ?? -1) capture=\(await backend.rawValue(SonyProp.captureButton) ?? -1) focus=\(await backend.rawValue(SonyProp.focusFound) ?? -1)")
                if i == 1 { try await backend.button(SonyProp.captureButton, down: false); try await backend.button(SonyProp.autoFocusButton, down: false); print("  (released)") }
            }
            print("  files in \(backend.saveDirectory.path): \((try? FileManager.default.contentsOfDirectory(atPath: backend.saveDirectory.path)) ?? [])")
        }
        if let spec = flag("--set") {
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                print("\n== Set \(parts[0]) = \(parts[1])")
                let t0 = Date()
                do {
                    switch parts[0] {
                    case "shutter": try await backend.setShutterSpeed(parts[1])
                    case "iris": try await backend.setFNumber(parts[1])
                    case "iso": try await backend.setISO(parts[1])
                    case "ev": try await backend.setExposureCompensation(index: Int(parts[1]) ?? 0)
                    case "focus": try await backend.setFocusMode(parts[1])
                    case "wb": try await backend.setWhiteBalance(mode: parts[1], colorTemp: nil)
                    default: print("  unknown key (shutter|iris|iso|ev|focus|wb)")
                    }
                    print(String(format: "  ok in %.2fs", Date().timeIntervalSince(t0)))
                } catch { print("  FAILED: \(error.localizedDescription)") }
                let s2 = try await backend.stateUpdates().first { _ in true }
                print("  now: shutter \(s2?.shutterSpeed ?? "-")  iris \(s2?.fNumber ?? "-")  iso \(s2?.iso ?? "-")  ev \(s2?.exposureCompensation?.label ?? "-")  wb \(s2?.whiteBalanceMode ?? "-")  focus \(s2?.focusMode ?? "-")")
            }
        }
        if args.contains("--stop") {
            print("\n== Stop recording"); do { try await backend.stopMovie(); print("  stopped, recState=\(await backend.rawValue(SonyProp.movieRecordingState) ?? -1)") } catch { print("  \(error.localizedDescription)") }
        }
        if args.contains("--rec") {
            print("\n== Movie record: start, watch 0xD21D for 3s, stop")
            try await backend.startMovie()
            for i in 0 ..< 6 { try await Task.sleep(for: .milliseconds(500)); print("  t=\(Double(i + 1) * 0.5)s recState=\(await backend.rawValue(SonyProp.movieRecordingState) ?? -1)") }
            try await backend.stopMovie()
            for i in 0 ..< 4 { try await Task.sleep(for: .milliseconds(500)); print("  stopped t=\(Double(i + 1) * 0.5)s recState=\(await backend.rawValue(SonyProp.movieRecordingState) ?? -1)") }
        }
        if args.contains("--settings") {
            print("\n== Settings menu")
            for st in await backend.settings() { print("  \(st.id) \(st.name) [\(st.group)] = \(st.current)  settable=\(st.settable)  (\(st.candidates.count) options: \(st.candidates.prefix(6).joined(separator: ", "))\(st.candidates.count > 6 ? ", …" : ""))") }
        }
        if let spec = flag("--setting") {
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, let st = await backend.settings().first(where: { $0.name == parts[0] || $0.id == parts[0] }) {
                print("\n== Set \(st.name) = \(parts[1])")
                do { try await backend.setSetting(id: st.id, value: parts[1]); try await Task.sleep(for: .milliseconds(500))
                     print("  now: \(await backend.settings().first { $0.id == st.id }?.current ?? "?")") }
                catch { print("  FAILED: \(error.localizedDescription)") }
            } else { print("unknown setting \(spec)") }
        }
        if args.contains("--watch") {
            print("\n== Watching property changes (turn dials on the camera; Ctrl-C to stop)")
            var last: [UInt16: Int64] = [:]
            for try await s in backend.stateUpdates() {
                for p in backend.allProperties() where last[p.code] != p.current {
                    if last[p.code] != nil { print(String(format: "  0x%04X %@ -> %lld", p.code, SonyProp.name(p.code), p.current)) }
                    last[p.code] = p.current
                }
                _ = s
            }
        }
        await backend.disconnect()
        semaphore.signal()
    } catch {
        print("ERROR: \(error.localizedDescription)")
        await backend.disconnect()
        exit(2)
    }
}
semaphore.wait()
