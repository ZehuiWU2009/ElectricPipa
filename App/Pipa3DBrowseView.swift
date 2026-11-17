import SwiftUI

/// 观琴页：三维琴面在这里只作视觉资产。
///
/// 左右拖动可以把琴转到正面、侧面、背面，三面各有自己的热点和介绍；
/// 双指缩放，轻点热点只出名称，再点名称才展开中英详解。这一页不接任何
/// 拨弦或扫弦回调，一个音都不发。真正的演奏全部交给二维的 PipaBoardView：
/// 在倾斜的琴面上横划很难和转视角区分，把两件事分开，视角手势就再也不会
/// 抢走扫弦。
///
/// 琴面独占一层铺满整个视图，标题、名称与介绍都是浮层，不切走它的高度。
/// 正面与背面都贴真琴照片，侧面的肋板暂用解析几何绘制。日后换成真正的
/// 3DGS 资产只需替换本文件的 Canvas 绘制，部位介绍与进入演奏的流程不受影响。

private struct BrowsePinchState {
    var scale: CGFloat = 1
}

private struct BrowseDragState {
    var translation: CGSize = .zero
}

private let browseYawLimit: Double = .pi
private let browseDragSensitivity: Double = 0.0045

struct Pipa3DBrowseView: View {
    let onEnterPlay: () -> Void

    private let frontPhoto = Image("PipaInstrument")
    private let backPhoto = Image("PipaInstrumentBack")

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var yaw: Double = 0
    @State private var pitch: Double = 0
    @State private var baseZoom: Double = 1
    @GestureState private var pinch = BrowsePinchState()
    @GestureState private var drag = BrowseDragState()

    /// 第一级：点过热点的部位名。nil 表示还没点，琴面完全无遮挡。
    @State private var selected: PipaPart? = nil
    /// 第二级：点名称后才展开的完整介绍。
    @State private var showDetail = false

    private var zoom: Double {
        min(max(baseZoom * Double(pinch.scale), Pipa3DCamera.minZoom),
            Pipa3DCamera.maxZoom)
    }

