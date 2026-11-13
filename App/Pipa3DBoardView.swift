import SwiftUI

/// A rotatable, procedural 3D board with exactly the same interface as
/// PipaBoardView, so PipaView can switch between the photographic and the
/// three-dimensional instrument without touching the audio path.
///
/// Nothing here is reconstructed from pixels. The body, four strings, 32
/// stops and note labels all come from Pipa3DGeometry, and every touch is
/// resolved by a ray cast against the soundboard plane. Swapping in a real
/// 3DGS asset later only replaces the drawing code in this file; the geometry
/// and the pluck callbacks stay untouched.
///
/// Gestures follow the existing board: a tap on the strings plucks, a
/// horizontal sweep strums. Dragging on the empty area around the instrument
/// rotates the view, and a pinch zooms. Those two new gestures never compete
/// with plucking because the drag mode is decided once, at touch down.

private enum BoardDragMode {
    case none
    case play
    case rotate
    case pinch
}

private struct PinchState {
    var scale: CGFloat = 1
    var active = false
}

struct Pipa3DBoardView: View {
    @Binding var selection: (string: Int, fret: Int)
    @Binding var litCell: (string: Int, fret: Int)?
    @Binding var vib: [StringVib]
    @Binding var slash: SlashState?
    @Binding var burst: BurstSignal
    let onPluck: (Int, Int, Double) -> Void
    let onStrum: (Bool, (string: Int, fret: Int)?) -> Void

    /// The same photographed instrument used by the 2D board. Its alpha
    /// channel supplies the real silhouette, including the pegbox and the
    /// four pegs that the procedural outline never had.
    private let photo = Image("PipaInstrument")

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressing: (string: Int, fret: Int)?
    @State private var firstTouch: (string: Int, fret: Int)?
    @State private var yaw: Double = 0
    @State private var pitch: Double = 0
    @State private var baseZoom: Double = 1
    @GestureState private var pinch = PinchState()
    @State private var dragMode: BoardDragMode = .none
    @State private var startYaw: Double = 0
    @State private var startPitch: Double = 0
    @State private var burstStart: Date = .distantPast
    @State private var showNoteNames = true

    private var zoom: Double {
        min(max(baseZoom * Double(pinch.scale), Pipa3DCamera.minZoom),
            Pipa3DCamera.maxZoom)
    }

    var body: some View {
        GeometryReader { geo in
            let rect = Pipa3DGeometry.instrumentRect(
                in: CGRect(origin: .zero, size: geo.size))
            let camera = Pipa3DGeometry.camera(for: rect, yaw: yaw, pitch: pitch,
                                               zoom: zoom)
            ZStack(alignment: .topLeading) {
                // The photograph and the stop annotations depend only on the
                // camera. Keeping them out of the animation timeline avoids
                // redrawing 32 textured bands thirty times a second.
                Canvas { canvas, _ in
                    drawBody(&canvas, camera: camera)
                    drawFrets(&canvas, camera: camera)
                    drawLitCell(&canvas, camera: camera)
                }
                .allowsHitTesting(false)

                TimelineView(.animation(minimumInterval: 1.0 / 30,
                                        paused: reduceMotion)) { context in
                    Canvas { canvas, _ in
                        drawStrings(&canvas, camera: camera, now: context.date)
                        drawGlow(&canvas, camera: camera, now: context.date)
                        drawSlash(&canvas, camera: camera, now: context.date)
                        drawBurst(&canvas, camera: camera, now: context.date)
                    }
                }
                .allowsHitTesting(false)

                if showNoteNames { noteLabels(camera: camera) }
                marker(camera: camera)
            }
            .overlay(alignment: .bottomTrailing) {
                viewControls.padding(8)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(camera: camera)
                .simultaneously(with: pinchGesture))
            .onChange(of: burst.token) { _, _ in
                guard burst.token > 0 else { return }
                burstStart = Date()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("三维琵琶演奏区")
            .accessibilityHint("轻点琴弦演奏，横划扫拂。在琴弦区外拖动可转动视角，双指缩放。")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onPluck(selection.string, selection.fret, 0.5) }
        }
    }

    // MARK: - Gestures

