import SwiftUI
import SortlyCore

/// "Fotos fliegen in Alben": while a plan runs, photos lift off a loose pile and fly in one
/// calm arc into their album, one album after another, while a counter runs up.
///
/// The show follows the real work and never runs ahead of it: an album only fills once its
/// step has really finished. With fast work it lasts about 2 s for one album and about 5–7 s
/// for many; when the work is slower, it waits on the next album and photos fly for nearly
/// every one. A backlog of finished albums is riffled through. "Animation überspringen" ends the show
/// at once. With Reduce Motion only the current album is shown and cross-fades; nothing flies.
struct SortingShow: View {
    struct Album: Identifiable, Equatable {
        /// Index of the album's last "add photos" step in the plan.
        let id: Int
        let title: String
        let assets: [AssetID]
    }

    let albums: [Album]
    var onFinish: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var current = 0
    @State private var landed: Set<Int> = []
    /// Distinct photos sorted so far (a photo in two albums counts once, like the result card).
    @State private var sorted: Set<AssetID> = []
    @State private var flights: [Flight] = []
    @State private var pop = false
    @State private var landings = 0
    @State private var width: CGFloat = 360

    private let sceneHeight: CGFloat = 360
    private var pileCenter: CGPoint { CGPoint(x: width / 2, y: 78) }
    private var albumCenter: CGPoint { CGPoint(x: width / 2, y: 252) }
    private var spacing: CGFloat { min(176, width * 0.44) }
    private var totalPhotos: Int { Set(albums.flatMap(\.assets)).count }
    private var counted: Int { sorted.count }

