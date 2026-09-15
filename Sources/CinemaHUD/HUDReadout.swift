import SwiftUI

/// One big cinema-style readout: small label on top, big value, click for a picker, scroll to step.
struct HUDReadout: View {
    let label: String
    let value: String
    var unit: String = ""
    var candidates: [String] = []
    var enabled: Bool = true
    var accent: Color = .white
    var format: (String) -> String = { $0 }
    var onSelect: (String) -> Void = { _ in }
    var onStep: (Int) -> Void = { _ in }

    @State private var showPicker = false

    var body: some View {
        ScrollStepper(onStep: { if enabled { onStep($0) } }) {
            Button {
                if enabled && !candidates.isEmpty { showPicker.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(Theme.label(10)).tracking(2).foregroundStyle(Theme.dim)
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(value).font(Theme.mono(24, weight: .semibold)).foregroundStyle(enabled ? accent : Theme.dim)
                        if !unit.isEmpty { Text(unit).font(Theme.mono(12)).foregroundStyle(Theme.dim) }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(minWidth: 96, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.45)
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
            Text(title).font(Theme.label(10)).tracking(2).foregroundStyle(Theme.dim).padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(candidates, id: \.self) { c in
                            Button { onPick(c) } label: {
                                HStack {
                                    Text(format(c)).font(Theme.mono(14, weight: c == current ? .bold : .regular))
                                    Spacer()
                                    if c == current { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                                }
                                .foregroundStyle(c == current ? Theme.amber : .white)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(c)
                        }
                    }
                }
                .frame(width: 160, height: min(320, CGFloat(candidates.count) * 26 + 8))
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .background(Color.black.opacity(0.92))
    }
}