    private func dragGesture(camera: Pipa3DCamera) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // A pinch also fires a one-finger drag. Suppress plucking for
                // the whole gesture instead of letting the release play a note.
                if pinch.active {
                    dragMode = .pinch
                    return
                }
                if dragMode == .none {
                    let outside = Pipa3DGeometry.isOutsideInstrument(
                        screen: value.startLocation, camera: camera)
                    dragMode = outside ? .rotate : .play
                    startYaw = yaw
                    startPitch = pitch
                    if !outside {
                        firstTouch = Pipa3DGeometry.hit(
                            screen: value.startLocation, camera: camera)
                    }
                }
                switch dragMode {
                case .rotate:
                    yaw = min(max(startYaw + Double(value.translation.width) * 0.0022,
                                  -Pipa3DCamera.maxYaw), Pipa3DCamera.maxYaw)
                    pitch = min(max(startPitch - Double(value.translation.height) * 0.0022,
                                    -Pipa3DCamera.maxPitch), Pipa3DCamera.maxPitch)
                case .play:
                    pressing = Pipa3DGeometry.hit(screen: value.location,
                                                  camera: camera)
                case .none, .pinch:
                    break
                }
            }
            .onEnded { value in
                let mode = dragMode
                let starter = firstTouch
                dragMode = .none
                firstTouch = nil
                pressing = nil
                guard mode == .play else { return }
                if abs(value.translation.width) < 14,
                   abs(value.translation.height) < 14 {
                    if let hit = Pipa3DGeometry.hit(screen: value.location,
                                                    camera: camera) {
                        onPluck(hit.string, hit.fret,
                                Pipa3DGeometry.pluckPosition(screen: value.location,
                                                             camera: camera))
                    }
                } else if starter != nil,
                          abs(value.translation.width) > abs(value.translation.height) {
                    onStrum(value.translation.width > 0, starter)
                }
            }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in
                state = PinchState(scale: value, active: true)
            }
            .onEnded { value in
                baseZoom = min(max(baseZoom * Double(value), Pipa3DCamera.minZoom),
                               Pipa3DCamera.maxZoom)
            }
    }

    // MARK: - Overlays

    private func noteLabels(camera: Pipa3DCamera) -> some View {
        ForEach(Pipa3DGeometry.labelledStops, id: \.self) { fret in
            let y = Pipa3DGeometry.stopRows[fret]
            let x = Pipa3DGeometry.stringPixelX(3, atY: y) + 24
            let point = camera.project(Pipa3DGeometry.local(
                xPixel: x, yPixel: y, z: Pipa3DGeometry.stringHeight))
            Text(PipaTuning.noteName(PipaTuning.midi(string: 3, fret: fret)))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(PipaPalette.ink.opacity(0.72))
                .position(point)
                .allowsHitTesting(false)
        }
    }

    private func marker(camera: Pipa3DCamera) -> some View {
        let current = pressing ?? selection
        let y = Pipa3DGeometry.stopRows[current.fret]
        let point = camera.project(Pipa3DGeometry.local(
            xPixel: Pipa3DGeometry.stringPixelX(current.string, atY: y),
            yPixel: y, z: Pipa3DGeometry.stringHeight + 2))
        return Circle()
            .fill(PipaPalette.cinnabar)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1))
            .position(point)
            .allowsHitTesting(false)
    }

    private var viewControls: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    showNoteNames.toggle()
                } label: {
                    Image(systemName: showNoteNames ? "eye" : "eye.slash")
                        .font(.system(size: 11))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .background(.white.opacity(0.62), in: Circle())
                .accessibilityLabel("音名标注")

                Button {
                    yaw = 0
                    pitch = 0
                    baseZoom = 1
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .background(.white.opacity(0.62), in: Circle())
                .accessibilityLabel("复位视角")
            }
            Text("弦区外拖动转视角 · 双指缩放")
                .font(.system(size: 9))
                .foregroundStyle(PipaPalette.muted.opacity(0.85))
                .allowsHitTesting(false)
        }
    }

    // MARK: - Canvas drawing

    private func drawBody(_ ctx: inout GraphicsContext, camera: Pipa3DCamera) {
        // The photograph is the whole instrument. There is deliberately no
        // procedural back plate: the old pear-shaped outline was wider than
        // the real Pipa and showed up as a dirty dark rim even head-on. The
        // banded perspective already reads as a tilted board; real thickness
        // belongs to the reconstructed asset, not to a flat photograph.
        drawPhotograph(&ctx, camera: camera)
    }

    /// Map the real photograph onto the rotated soundboard.
    ///
    /// Canvas has no perspective-correct texture mapping; it can only draw an
    /// image into an axis-aligned rectangle. A flat image seen through a
    /// rotating camera is a homography, so the 506 x 1557 asset is split into
    /// narrow horizontal bands. Each band is clipped to its true projected
    /// quadrilateral and given a least-squares affine fit over all four
    /// corners. At 32 bands the residual stays near a point even at maximum
    /// tilt, while the dead-on view collapses to a single draw.
    private func drawPhotograph(_ ctx: inout GraphicsContext,
                                camera: Pipa3DCamera) {
        let width = CGFloat(Pipa3DGeometry.referenceWidth)
        let height = CGFloat(Pipa3DGeometry.referenceHeight)
        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        let flat = abs(camera.yaw) < 1e-4 && abs(camera.pitch) < 1e-4
        let bands = flat ? 1 : 32
        let bandHeight = height / CGFloat(bands)

        for band in 0..<bands {
            let y0 = CGFloat(band) * bandHeight
            let y1 = y0 + bandHeight
            let topLeft = camera.project(Pipa3DGeometry.local(
                xPixel: 0, yPixel: Double(y0)))
            let topRight = camera.project(Pipa3DGeometry.local(
                xPixel: Double(width), yPixel: Double(y0)))
            let bottomRight = camera.project(Pipa3DGeometry.local(
                xPixel: Double(width), yPixel: Double(y1)))
            let bottomLeft = camera.project(Pipa3DGeometry.local(
                xPixel: 0, yPixel: Double(y1)))

            var quad = Path()
            quad.move(to: topLeft)
            quad.addLine(to: topRight)
            quad.addLine(to: bottomRight)
            quad.addLine(to: bottomLeft)
            quad.closeSubpath()

            // Least-squares affine over all four corners. Averaging the two
            // horizontal and the two vertical edges spreads the perspective
            // residual over every corner instead of dumping all of it on the
            // fourth one, which halves the worst-case error for free.
            let centre = CGPoint(
                x: (topLeft.x + topRight.x + bottomRight.x + bottomLeft.x) / 4,
                y: (topLeft.y + topRight.y + bottomRight.y + bottomLeft.y) / 4)
            let a = ((topRight.x - topLeft.x)
                     + (bottomRight.x - bottomLeft.x)) / (2 * width)
            let b = ((topRight.y - topLeft.y)
                     + (bottomRight.y - bottomLeft.y)) / (2 * width)
            let c = ((bottomLeft.x - topLeft.x)
                     + (bottomRight.x - topRight.x)) / (2 * bandHeight)
            let d = ((bottomLeft.y - topLeft.y)
                     + (bottomRight.y - topRight.y)) / (2 * bandHeight)
            let midY = (y0 + y1) / 2
            let transform = CGAffineTransform(
                a: a, b: b, c: c, d: d,
                tx: centre.x - a * width / 2 - c * midY,
                ty: centre.y - b * width / 2 - d * midY)

            // Each band gets its own drawing layer, which isolates the clip
            // and transform from the bands that follow it.
            ctx.drawLayer { layer in
                layer.clip(to: quad)
                layer.concatenate(transform)
                layer.draw(photo, in: imageRect)
            }
        }
    }

    private func drawFrets(_ ctx: inout GraphicsContext, camera: Pipa3DCamera) {
        // The photograph already shows the fret bars. These hairlines are
        // annotation only: they mark which of the 32 stops is playable and
        // stay faint so the wood grain remains visible underneath.
        for fret in 0..<Pipa3DGeometry.positionCount {
            let (a, b) = Pipa3DGeometry.fretLine(fret)
            var path = Path()
            path.move(to: camera.project(a))
            path.addLine(to: camera.project(b))
            let emphasis = fret < 6 || fret % 6 == 0
            ctx.stroke(path,
                       with: .color(PipaPalette.cinnabar.opacity(emphasis ? 0.5 : 0.26)),
                       lineWidth: (emphasis ? 1.3 : 0.8) * CGFloat(zoom))
        }
    }

    private func drawStrings(_ ctx: inout GraphicsContext, camera: Pipa3DCamera,
                             now: Date) {
        for string in 0..<Pipa3DGeometry.stringCount {
            let state = vib[string]
            let elapsed = state.start.map { now.timeIntervalSince($0) } ?? 100
            let strength = max(0, 1 - elapsed / max(state.dur, 0.01))
            var path = Path()
            for step in 0...36 {
                let t = Double(step) / 36
                let y = Pipa3DGeometry.nutPixel
                    + t * (Pipa3DGeometry.bridgePixel - Pipa3DGeometry.nutPixel)
                let sway = reduceMotion ? 0
                    : sin(elapsed * state.freq * 2 * .pi) * strength
                        * state.dir * 2
                let x = Pipa3DGeometry.stringPixelX(string, atY: y)
                    + sway * sin(t * .pi)
                let point = camera.project(Pipa3DGeometry.local(
                    xPixel: x, yPixel: y, z: Pipa3DGeometry.stringHeight))
                if step == 0 { path.move(to: point) }
                else { path.addLine(to: point) }
            }
            ctx.stroke(path,
                       with: .color(Color(red: 0.42, green: 0.35, blue: 0.25).opacity(0.85)),
                       lineWidth: CGFloat(4 - string) * 0.16 + 0.5)
        }
    }

    private func drawGlow(_ ctx: inout GraphicsContext, camera: Pipa3DCamera,
                          now: Date) {
        for string in 0..<Pipa3DGeometry.stringCount {
            let state = vib[string]
            guard let start = state.start else { continue }
            let elapsed = now.timeIntervalSince(start)
            guard elapsed >= 0, elapsed < state.dur else { continue }
            let value = 1 - elapsed / max(state.dur, 0.01)
            guard value > 0.01 else { continue }
            let y = Pipa3DGeometry.stopRows[min(max(state.fret, 0),
                                                Pipa3DGeometry.positionCount - 1)]
            let point = camera.project(Pipa3DGeometry.local(
                xPixel: Pipa3DGeometry.stringPixelX(string, atY: y),
                yPixel: y, z: Pipa3DGeometry.stringHeight + 2))
            for ring in 0..<3 {
                let radius = CGFloat(8 + ring * 9) * CGFloat(value + 0.35)
                let rect = CGRect(x: point.x - radius, y: point.y - radius,
                                  width: radius * 2, height: radius * 2)
                ctx.fill(Path(ellipseIn: rect),
                         with: .color(PipaPalette.gold.opacity(
                            0.14 * value / Double(ring + 1))))
            }
        }
    }

    private func drawSlash(_ ctx: inout GraphicsContext, camera: Pipa3DCamera,
                           now: Date) {
        guard let state = slash else { return }
        let elapsed = now.timeIntervalSince(state.start)
        guard elapsed >= 0, elapsed < SlashState.totalDuration else { return }
        let points = state.points.map { item in
            let y = Pipa3DGeometry.stopRows[min(max(item.fret, 0),
                                                Pipa3DGeometry.positionCount - 1)]
            return camera.project(Pipa3DGeometry.local(
                xPixel: Pipa3DGeometry.stringPixelX(item.string, atY: y),
                yPixel: y, z: Pipa3DGeometry.stringHeight + 3))
        }
        guard points.count >= 2 else { return }
        let progress = min(1, max(0, elapsed / SlashState.travel))
        var trail = Path()
        trail.move(to: points[0])
        let last = progress * Double(points.count - 1)
        let whole = Int(last)
        for index in 1...max(1, whole) where index < points.count {
            trail.addLine(to: points[index])
        }
        if whole + 1 < points.count {
            let fraction = last - Double(whole)
            let a = points[whole], b = points[whole + 1]
            trail.addLine(to: CGPoint(x: a.x + (b.x - a.x) * fraction,
                                      y: a.y + (b.y - a.y) * fraction))
        }
        let fade: Double = elapsed < SlashState.travel + SlashState.hold
            ? 1
            : max(0, 1 - (elapsed - SlashState.travel - SlashState.hold)
                  / SlashState.fade)
        ctx.stroke(trail, with: .color(PipaPalette.gold.opacity(0.32 * fade)),
                   lineWidth: 16)
        ctx.stroke(trail, with: .color(PipaPalette.gold.opacity(0.85 * fade)),
                   lineWidth: 6)
        ctx.stroke(trail, with: .color(Color.white.opacity(0.95 * fade)),
                   lineWidth: 2.5)
    }

    private func drawBurst(_ ctx: inout GraphicsContext, camera: Pipa3DCamera,
                           now: Date) {
        let elapsed = now.timeIntervalSince(burstStart)
        guard elapsed >= 0, elapsed < 0.5 else { return }
        let life = 1 - elapsed / 0.5
        let y = Pipa3DGeometry.stopRows[min(max(burst.fret, 0),
                                            Pipa3DGeometry.positionCount - 1)]
        let point = camera.project(Pipa3DGeometry.local(
            xPixel: Pipa3DGeometry.stringPixelX(burst.string, atY: y),
            yPixel: y, z: Pipa3DGeometry.stringHeight + 3))
        let radius = CGFloat(6 + 34 * (1 - life))
        let rect = CGRect(x: point.x - radius, y: point.y - radius,
                          width: radius * 2, height: radius * 2)
        ctx.stroke(Path(ellipseIn: rect),
                   with: .color(PipaPalette.gold.opacity(0.8 * life)),
                   lineWidth: 2)
    }

    private func drawLitCell(_ ctx: inout GraphicsContext, camera: Pipa3DCamera) {
        guard let cell = litCell else { return }
        let y = Pipa3DGeometry.stopRows[min(max(cell.fret, 0),
                                            Pipa3DGeometry.positionCount - 1)]
        let point = camera.project(Pipa3DGeometry.local(
            xPixel: Pipa3DGeometry.stringPixelX(cell.string, atY: y),
            yPixel: y, z: Pipa3DGeometry.stringHeight + 1))
        let rect = CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)
        ctx.stroke(Path(roundedRect: rect, cornerRadius: 3),
                   with: .color(PipaPalette.cinnabar.opacity(0.9)), lineWidth: 1.5)
    }
}
