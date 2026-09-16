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

    public static func document(pairs: [TakePair], syncedFolder: URL, projectFPS: Int, eventName: String) -> String {
        var resources: [String] = []
        var items: [String] = []
        var nextID = 1
        func id() -> String { defer { nextID += 1 }; return "r\(nextID)" }

        // One format per distinct picture size.
        var formats: [String: String] = [:]    // "WxH" → id
        for p in pairs {
            let key = "\(Int(p.clip.videoSize.width))x\(Int(p.clip.videoSize.height))"
            if formats[key] == nil {
                let f = id(); formats[key] = f
                resources.append("<format id=\"\(f)\" frameDuration=\"1/\(projectFPS)s\" width=\"\(Int(p.clip.videoSize.width))\" height=\"\(Int(p.clip.videoSize.height))\"/>")
            }
        }

        for p in pairs {
            let key = "\(Int(p.clip.videoSize.width))x\(Int(p.clip.videoSize.height))"
            let format = formats[key]!
            let dur = rational(p.clip.duration, fps: projectFPS)
            let name = escape(p.clip.name)
            let clipID = id()
            resources.append("<asset id=\"\(clipID)\" name=\"\(name)\" start=\"0s\" duration=\"\(dur)\" hasVideo=\"1\" format=\"\(format)\" hasAudio=\"\(p.clip.hasAudio ? 1 : 0)\" audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\"><media-rep kind=\"original-media\" src=\"\(fileURL(p.clip.url))\"/></asset>")
            if case .exported(let wav) = p.status {
                let wavID = id()
                let wavName = escape(wav.deletingPathExtension().lastPathComponent)
                resources.append("<asset id=\"\(wavID)\" name=\"\(wavName)\" start=\"0s\" duration=\"\(dur)\" hasAudio=\"1\" audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\"><media-rep kind=\"original-media\" src=\"\(fileURL(wav))\"/></asset>")
                items.append("""
                <sync-clip name="\(name)" offset="0s" duration="\(dur)" format="\(format)" tcFormat="NDF">
                    <asset-clip ref="\(clipID)" offset="0s" name="\(name)" duration="\(dur)" tcFormat="NDF" audioRole="dialogue"/>
                    <asset-clip ref="\(wavID)" lane="-1" offset="0s" name="\(wavName)" duration="\(dur)" audioRole="dialogue"/>
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
