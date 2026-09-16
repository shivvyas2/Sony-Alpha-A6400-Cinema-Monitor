import Foundation
import CoreGraphics

/// FCPXML 1.11 for Final Cut Pro (File ▸ Import ▸ XML) and Resolve. Each exported pair becomes a
/// sync-clip: the camera clip on the storyline with its own audio muted, the trimmed WAV connected on
/// lane −1 at offset 0 (the WAV already starts with the clip).
public enum FCPXML {
    public static func rational(_ seconds: Double, fps: Int) -> String {
        let frames = Int((seconds * Double(fps)).rounded())
        return frames == 0 ? "0s" : "\(frames)/\(fps)s"
    }

    /// A duration bounded by a real file, rounded **down** to the frame.
    ///
    /// `rational` rounds to nearest, which overshoots by up to half a frame whenever a clip's length
    /// isn't on a project-frame boundary — a 42.29 s clip becomes 42.2917 s at 24 fps. The trimmed WAV
    /// beside it holds `Int(duration * sampleRate)` samples, i.e. exactly 42.29 s, so the edit claimed
    /// audio that was never written and Final Cut rejected the whole sync-clip with "Invalid edit with
    /// no respective media". Every duration that has to stay inside a file floors instead.
    public static func mediaRational(_ seconds: Double, fps: Int) -> String {
        let frames = max(0, Int((seconds * Double(fps)).rounded(.down)))
        return frames == 0 ? "0s" : "\(frames)/\(fps)s"
    }

    /// An exported WAV's exact length, in the file's own sample-rate timebase — never a frame grid,
    /// which cannot express a sample count that doesn't divide evenly into frames.
    public static func audioRational(_ wav: ExportedWAV) -> String {
        let rate = Int(wav.sampleRate.rounded())
        return wav.frames <= 0 || rate <= 0 ? "0s" : "\(wav.frames)/\(rate)s"
    }

    public static func document(pairs: [TakePair], projectFPS: Int, eventName: String) -> String {
        var resources: [String] = []
        var items: [String] = []
        var nextID = 1
        func id() -> String { defer { nextID += 1 }; return "r\(nextID)" }

        // A clip with no detected video track would otherwise emit `<format width="0" height="0">`,
        // which Final Cut may reject for the whole document (not just that clip); default it to
        // 1920×1080 instead of dropping the clip from the export.
        func size(_ p: TakePair) -> CGSize { p.clip.videoSize == .zero ? CGSize(width: 1920, height: 1080) : p.clip.videoSize }

        // One format per distinct picture size.
        var formats: [String: String] = [:]    // "WxH" → id
        for p in pairs {
            let s = size(p)
            let key = "\(Int(s.width))x\(Int(s.height))"
            if formats[key] == nil {
                let f = id(); formats[key] = f
                resources.append("<format id=\"\(f)\" frameDuration=\"1/\(projectFPS)s\" width=\"\(Int(s.width))\" height=\"\(Int(s.height))\"/>")
            }
        }

        for p in pairs {
            let s = size(p)
            let key = "\(Int(s.width))x\(Int(s.height))"
            let format = formats[key]!
            let dur = mediaRational(p.clip.duration, fps: projectFPS)
            let videoSeconds = (p.clip.duration * Double(projectFPS)).rounded(.down) / Double(projectFPS)
            let name = escape(p.clip.name)
            let clipID = id()
            resources.append("<asset id=\"\(clipID)\" name=\"\(name)\" start=\"0s\" duration=\"\(dur)\" hasVideo=\"1\" format=\"\(format)\" hasAudio=\"\(p.clip.hasAudio ? 1 : 0)\" audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\"><media-rep kind=\"original-media\" src=\"\(fileURL(p.clip.url))\"/></asset>")
            if case .exported(let out) = p.status {
                let wav = out.url
                let wavID = id()
                let wavName = escape(wav.deletingPathExtension().lastPathComponent)
                // The asset declares what the file actually holds; the edit takes the shorter of the two
                // media, each stated in its own timebase, so neither side of the sync-clip overruns.
                let wavDur = out.frames > 0 ? audioRational(out) : dur
                let connectedDur = out.seconds > 0 && out.seconds < videoSeconds ? wavDur : dur
                // Derived from the paired take when there is one (the WAV's actual channel count and
                // sample rate), rather than the hard-coded stereo/48 kHz that held regardless of what
                // was actually recorded.
                let wavChannels = p.take?.channelNames.count ?? 2
                let wavRate = p.take.map { Int($0.sampleRate) } ?? 48000
                resources.append("<asset id=\"\(wavID)\" name=\"\(wavName)\" start=\"0s\" duration=\"\(wavDur)\" hasVideo=\"0\" hasAudio=\"1\" audioSources=\"1\" audioChannels=\"\(wavChannels)\" audioRate=\"\(wavRate)\"><media-rep kind=\"original-media\" src=\"\(fileURL(wav))\"/></asset>")
                items.append("""
                <sync-clip name="\(name)" offset="0s" duration="\(dur)" format="\(format)" tcFormat="NDF">
                    <asset-clip ref="\(clipID)" offset="0s" name="\(name)" start="0s" duration="\(dur)" tcFormat="NDF" audioRole="dialogue"/>
                    <asset-clip ref="\(wavID)" lane="-1" offset="0s" name="\(wavName)" start="0s" duration="\(connectedDur)" audioRole="dialogue"/>
                    <sync-source sourceID="storyline"><audio-role-source role="dialogue.dialogue-1" active="0"/></sync-source>
                    <sync-source sourceID="connected"><audio-role-source role="dialogue.dialogue-1"/></sync-source>
                </sync-clip>
                """)
            } else {
                items.append("<asset-clip ref=\"\(clipID)\" offset=\"0s\" name=\"\(name)\" duration=\"\(dur)\" format=\"\(format)\" tcFormat=\"NDF\" audioRole=\"dialogue\"/>")
            }
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
            <resources>
                \(resources.joined(separator: "\n        "))
            </resources>
            <library>
                <event name="\(escape(eventName))">
                    \(items.joined(separator: "\n            "))
                </event>
            </library>
        </fcpxml>
        """
    }

    static func fileURL(_ url: URL) -> String { escape(url.standardizedFileURL.absoluteString) }
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
