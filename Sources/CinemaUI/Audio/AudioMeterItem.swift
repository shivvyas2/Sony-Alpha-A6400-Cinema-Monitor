#if os(macOS)
import SwiftUI
import CinemaAudio

enum MeterScale {
    /// 0 at −60 dBFS (the meter floor), 1 at 0 dBFS.
    static func fraction(_ dB: Float) -> CGFloat {
        CGFloat(min(1, max(0, (dB - MeterMath.floor) / -MeterMath.floor)))
    }
}

/// Bottom-strip item: source, rate, one bar per channel, take dot, MTC tag. Hidden until armed.
struct AudioMeterItem: View {
    @Environment(AudioSessionController.self) private var audio: AudioSessionController?

    var body: some View {
        if let audio, audio.isArmed || audio.interruption != nil {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("AUDIO").font(Theme.label(9)).tracking(1.2).foregroundStyle(Theme.dim)
                if audio.isArmed {
                    Text(audio.selectedDevice?.shortName ?? audio.meters.deviceName.uppercased()).font(Theme.strip(13)).foregroundStyle(Theme.text)
                    Text("\(Int(audio.meters.sampleRate / 1000))k").font(Theme.label(9)).foregroundStyle(Theme.dim)
                    HStack(spacing: 3) {
                        ForEach(audio.meters.channels.indices, id: \.self) { i in MeterBar(channel: audio.meters.channels[i]) }
                    }
                    if audio.currentTake != nil { Text("●").font(Theme.label(9)).foregroundStyle(Theme.rec) }
                    if audio.transportRunning { Text("MTC \(audio.mtcRate.framesPerSecond)").font(Theme.label(9)).foregroundStyle(Theme.accent) }
                } else {
                    Text("AUDIO LOST").font(Theme.strip(13)).foregroundStyle(Theme.warn)
                }
            }
            .padding(.horizontal, 10)
            .help(audio.interruption ?? audio.armError ?? "Audio interface armed")
        }
    }
}

struct MeterBar: View {
    var channel: MeterState.Channel
    private let width: CGFloat = 22, height: CGFloat = 8

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.14))
            Rectangle().fill(channel.clipped ? Theme.rec : Theme.text).frame(width: width * MeterScale.fraction(channel.rms))
            Rectangle().fill(channel.clipped ? Theme.rec : Theme.text).frame(width: 1).offset(x: max(0, width * MeterScale.fraction(channel.hold) - 1))
        }
        .frame(width: width, height: height)
        .accessibilityLabel("Audio level \(Int(channel.rms)) dBFS")
    }
}

/// Settings-panel rows for the audio interface; the Audio menu offers the same choices.
struct AudioSettingsSection: View {
    @Environment(AudioSessionController.self) private var audio: AudioSessionController?

    var body: some View {
        if let audio {
            @Bindable var a = audio
            VStack(alignment: .leading, spacing: 6) {
                Text("AUDIO").font(Theme.label()).tracking(1.6).foregroundStyle(Theme.accent).padding(.horizontal, 12)
                HStack {
                    Text("Input").font(.system(size: 12)).foregroundStyle(Theme.text)
                    Spacer()
                    Picker("", selection: Binding(get: { audio.selectedDeviceUID ?? "" }, set: { uid in Task { await audio.arm(deviceUID: uid.isEmpty ? nil : uid, channels: audio.selectedChannels) } })) {
                        Text("None").tag("")
                        ForEach(audio.devices) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden().frame(maxWidth: 170).controlSize(.small)
                }
                .padding(.horizontal, 12)
                if let d = audio.selectedDevice {
                    HStack {
                        Text("Channels").font(.system(size: 12)).foregroundStyle(Theme.text)
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(Array(d.inputChannelNames.prefix(8).enumerated()), id: \.offset) { i, name in
                                let ch = i + 1
                                Toggle("\(ch)", isOn: Binding(get: { audio.selectedChannels.contains(ch) }, set: { on in
                                    var c = Set(audio.selectedChannels); if on { c.insert(ch) } else { c.remove(ch) }
                                    Task { await audio.setChannels(c.sorted()) }
                                })).toggleStyle(.button).controlSize(.mini).help(name)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                HStack {
                    Text("Send timecode to Logic").font(.system(size: 12)).foregroundStyle(Theme.text)
                    Spacer()
                    Toggle("", isOn: $a.sendTimecode).toggleStyle(.switch).controlSize(.small)
                }
                .padding(.horizontal, 12)
                if let e = audio.armError ?? audio.interruption {
                    Text(e).font(.system(size: 10)).foregroundStyle(Theme.warn).padding(.horizontal, 12)
                }
            }
        }
    }
}
#endif