    /// Loose photos on the pile: offset x, offset y, rotation in degrees.
    private static let scatter: [(CGFloat, CGFloat, Double)] = [
        (-54, -4, -11), (46, -12, 8), (-14, 12, -3), (60, 16, 13), (-66, 24, -16), (8, -22, 5),
    ]

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            header
            ZStack {
                pile
                carousel
                ForEach(flights) { FlyingPhoto(flight: $0) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: sceneHeight)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // Decorative and hidden from VoiceOver: the labels must not grow out of the scene.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .accessibilityHidden(true)

            // Ends only the animation; the albums keep being created in the background.
            Button("Animation überspringen", action: onFinish)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.glass)
                .controlSize(.large)
        }
        // iPad: a focused column instead of a small cluster in a wide band.
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.m)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: landings)
        .task {
            if voiceOver {
                AccessibilityNotification.Announcement(String(localized: "Fotos werden einsortiert")).post()
            }
            await run()
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(spacing: Theme.Spacing.xs) {
            // Albums count up steadily; the photo count would stand still while photos that
            // are already sorted get a second album (a country holds its trips).
            Text(landed.count, format: .number)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(landed.count)))
            Text("von \(albums.count) Alben fertig")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("\(counted) Fotos einsortiert")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(counted)))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Fotos werden einsortiert"))
        .accessibilityValue(Text("\(landed.count) von \(albums.count) Alben fertig, \(counted) Fotos einsortiert"))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The pile thins out as photos find their albums.
    private var pile: some View {
        let photos = pilePhotos
        let remaining = 1 - Double(counted) / Double(max(1, totalPhotos))
        let visible = max(0, min(photos.count, Int((remaining * Double(photos.count)).rounded(.up))))
        return ZStack {
            ForEach(Array(photos.prefix(visible).enumerated()), id: \.element) { index, id in
                let s = Self.scatter[index % Self.scatter.count]
                PhotoChip(id: id, side: 76)
                    .rotationEffect(.degrees(s.2 * 0.6))
                    .offset(x: s.0, y: s.1)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .position(pileCenter)
        .animation(.smooth(duration: 0.35), value: visible)
    }

    /// The albums move as one strip; with Reduce Motion only the current one, cross-fading.
    private var carousel: some View {
        ZStack {
            ForEach(albums.indices.filter { reduceMotion ? $0 == current : abs($0 - current) <= 1 }, id: \.self) { index in
                let offset = CGFloat(index - current)
                AlbumStack(album: albums[index], filled: landed.contains(index), focused: index == current)
                    // Fade the album as one picture; otherwise the placeholder shines through the cover.
                    .compositingGroup()
                    .scaleEffect(index == current ? (pop && !reduceMotion ? 1.04 : 1) : 0.76)
                    .opacity(index == current ? 1 : (index < current ? 0.5 : 0.35))
                    .position(x: albumCenter.x + offset * spacing, y: albumCenter.y)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.asymmetric(
                        insertion: AnyTransition.offset(x: spacing).combined(with: .opacity),
                        removal: AnyTransition.offset(x: -spacing).combined(with: .opacity)))
            }
        }
    }

    /// Up to six photos from the first albums, so the pile shows the user's own pictures.
    private var pilePhotos: [AssetID] {
        var result: [AssetID] = []
        var round = 0
        while result.count < 6 && round < 6 {
            for album in albums where round < album.assets.count && result.count < 6 {
                let id = album.assets[round]
                if !result.contains(id) { result.append(id) }
            }
            round += 1
        }
        return result
    }

    // MARK: Choreography

    private func run() async {
        let started = Date()
        // When the strip may move again: a move never starts while the last one is still
        // running, otherwise a fast riffle shows two strips sliding over each other.
        var moveEnds = Date.distantPast
        // `.task` restarts when the tab comes back: continue there, never land an album twice.
        for index in albums.indices where !landed.contains(index) {
            if Task.isCancelled { return }
            let essential = index < 3 || index == albums.count - 1
            let calm = !reduceMotion && !voiceOver
            if calm && (essential || albumsDone() - index <= 1) {
                await prefetch(index)
            }
            await waitUntilDone(index, started: started)
            let execution = model.execution
            if Task.isCancelled || execution.failure != nil { break }
            if !execution.isRunning && execution.finished == nil { break } // never started: no celebration
            // A step that failed or was skipped gets no checkmark.
            if execution.unsuccessfulSteps.contains(albums[index].id) { continue }
            // Photos fly while the show keeps up; a backlog of finished albums is riffled through.
            let quick = !calm || (!essential && albumsDone() - index > 1)
            let mustMove = current != index && (!quick || index == albums.count - 1)
            if mustMove, moveEnds.timeIntervalSinceNow > 0 {
                try? await Task.sleep(for: .seconds(moveEnds.timeIntervalSinceNow))
            }
            if current != index && (mustMove || moveEnds.timeIntervalSinceNow <= 0) {
                let duration = reduceMotion || quick ? 0.3 : 0.5
                withAnimation(reduceMotion ? .easeInOut(duration: duration) : .smooth(duration: duration)) {
                    current = index
                }
                moveEnds = Date().addingTimeInterval(duration + 0.04)
            }
            if quick {
                await land(index, quietly: true)
                let step = reduceMotion ? max(0.08, min(0.5, 2.0 / Double(albums.count))) : 0.06
                try? await Task.sleep(for: .seconds(step))
            } else {
                let arrival = launch(index, duration: albums.count == 1 ? 0.7 : 0.58, lead: 0.15)
                try? await Task.sleep(for: .seconds(arrival))
                await land(index, quietly: false)
                try? await Task.sleep(for: .seconds(0.15))
                // The next album already moves to the centre and waits there while its step runs.
                if index + 1 < albums.count && albumsDone() <= index + 1 {
                    withAnimation(.smooth(duration: 0.5)) { current = index + 1 }
                    moveEnds = Date().addingTimeInterval(0.54)
                }
            }
        }
        await waitForEnd(started: started)
        guard !Task.isCancelled else { return }
        // The counter ends on what really arrived (photos no longer in the library are not counted).
        if let finished = model.execution.finished {
            let applied = finished.appliedAssets
            if applied != sorted { withAnimation(.snappy(duration: 0.3)) { sorted = applied } }
        }
        try? await Task.sleep(for: .seconds(0.5))
        guard !Task.isCancelled else { return }
        onFinish()
    }

    /// Sends the first photos of an album on their way; returns when the last one arrives.
    @discardableResult
    private func launch(_ index: Int, duration: Double, lead: Double = 0) -> Double {
        let album = albums[index]
        let count = min(album.assets.count, albums.count == 1 ? 5 : 3)
        let flight = max(0.5, duration)
        let stagger = 0.08
        let target = CGPoint(x: albumCenter.x, y: albumCenter.y - 30)
        // One calm gesture per album: all photos bow to the same side, alternating per album.
        let bow: CGFloat = (index.isMultiple(of: 2) ? 1 : -1) * min(64, width * 0.16)
        var launched: [Flight] = []
        for k in 0..<count {
            let s = Self.scatter[k % Self.scatter.count]
            // Dealt from the top of the pile; ArcFlight fades them in while they lift.
            let from = CGPoint(x: pileCenter.x + s.0 * 0.25, y: pileCenter.y + s.1 * 0.25 - 6)
            let to = CGPoint(x: target.x + CGFloat(k % 3 - 1) * 5, y: target.y + CGFloat(k % 2) * 3)
            let control = CGPoint(x: (from.x + to.x) / 2 + bow * (1 + 0.2 * CGFloat(k)), y: from.y - 56)
            launched.append(Flight(asset: album.assets[k], from: from, control: control, to: to,
                                   angle: s.2 * 0.6, delay: lead + Double(k) * stagger, duration: flight))
        }
        flights.append(contentsOf: launched)
        let arrival = lead + Double(max(0, count - 1)) * stagger + flight
        let ids = Set(launched.map(\.id))
        Task {
            try? await Task.sleep(for: .seconds(arrival + 0.3))
            flights.removeAll { ids.contains($0.id) }
        }
        return arrival
    }

    private func land(_ index: Int, quietly: Bool) async {
        guard !landed.contains(index) else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.62)) {
            _ = landed.insert(index)
        }
        withAnimation(.snappy(duration: quietly ? 0.15 : 0.35)) { sorted.formUnion(albums[index].assets) }
        if quietly { return }
        if index < 3 || index == albums.count - 1 { landings += 1 } // a few soft taps, not one per album
        withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) { pop = true }
        try? await Task.sleep(for: .seconds(0.14))
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { pop = false }
    }

    /// Never ahead of the real work: wait until the album's step has finished.
    private func waitUntilDone(_ index: Int, started: Date) async {
        while !Task.isCancelled {
            let execution = model.execution
            // completedSteps only counts for this run while it runs (a previous run leaves its value).
            if execution.isRunning && execution.completedSteps > albums[index].id { return }
            if execution.finished != nil || execution.failure != nil { return }
            if !execution.isRunning && Date().timeIntervalSince(started) > 3 { return }
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    /// The result card needs isRunning == false; `finished` is set earlier, before the new
    /// albums are recorded.
    private func waitForEnd(started: Date) async {
        while !Task.isCancelled {
            let execution = model.execution
            if !execution.isRunning && (execution.finished != nil || execution.failure != nil) { return }
            if !execution.isRunning && Date().timeIntervalSince(started) > 3 { return }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func albumsDone() -> Int {
        let execution = model.execution
        if execution.finished != nil { return albums.count }
        guard execution.isRunning else { return 0 }
        return albums.filter { execution.completedSteps > $0.id }.count
    }

    /// Loads the photos about to fly now, not mid-flight.
    private func prefetch(_ index: Int) async {
        for id in albums[index].assets.prefix(albums.count == 1 ? 5 : 3) {
            _ = await ThumbnailCache.shared.image(for: id, side: 76)
        }
    }

    // MARK: Plan → albums

    /// The albums a plan fills, in plan order. Chunked "add photos" steps of one album are
    /// merged; the album counts as done when its last chunk is done.
    static func albums(from plan: ChangePlan, inventory: CollectionInventory) -> [Album] {
        var titles: [String: String] = [:]
        for step in plan.steps {
            if case .createAlbum(let key, let title, _) = step.operation { titles[key] = title }
        }
        var order: [AlbumRef] = []
        var lastStep: [AlbumRef: Int] = [:]
        var assets: [AlbumRef: [AssetID]] = [:]
        for (index, step) in plan.steps.enumerated() {
            guard case .addAssets(let ref, let ids) = step.operation, !ids.isEmpty else { continue }
            if lastStep[ref] == nil { order.append(ref) }
            lastStep[ref] = index
            assets[ref, default: []].append(contentsOf: ids)
        }
        return order.map { ref in
            let title: String = switch ref {
            case .planned(let key): titles[key] ?? String(localized: "Album")
            case .existing(let id): inventory[id]?.title ?? String(localized: "Album")
            }
            return Album(id: lastStep[ref] ?? 0, title: title, assets: assets[ref] ?? [])
        }
    }
}

// MARK: - Pieces

/// A photo as a small print: rounded edge in the card colour (white in light mode, a quiet
/// rim in dark mode), soft shadow.
private struct PhotoChip: View {
    var id: AssetID
    var side: CGFloat

    var body: some View {
        AssetThumbnail(id: id, side: side)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.card, lineWidth: 3)
            }
            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
    }
}

/// The target album: a small stack with its cover, title and count.
private struct AlbumStack: View {
    var album: SortingShow.Album
    var filled: Bool
    /// The album in the centre; neighbours hide their labels (the screen edges would cut them).
    var focused = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let side: CGFloat = 124

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.card)
                    .frame(width: side - 16, height: side - 16)
                    .offset(y: -14)
                    .opacity(0.7)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.card)
                    .frame(width: side - 8, height: side - 8)
                    .offset(y: -7)
                cover
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if filled {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Theme.onAccent, Theme.accent)
                                .padding(8)
                                .transition(reduceMotion ? AnyTransition.opacity
                                            : AnyTransition.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
            }
            .shadow(color: .black.opacity(0.12), radius: 14, y: 8)
            // Up to two lines, so trip names with dates stay whole. The hidden copy keeps room
            // for two lines; the count follows the name directly and nothing below jumps.
            ZStack(alignment: .top) {
                label(title: "A\nA", count: 0).hidden()
                label(title: album.title, count: album.assets.count)
            }
            .opacity(focused ? 1 : 0)
        }
    }

    private func label(title: String, count: Int) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 200)
            Text("\(count) Fotos")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Opaque placeholder that pulses calmly while the album waits for its step; the cover
    /// is always mounted so it is loaded in time and fades in without a grey frame.
    private var cover: some View {
        ZStack {
            Theme.card
            Theme.accent.opacity(0.12)
            Image(systemName: "rectangle.stack")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Theme.accent.opacity(0.6))
                .symbolEffect(.pulse, isActive: focused && !filled && !reduceMotion)
                .opacity(filled ? 0 : 1)
            if let first = album.assets.first {
                AssetThumbnail(id: first, side: side)
                    .opacity(filled ? 1 : 0)
            }
        }
    }
}

