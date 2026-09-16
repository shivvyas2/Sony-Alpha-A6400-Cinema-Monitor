#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CinemaAudio

@Observable
@MainActor
public final class SyncTakesModel {
    public var dayFolder: URL { didSet { pairs = []; message = nil; reloadTakes() } }
    public private(set) var takes: [TakeRecord] = []
    public private(set) var pairs: [TakePair] = []
    public private(set) var busy = false
    public private(set) var message: String?
    public var projectFPS = 24

    public init(dayFolder: URL) { self.dayFolder = dayFolder; reloadTakes() }

    public func reloadTakes() { takes = TakeLog.load(from: dayFolder).takes }

    /// Inspect dropped files/folders, pair them with this day's takes, flag missing WAVs.
    public func load(_ urls: [URL]) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        message = nil
        let clips = await TakeSync.inspect(urls)
        guard !clips.isEmpty else { message = "No clips found (looking for .MP4 / .MOV)"; return }
        pairs = Self.markMissing(TakeSync.pair(clips: clips, takes: takes), dayFolder: dayFolder)
    }

    public func setTake(_ take: TakeRecord?, for pairID: String) {
        guard !busy else { return }
        guard let i = pairs.firstIndex(where: { $0.id == pairID }) else { return }
        pairs[i].take = take
        pairs[i].offsetSeconds = take.map(TakeSync.estimate)
        pairs[i].confidence = nil
        pairs[i].status = take == nil ? .unpaired : .estimated
        pairs = Self.markMissing(pairs, dayFolder: dayFolder)
    }

    /// Run the waveform search for every pair that has a take and a WAV, four at a time.
    public func syncAll() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let folder = dayFolder
        enum Outcome { case ok(offset: Double, confidence: Double), failed(String) }
        let work = pairs.indices.filter { pairs[$0].take != nil && pairs[$0].status != .missingWAV }
        for batch in stride(from: 0, to: work.count, by: 4).map({ Array(work[$0 ..< min($0 + 4, work.count)]) }) {
            await withTaskGroup(of: (Int, Outcome).self) { group in
                for i in batch {
                    let take = pairs[i].take!
                    let wav = folder.appendingPathComponent(take.wavPath)
                    let clip = pairs[i].clip.url
                    let estimate = pairs[i].offsetSeconds ?? TakeSync.estimate(take)
                    group.addTask {
                        do {
                            let r = try await TakeSync.offset(clip: clip, wav: wav, around: estimate)
                            return (i, .ok(offset: r.offset, confidence: r.confidence))
                        } catch {
                            return (i, .failed(error.localizedDescription))
                        }
                    }
                }
                for await (i, outcome) in group {
                    switch outcome {
                    case .ok(let offset, let confidence):
                        pairs[i].confidence = confidence
                        if confidence >= TakeSync.lowConfidence {
                            pairs[i].offsetSeconds = offset
                            pairs[i].status = .synced
                        } else {
                            pairs[i].offsetSeconds = TakeSync.estimate(pairs[i].take!)
                            pairs[i].status = .lowConfidence
                        }
                    case .failed(let message):
                        pairs[i].status = .failed(message)
                    }
                }
            }
        }
    }

    /// Trimmed WAV + synced .mov per pair, then the FCPXML for the day.
    public func exportAll() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let synced = dayFolder.appendingPathComponent("synced")
        try? FileManager.default.createDirectory(at: synced, withIntermediateDirectories: true)
        for i in pairs.indices {
            guard let take = pairs[i].take, let offset = pairs[i].offsetSeconds, pairs[i].status != .missingWAV else { continue }
            let src = dayFolder.appendingPathComponent(take.wavPath)
            let out = TakeExport.outputs(for: pairs[i].clip, take: take, in: synced)
            do {
                try TakeExport.trimmedWAV(wav: src, offset: offset, duration: pairs[i].clip.duration, take: take, to: out.wav)
                try await TakeExport.movie(clip: pairs[i].clip.url, wav: src, offset: offset, to: out.mov)
                pairs[i].status = .exported(out.wav)
            } catch {
                pairs[i].status = .failed(error.localizedDescription)
            }
        }
        let day = dayFolder.lastPathComponent
        let xml = FCPXML.document(pairs: pairs, syncedFolder: synced, projectFPS: projectFPS, eventName: "CinemaHUD \(day)")
        let xmlURL = synced.appendingPathComponent("CinemaHUD_\(day).fcpxml")
        do {
            try xml.write(to: xmlURL, atomically: true, encoding: .utf8)
            message = "Exported to \(synced.path)"
            NSWorkspace.shared.activateFileViewerSelecting([xmlURL])
        } catch {
            message = "Could not write FCPXML: \(error.localizedDescription)"
        }
    }

    // nonisolated (deviation from the brief): the brief's `markMissing` inherits the class's @MainActor
    // isolation, but it is a pure function over its arguments — it touches no actor state. The test calls
    // it from a synchronous, non-async XCTestCase method with no actor context, which the compiler rejects
    // as an actor-isolated call from a nonisolated synchronous context. Marking it `nonisolated` matches
    // what the function actually does and keeps the test (and the brief's other call sites, all already
    // on the main actor) working without changing its signature.
    nonisolated public static func markMissing(_ pairs: [TakePair], dayFolder: URL) -> [TakePair] {
        pairs.map { p in
            var p = p
            if let t = p.take, !FileManager.default.fileExists(atPath: dayFolder.appendingPathComponent(t.wavPath).path) { p.status = .missingWAV }
            return p
        }
    }

    /// For tests: force `busy` without going through an actual load/sync/export.
    func setBusyForTesting(_ v: Bool) { busy = v }
}