    var body: some View {
        GeometryReader { geo in
            let rect = Pipa3DGeometry.instrumentRect(
                in: CGRect(origin: .zero, size: geo.size))
            // The live drag is folded into the camera while the finger is down,
            // and committed to yaw/pitch only when the gesture ends. Rebuilding
            // the camera from the base angle each frame keeps a long drag from
            // accelerating.
            let liveYaw = clampAngle(yaw + Double(drag.translation.width) * browseDragSensitivity,
                                     limit: browseYawLimit)
            let livePitch = clampAngle(pitch - Double(drag.translation.height) * browseDragSensitivity,
                                       limit: Pipa3DCamera.maxPitch)
            let camera = Pipa3DGeometry.camera(for: rect, yaw: liveYaw,
                                               pitch: livePitch, zoom: zoom)
            let face = PipaViewFace.fromYaw(liveYaw)

            ZStack {
                // The instrument owns the whole view. Its rectangle is fitted
                // to the full frame, so no bar can crop its lower half.
                Canvas { canvas, _ in
                    switch face {
                    case .front:
                        drawPhotograph(&canvas, photo: frontPhoto, camera: camera,
                                       z: 0)
                        drawFrets(&canvas, camera: camera)
                        drawStrings(&canvas, camera: camera)
                    case .back:
                        drawPhotograph(&canvas, photo: backPhoto, camera: camera,
                                       z: -Pipa3DGeometry.bodyThickness, flipX: true)
                    case .side:
                        drawRibs(&canvas, camera: camera)
                    }
                }
                .allowsHitTesting(false)

                // Hotspots breathe on their own clock. Keeping them in a
                // separate animation layer means the 32-band photo is drawn
                // only when the camera changes, not on every twinkle frame.
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    Canvas { canvas, _ in
                        drawHotspots(&canvas, camera: camera, face: face,
                                     time: timeline.date)
                    }
                    .allowsHitTesting(false)
                }

                // A dedicated transparent touch layer sits above the drawing
                // but below every control, so taps on the name/detail buttons
                // never also start a rotation.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture(camera: camera)
                        .simultaneously(with: pinchGesture))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("三维琵琶观琴区")
                    .accessibilityHint("轻点琴身部位看名称，再点名称看介绍。左右拖动可看正面、侧面与背面，双指缩放。这里不发声，演奏请按开始演奏。")

                header(face: face)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // Two-level disclosure: name first, full text only on request.
                VStack(spacing: 0) {
                    if let part = selected {
                        if showDetail {
                            detailCard(for: part, face: face)
                        } else {
                            nameChip(for: part, face: face)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(PipaPalette.paper)
        .foregroundStyle(PipaPalette.ink)
    }

    // MARK: - Face

    // MARK: - Header

    private func header(face: PipaViewFace) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("认识这把 Pipa").font(.system(size: 20, weight: .medium, design: .serif))
                Text("轻点热点看名称 · 左右拖动看三面 · 双指缩放")
                    .font(.system(size: 10)).foregroundStyle(PipaPalette.muted)
            }
            Spacer(minLength: 6)
            Button {
                yaw = 0
                pitch = 0
                baseZoom = 1
                selected = nil
                showDetail = false
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.66), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("复位视角")

            Button(action: onEnterPlay) {
                HStack(spacing: 5) {
                    Text("开始演奏").font(.system(size: 13, weight: .medium, design: .serif))
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(PipaPalette.paper)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(PipaPalette.cinnabar, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("进入二维演奏")
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 22)
        .background(
            LinearGradient(colors: [PipaPalette.paper, PipaPalette.paper.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Gestures (view only, never pluck)

    /// 整面都是旋转区，横向长拖可以一直转到背面。位移很小的拖动当成轻点。
    private func dragGesture(camera: Pipa3DCamera) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($drag) { value, state, _ in
                state = BrowseDragState(translation: value.translation)
            }
            .onEnded { value in
                yaw = clampAngle(yaw + Double(value.translation.width) * browseDragSensitivity,
                                 limit: browseYawLimit)
                pitch = clampAngle(pitch - Double(value.translation.height) * browseDragSensitivity,
                                   limit: Pipa3DCamera.maxPitch)
                guard abs(value.translation.width) < 12,
                      abs(value.translation.height) < 12 else {
                    // Turning the instrument puts a different set of parts in
                    // view, so a real drag closes any name/detail card.
                    selected = nil
                    showDetail = false
                    return
                }
                let tappedFace = PipaViewFace.fromYaw(yaw)
                if let part = part(at: value.startLocation, camera: camera, face: tappedFace) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        selected = part
                        showDetail = false
                    }
                }
            }
    }

    private func clampAngle(_ value: Double, limit: Double) -> Double {
        min(max(value, -limit), limit)
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in
                state = BrowsePinchState(scale: value)
            }
            .onEnded { value in
                baseZoom = min(max(baseZoom * Double(value), Pipa3DCamera.minZoom),
                               Pipa3DCamera.maxZoom)
            }
    }

    private func part(at screen: CGPoint, camera: Pipa3DCamera,
                      face: PipaViewFace) -> PipaPart? {
        // A tap on a hotspot dot selects the part that dot promises. The
        // semantic hit puts frets ahead of the soundboard, so without this
        // the "相" dot could jump to a neighboring part and feel broken.
        var nearest: PipaPart?
        var nearestDist: CGFloat = 16
        for info in PipaPartAnnotations.entries(on: face) {
            let p = camera.project(PipaPartAnnotations.anchorLocal(info.part, face: face))
            let d = hypot(screen.x - p.x, screen.y - p.y)
            if d < nearestDist { nearestDist = d; nearest = info.part }
        }
        if let nearest { return nearest }

        // Elsewhere on the instrument, fall back to the semantic layer.
        let z = face == .front ? 0.0
              : face == .back ? -Pipa3DGeometry.bodyThickness
              : -Pipa3DGeometry.bodyThickness / 2
        guard let local = camera.unproject(screen, planeZ: z) else { return nil }
        let (x, y) = Pipa3DGeometry.pixel(local)
        return PipaPartAnnotations.hit(x: x, y: y, face: face)
    }

    // MARK: - Level 1: name only

    private func nameChip(for part: PipaPart, face: PipaViewFace) -> some View {
        let info = PipaPartAnnotations.info(part, face: face)
        return Button {
            withAnimation(.easeOut(duration: 0.2)) { showDetail = true }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(PipaPalette.cinnabar).frame(width: 6, height: 6)
                Text(info.zhName)
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(PipaPalette.cinnabar)
                Text(info.enName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PipaPalette.muted)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PipaPalette.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(PipaPalette.gold.opacity(0.28), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.bottom, 14)
        .accessibilityLabel("\(info.zhName)，点按查看介绍")
    }

    // MARK: - Level 2: full introduction

    private func detailCard(for part: PipaPart, face: PipaViewFace) -> some View {
        let info = PipaPartAnnotations.info(part, face: face)
        let others = PipaPartAnnotations.listedParts(on: face)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(info.zhName)
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(PipaPalette.cinnabar)
                Text(info.enName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PipaPalette.muted)
                Spacer(minLength: 4)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showDetail = false }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起介绍")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(info.zhDetail)
                        .font(.system(size: 12, weight: .regular, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(info.enDetail)
                        .font(.system(size: 10)).foregroundStyle(PipaPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxHeight: 150)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(others, id: \.self) { other in
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                selected = other
                                showDetail = true
                            }
                        } label: {
                            Text(PipaPartAnnotations.info(other, face: face).zhName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(other == part
                                                 ? PipaPalette.paper : PipaPalette.ink)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(other == part
                                            ? PipaPalette.cinnabar.opacity(0.85)
                                            : Color.white.opacity(0.72),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(PipaPartAnnotations.info(other, face: face).zhName)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(PipaPalette.gold.opacity(0.22), lineWidth: 0.7))
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    // MARK: - Canvas drawing, photographed faces

    /// 照片琴身，正面与背面共用。Canvas 没有透视正确的贴图，按
    /// Pipa3DBoardView 的做法把参考图切成 32 条水平带，每条对四角做
    /// 最小二乘仿射，正视时退化为一次绘制。z 为 0 贴正面，为 -bodyThickness
    /// 贴背面；两张照片都已裁到 506 x 1557，共用同一套参考像素。
    private func drawPhotograph(_ ctx: inout GraphicsContext, photo: Image,
                                camera: Pipa3DCamera, z: Double,
                                flipX: Bool = false) {
        let width = CGFloat(Pipa3DGeometry.referenceWidth)
        let height = CGFloat(Pipa3DGeometry.referenceHeight)
        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        let flat = abs(camera.yaw) < 1e-4 && abs(camera.pitch) < 1e-4
        let bands = flat ? 1 : 32
        let bandHeight = height / CGFloat(bands)
        // The back view is reached by yawing past 90 degrees, which mirrors
        // local x on screen. The back photo was shot from that side already,
        // so its columns must be swapped to appear the right way round.
        let leftPixel = flipX ? width : 0
        let rightPixel = flipX ? 0 : width

        for band in 0..<bands {
            let y0 = CGFloat(band) * bandHeight
            let y1 = y0 + bandHeight
            let topLeft = camera.project(Pipa3DGeometry.local(
                xPixel: leftPixel, yPixel: Double(y0), z: z))
            let topRight = camera.project(Pipa3DGeometry.local(
                xPixel: rightPixel, yPixel: Double(y0), z: z))
            let bottomRight = camera.project(Pipa3DGeometry.local(
                xPixel: rightPixel, yPixel: Double(y1), z: z))
            let bottomLeft = camera.project(Pipa3DGeometry.local(
                xPixel: leftPixel, yPixel: Double(y1), z: z))

            var quad = Path()
            quad.move(to: topLeft)
            quad.addLine(to: topRight)
            quad.addLine(to: bottomRight)
            quad.addLine(to: bottomLeft)
            quad.closeSubpath()

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

            ctx.drawLayer { layer in
                layer.clip(to: quad)
                layer.concatenate(transform)
                layer.draw(photo, in: imageRect)
            }
        }
    }

    /// 品线只是标注：照片里已有真实的品，这里画出 32 个可介绍音位。
    private func drawFrets(_ ctx: inout GraphicsContext, camera: Pipa3DCamera) {
        for fret in 0..<Pipa3DGeometry.positionCount {
            let (a, b) = Pipa3DGeometry.fretLine(fret)
            var path = Path()
            path.move(to: camera.project(a))
            path.addLine(to: camera.project(b))
            let emphasis = fret < 6 || fret % 6 == 0
            ctx.stroke(path,
                       with: .color(PipaPalette.cinnabar.opacity(emphasis ? 0.38 : 0.18)),
                       lineWidth: (emphasis ? 1.1 : 0.7) * CGFloat(zoom))
        }
    }

    /// 静态四弦。观琴页不振动、不发光——那是演奏页的事。
    private func drawStrings(_ ctx: inout GraphicsContext, camera: Pipa3DCamera) {
        for string in 0..<Pipa3DGeometry.stringCount {
            let (a, b) = Pipa3DGeometry.stringLine(string)
            var path = Path()
            path.move(to: camera.project(a))
            path.addLine(to: camera.project(b))
            ctx.stroke(path,
                       with: .color(Color(red: 0.42, green: 0.35, blue: 0.25).opacity(0.82)),
                       lineWidth: CGFloat(4 - string) * 0.16 + 0.5)
        }
    }

    // MARK: - Canvas drawing, side

    /// 侧视只画一条由面板外缘与背板外缘围出的肋板带，琴腹热点落在带中央。
    private func drawRibs(_ ctx: inout GraphicsContext, camera: Pipa3DCamera) {
        let near = camera.yaw >= 0 ? -1.0 : 1.0
        let steps = 48
        var rib = Path()
        var first = true
        for i in 0...steps {
            let y = Double(i) / Double(steps) * Pipa3DGeometry.referenceHeight
            let x = 247 + near * Pipa3DGeometry.bodyHalfWidth(atY: y)
            let p = camera.project(Pipa3DGeometry.local(xPixel: x, yPixel: y, z: 0))
            if first { rib.move(to: p); first = false } else { rib.addLine(to: p) }
        }
        for i in stride(from: steps, through: 0, by: -1) {
            let y = Double(i) / Double(steps) * Pipa3DGeometry.referenceHeight
            let x = 247 + near * Pipa3DGeometry.bodyHalfWidth(atY: y)
            rib.addLine(to: camera.project(Pipa3DGeometry.local(
                xPixel: x, yPixel: y, z: -Pipa3DGeometry.bodyThickness)))
        }
        rib.closeSubpath()

        let wood = Gradient(colors: [
            Color(red: 0.52, green: 0.30, blue: 0.17),
            Color(red: 0.31, green: 0.16, blue: 0.09),
            Color(red: 0.46, green: 0.25, blue: 0.13)
        ])
        ctx.fill(rib, with: .linearGradient(
            wood, startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: 0, y: camera.project(Pipa3DGeometry.local(
                xPixel: 247, yPixel: 1557, z: 0)).y)))
        ctx.stroke(rib, with: .color(Color(red: 0.20, green: 0.10, blue: 0.06)),
                   lineWidth: 1.2)

        ctx.drawLayer { layer in
            layer.clip(to: rib)
            for i in 1..<6 {
                let z = -Pipa3DGeometry.bodyThickness * Double(i) / 6
                var grain = Path()
                for step in 0...steps {
                    let y = Double(step) / Double(steps) * Pipa3DGeometry.referenceHeight
                    let x = 247 + near * Pipa3DGeometry.bodyHalfWidth(atY: y)
                    let p = camera.project(Pipa3DGeometry.local(xPixel: x, yPixel: y, z: z))
                    if step == 0 { grain.move(to: p) } else { grain.addLine(to: p) }
                }
                layer.stroke(grain, with: .color(
                    Color(red: 0.18, green: 0.09, blue: 0.05).opacity(0.24)),
                    lineWidth: 0.7)
            }
        }
    }

    /// 会呼吸的亮点：一枚暖白核心、一圈朱砂柔光、四道星芒。
    /// 每个部位用自己固定的相位，亮度与大小错开起伏，像夜空里此起彼伏的星。
    /// 选中点停在最亮一档，并保留白边，方便确认刚才点的是哪里。
    private func drawHotspots(_ ctx: inout GraphicsContext,
                              camera: Pipa3DCamera,
                              face: PipaViewFace,
                              time: Date) {
        let entries = PipaPartAnnotations.entries(on: face)
        let clock = time.timeIntervalSinceReferenceDate
        for (index, info) in entries.enumerated() {
            let point = camera.project(
                PipaPartAnnotations.anchorLocal(info.part, face: face))
            let active = selected == info.part
            let phase = clock * 1.9 + Double(index) * 1.37
            let pulse = 0.5 + 0.5 * sin(phase)              // 0...1 呼吸
            let spark = pow(max(0, sin(phase * 1.7)), 6)   // 细窄的闪光尖峰
            let glow = active ? 1 : 0.42 + 0.5 * pulse

            // 柔光：三层由大到小的半透明圆，模拟光在纸上洇开。
            for layer in stride(from: 3, through: 1, by: -1) {
                let radius = (5.2 + 2.6 * pulse) * CGFloat(layer)
                let halo = Path(ellipseIn: CGRect(
                    x: point.x - radius, y: point.y - radius,
                    width: radius * 2, height: radius * 2))
                ctx.fill(halo, with: .color(PipaPalette.gold.opacity(
                    0.045 * glow / CGFloat(layer))))
            }

            // 星芒：亮点四角的细十字，只在闪光尖峰附近拉长。
            let arm = (4.2 + 4.8 * spark) * (active ? 1.15 : 1)
            let stx = PipaPalette.gold.opacity((0.25 + 0.55 * spark) * glow)
            var horizontal = Path()
            horizontal.move(to: CGPoint(x: point.x - arm, y: point.y))
            horizontal.addLine(to: CGPoint(x: point.x + arm, y: point.y))
            var vertical = Path()
            vertical.move(to: CGPoint(x: point.x, y: point.y - arm))
            vertical.addLine(to: CGPoint(x: point.x, y: point.y + arm))
            ctx.stroke(horizontal, with: .color(stx), lineWidth: 0.7)
            ctx.stroke(vertical, with: .color(stx), lineWidth: 0.7)

            // 核心：暖白内芯 + 朱砂边，呼吸改变半径。
            let r: CGFloat = (2.6 + 0.9 * pulse) * (active ? 1.35 : 1)
            let core = Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r,
                                              width: r * 2, height: r * 2))
            ctx.fill(core, with: .color(Color.white.opacity(0.9 * glow)))
            ctx.stroke(core, with: .color(PipaPalette.cinnabar.opacity(glow)),
                       lineWidth: active ? 1.5 : 0.9)
        }
    }
}

struct Pipa3DBrowseView_Previews: PreviewProvider {
    static var previews: some View {
        Pipa3DBrowseView(onEnterPlay: {})
    }
}