private struct Flight: Identifiable {
    let id = UUID()
    let asset: AssetID
    let from: CGPoint
    let control: CGPoint
    let to: CGPoint
    let angle: Double
    let delay: Double
    let duration: Double
}

/// One photo on its way: it lifts (grows, deeper shadow), swings along a curve and shrinks
/// into the album.
private struct FlyingPhoto: View {
    let flight: Flight
    @State private var progress: CGFloat = 0

    var body: some View {
        PhotoChip(id: flight.asset, side: 76)
            .modifier(ArcFlight(progress: progress, from: flight.from, control: flight.control,
                                to: flight.to, angle: flight.angle))
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.timingCurve(0.42, 0, 0.18, 1, duration: flight.duration).delay(flight.delay)) {
                    progress = 1
                }
            }
    }
}

/// Position on a quadratic Bézier curve plus lift, turn and fade, driven by one number so
/// SwiftUI can animate it frame by frame.
private struct ArcFlight: ViewModifier, Animatable {
    var progress: CGFloat
    let from: CGPoint
    let control: CGPoint
    let to: CGPoint
    let angle: Double

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = progress
        let u = 1 - t
        let x = u * u * from.x + 2 * u * t * control.x + t * t * to.x
        let y = u * u * from.y + 2 * u * t * control.y + t * t * to.y
        // Lift first (+8 %, deeper shadow, squares up), then sink and shrink into the album.
        let lift = sin(CGFloat.pi * min(1, t / 0.6))
        let settle = max(0, (t - 0.5) / 0.5)
        let scale = (1 + 0.08 * lift) * (1 - 0.38 * settle * settle)
        let appear = Double(min(1, t / 0.08))
        let fade: Double = t > 0.9 ? Double((1 - t) / 0.1) : 1
        return content
            .scaleEffect(scale)
            .rotationEffect(.degrees(angle * Double(u * u)))
            .shadow(color: .black.opacity(0.18 * Double(lift)), radius: 12 * lift, y: 8 * lift)
            .opacity(appear * fade)
            .position(x: x, y: y)
    }
}