public struct SyncTakesView: View {
    @Environment(AudioSessionController.self) private var audio: AudioSessionController?
    @State private var model: SyncTakesModel

    public init(dayFolder: URL) { _model = State(initialValue: SyncTakesModel(dayFolder: dayFolder)) }

    public var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(model.dayFolder.path).font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.head)
                Button("Choose Day Folder…") { chooseDayFolder() }.disabled(model.busy).controlSize(.small)
                Spacer()
                Button("Choose Clips…") { chooseClips() }.disabled(model.busy).controlSize(.small)
                Button("Sync All") { Task { await model.syncAll() } }.disabled(model.busy || model.pairs.isEmpty).controlSize(.small)
                Button("Export") { Task { await model.exportAll() } }.disabled(model.busy || !model.pairs.contains { $0.offsetSeconds != nil }).controlSize(.small).keyboardShortcut(.defaultAction)
            }
            if model.pairs.isEmpty {
                ContentUnavailableView("Drop the card's clips here", systemImage: "waveform.badge.plus",
                                       description: Text("Drag the CLIP folder from the SD card, or choose files. Takes come from \(model.dayFolder.lastPathComponent)/takes.json."))
            } else {
                Table(model.pairs) {
                    TableColumn("Clip") { Text($0.clip.name) }
                    TableColumn("Take") { p in
                        Picker("", selection: Binding(get: { p.take?.id ?? "" }, set: { id in model.setTake(model.takes.first { $0.id == id }, for: p.id) })) {
                            Text("—").tag("")
                            ForEach(model.takes.filter { $0.outcome == .complete }) { Text($0.id).tag($0.id) }
                        }.labelsHidden()
                    }
                    TableColumn("Duration") { Text(String(format: "%.1f s", $0.clip.duration)) }
                    TableColumn("Offset") { p in Text(p.offsetSeconds.map { String(format: "%.3f s", $0) } ?? "—") }
                    TableColumn("Confidence") { p in Text(p.confidence.map { String(format: "%.0f %%", $0 * 100) } ?? "—") }
                    TableColumn("Status") { p in Text(statusText(p.status)).foregroundStyle(statusColor(p.status)) }
                }
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.message ?? "").font(.system(size: 11)).foregroundStyle(Theme.dim)
                Spacer()
            }
        }
        .padding(14)
        .frame(minWidth: 760, minHeight: 420)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !model.busy else { return false }
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) { urls.append(u) }
                }
                await model.load(urls)
            }
            return true
        }
        .onAppear { if let fps = audio?.projectFPS { model.projectFPS = fps } }
    }

    private func chooseClips() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .folder]
        panel.title = "Choose camera clips or the card's CLIP folder"
        if panel.runModal() == .OK { Task { await model.load(panel.urls) } }
    }
    private func chooseDayFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = model.dayFolder.deletingLastPathComponent()
        panel.title = "Choose the day folder (contains takes.json)"
        if panel.runModal() == .OK, let u = panel.url { model.dayFolder = u }
    }
    private func statusText(_ s: TakePair.Status) -> String {
        switch s {
        case .unpaired: return "No take"; case .estimated: return "Estimated"; case .synced: return "Synced"
        case .lowConfidence: return "Low confidence (estimate used)"; case .missingWAV: return "WAV missing"
        case .exported: return "Exported"; case .failed(let m): return "Failed: \(m)"
        }
    }
    private func statusColor(_ s: TakePair.Status) -> Color {
        switch s { case .synced, .exported: return Theme.ok; case .lowConfidence, .missingWAV, .failed: return Theme.warn; default: return Theme.dim }
    }
}

/// Tiny window for the scene and a note, written into each take's iXML and takes.json.
public struct AudioSceneView: View {
    @Environment(AudioSessionController.self) private var audio: AudioSessionController?
    public init() {}
    public var body: some View {
        if let audio {
            @Bindable var a = audio
            Form {
                TextField("Scene", text: $a.scene)
                TextField("Note", text: $a.note)
            }
            .padding(14).frame(width: 320)
        }
    }
}
#endif
