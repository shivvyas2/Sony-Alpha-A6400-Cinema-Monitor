import SwiftUI

/// Cinematic boot sequence shown once at launch: frame lines draw on, the CHM wordmark resolves
/// with a light sweep, the subtitle fades in, then everything dissolves into the app.
/// Tap to skip. With Reduce Motion on, it shows a brief static wordmark instead.
struct LaunchIntroView: View {
    var onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lines: CGFloat = 0          // 0…1 frame-line draw progress
    @State private var wordOpacity: Double = 0
    @State private var wordScale: CGFloat = 0.94
    @State private var sweep: CGFloat = -1.2       // light sweep position across the wordmark
    @State private var subtitleOpacity: Double = 0
    @State private var dotScale: CGFloat = 0
    @State private var dissolve: Double = 1        // whole intro opacity
    @State private var finished = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                let r = CGRect(x: 0, y: 0, width: geo.size.width, height: geo.size.height).insetBy(dx: geo.size.width * 0.06, dy: geo.size.height * 0.08)
                // Frame lines: four corner brackets that grow out of the corners.
                FrameLines(progress: lines, rect: r)
                    .stroke(Color(red: 0.90, green: 0.13, blue: 0.16), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                // Edge ticks, appear with the brackets.
                Path { p in
                    let t: CGFloat = 10
                    for (x, y, dx, dy) in [(r.midX, r.minY, 0.0, 1.0), (r.midX, r.maxY, 0.0, -1.0), (r.minX, r.midY, 1.0, 0.0), (r.maxX, r.midY, -1.0, 0.0)] {
                        p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + dx * t, y: y + dy * t))
                    }
                }
                .stroke(Color(red: 0.90, green: 0.13, blue: 0.16), lineWidth: 2)
                .opacity(Double(lines))
            }
            VStack(spacing: 14) {
                ZStack {
                    wordmark
                    // light sweep: a soft diagonal highlight masked by the text
                    wordmark
                        .foregroundStyle(.white)
                        .mask(
                            GeometryReader { g in
                                LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: g.size.width * 0.5)
                                    .offset(x: sweep * g.size.width)
                                    .rotationEffect(.degrees(18))
                            }
                        )
                        .blendMode(.plusLighter)
                }
                .scaleEffect(wordScale)
                .opacity(wordOpacity)
                Text("CINEMA HUD MONITOR")
                    .font(.system(size: 13, weight: .semibold)).tracking(5)
                    .foregroundStyle(.white.opacity(0.7))
                    .opacity(subtitleOpacity)
            }
            // REC-style dot that pops in at the end, then rides out with the dissolve
            Circle().fill(Color(red: 0.90, green: 0.13, blue: 0.16)).frame(width: 10, height: 10)
                .scaleEffect(dotScale)
                .offset(y: 78)
        }
        .opacity(dissolve)
        .contentShape(Rectangle())
        .onTapGesture { finish(now: true) }
        .onAppear(perform: run)
        .accessibilityLabel("CinemaHUD is starting")
    }

    private var wordmark: some View {
        Text("CHM")
            .font(.system(size: 64, weight: .bold, design: .default).width(.condensed))
            .tracking(6)
            .foregroundStyle(.white)
    }

    private func run() {
        if reduceMotion {
            lines = 1; wordOpacity = 1; wordScale = 1; subtitleOpacity = 1; dotScale = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { finish(now: false) }
            return
        }
        withAnimation(.easeOut(duration: 0.55)) { lines = 1 }
        withAnimation(.easeOut(duration: 0.6).delay(0.25)) { wordOpacity = 1; wordScale = 1 }
        withAnimation(.easeInOut(duration: 0.7).delay(0.45)) { sweep = 1.4 }
        withAnimation(.easeOut(duration: 0.4).delay(0.7)) { subtitleOpacity = 1 }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.55).delay(0.95)) { dotScale = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.55) { finish(now: false) }
    }

    private func finish(now: Bool) {
        guard !finished else { return }
        finished = true
        withAnimation(.easeInOut(duration: now ? 0.2 : 0.45)) { dissolve = 0; wordScale = 1.04 }
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0.2 : 0.45)) { onFinished() }
    }
}

/// Four corner brackets whose arms extend with `progress`.
struct FrameLines: Shape {
    var progress: CGFloat
    var rect: CGRect
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func path(in _: CGRect) -> Path {
        var p = Path()
        let L = min(rect.width, rect.height) * 0.16 * progress
        for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0), (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x + dx * L, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy * L))
        }
        return p
    }
}
