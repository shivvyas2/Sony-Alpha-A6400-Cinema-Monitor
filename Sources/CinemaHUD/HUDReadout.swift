import SwiftUI

/// One camera-body readout: tracked label above, large tabular value, optional sub-value.
/// Click for a picker, scroll to step. Dimmed when the camera does not allow the change.
struct HUDReadout: View {
    let label: String
    let value: String
    var sub: String = ""
    var candidates: [String] = []
    var enabled: Bool = true
    var accent: Color = Theme.text
    var width: CGFloat = 104
    var format: (String) -> String = { $0 }
    var onSelect: (String) -> Void = { _ in }
    var onStep: (Int) -> Void = { _ in }

    @State private var showPicker = false
    @State private var hover = false

    var body: some View {
        ScrollStepper(onStep: { if enabled { onStep($0) } }) {
            Button {
                if enabled && !candidates.isEmpty { showPicker.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(Theme.label()).tracking(1.6).foregroundStyle(Theme.dim)
                    Text(value).font(Theme.value()).foregroundStyle(enabled ? accent : Theme.faint)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(sub.isEmpty ? " " : sub).font(Theme.mono(10)).foregroundStyle(Theme.dim)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(width: width, alignment: .leading)
                .background(hover && enabled ? Color.white.opacity(0.06) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .popover(isPresented: $showPicker, arrowEdge: .top) {
                CandidatePicker(title: label, current: value, candidates: candidates, format: format) { v in
                    showPicker = false
                    onSelect(v)
                }
            }
        }
    }
}

struct CandidatePicker: View {
    let title: String
    let current: String
    let candidates: [String]
    var format: (String) -> String
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Theme.label()).tracking(1.6).foregroundStyle(Theme.dim).padding(.horizontal, 12).padding(.vertical, 8)
            Divider().overlay(Theme.panelLine)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(candidates, id: \.self) { c in
                            let selected = format(c) == current
                            Button { onPick(c) } label: {
                                Text(format(c)).font(Theme.mono(14, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Color.black : Theme.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(selected ? Theme.selection : .clear)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(c)
                        }
                    }
                }
                .frame(width: 168, height: min(320, CGFloat(candidates.count) * 26 + 8))
                .onAppear { if let c = candidates.first(where: { format($0) == current }) { proxy.scrollTo(c, anchor: .center) } }
            }
        }
        .background(Theme.panel)
    }
}
