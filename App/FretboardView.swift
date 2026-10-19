import SwiftUI

/// The instrument panel: a vector-drawn Pipa you actually touch.
///
/// The board is a half-pear soundboard with wood grain, four strings running
/// from the nut to the bridge, six xiang on the neck and twenty-five frets on
/// the soundboard, every stop position placed where the sounding length of the
/// string is 2^(-n/12) of the open length, exactly as on the real instrument.
///
/// Touch the board anywhere near a string and the nearest stop position
/// sounds, so the finger lands where the note is rather than on a grid cell.
/// Drag sideways across the strings to strum.
struct PipaBoardView: View {
    @EnvironmentObject private var audio: AudioEngine

    @Binding var selection: (string: Int, fret: Int)
    @Binding var litCell: (string: Int, fret: Int)?

    /// Called with the string, the stop position and the excitation point
    /// along the string, so the pluck position follows the finger.
    let onPluck: (Int, Int, Double) -> Void

    /// The stop position currently under the finger, highlighted while
    /// pressing and before the sound is committed.
    @State private var pressing: (string: Int, fret: Int)? = nil
    /// Which string is ringing, for the vibration shimmer.
    @State private var shimmerString: Int? = nil
    @State private var shimmerOffset: CGFloat = 0

    /// String gauges and sags: the Chan string is thickest and sags most.
    private let stringWidth: [CGFloat] = [2.6, 2.1, 1.6, 1.1]
    private let stringSag: [CGFloat] = [2.8, 2.2, 1.7, 1.2]

    private let woodLight = Color(red: 0.46, green: 0.25, blue: 0.14)
    private let woodMid = Color(red: 0.34, green: 0.17, blue: 0.09)
    private let woodDark = Color(red: 0.22, green: 0.10, blue: 0.05)
    private let woodEdge = Color(red: 0.16, green: 0.07, blue: 0.03)
    private let boneColor = Color(red: 0.93, green: 0.89, blue: 0.76)
    private let stringLight = Color(red: 0.90, green: 0.87, blue: 0.80)
    private let stringDark = Color(red: 0.55, green: 0.52, blue: 0.47)

    var body: some View {
        GeometryReader { geo in
            let rect = geo.frame(in: .local)
            ZStack {
                soundboard(in: rect)
                hardware(in: rect)
                strings(in: rect)
                stopPositions(in: rect)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        pressing = PipaGeometry.nearest(location: value.location, in: rect)
                    }
                    .onEnded { value in
                        let translation = value.translation
                        pressing = nil
                        if abs(translation.width) < 14, abs(translation.height) < 14 {
                            // A tap: sound the nearest stop position and use
                            // the touch point as the excitation point.
                            if let hit = PipaGeometry.nearest(location: value.location, in: rect) {
                                onPluck(hit.string, hit.fret,
                                        PipaGeometry.pluckPosition(value.location, in: rect))
                            }
                        } else if abs(translation.width) > abs(translation.height) {
                            audio.strum(ascending: translation.width > 0)
                        }
                    }
            )
            // A labelled tuple is not Equatable, so watch a string key of it.
            .onChange(of: litCell.wrappedValue.map { "\($0.string)-\($0.fret)" }) { _, _ in
                guard let hit = litCell.wrappedValue else { return }
                shimmerString = hit.string
                shimmerOffset = 0
                withAnimation(.linear(duration: 0.055).repeatCount(6, autoreverses: true)) {
                    shimmerOffset = 1.4
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    shimmerString = nil
                    shimmerOffset = 0
                }
            }
        }
    }

    // MARK: The soundboard

    private func soundboard(in rect: CGRect) -> some View {
        let body = PipaGeometry.bodyPath(in: rect)
        let grain = PipaGeometry.grainPaths(in: rect)
        return ZStack {
            body.fill(
                LinearGradient(colors: [woodLight, woodMid, woodDark],
                               startPoint: .top, endPoint: .bottom)
            )
            // Sheen across the arched face
            body.fill(
                LinearGradient(colors: [.clear, Color.white.opacity(0.10), .clear],
                               startPoint: .leading, endPoint: .trailing)
            )
            // Wood grain, clipped to the board
            ForEach(0..<grain.count, id: \.self) { index in
                grain[index]
                    .stroke(Color(red: 0.14, green: 0.06, blue: 0.02).opacity(0.30), lineWidth: 1.1)
            }
            .clipShape(body)
            body.stroke(woodEdge, lineWidth: 1.5)
        }
    }

    // MARK: Nut, xiang, frets, bridge, pegs

    private func hardware(in rect: CGRect) -> some View {
        let nutY = PipaGeometry.nutY(in: rect)
        let bridgeY = PipaGeometry.bridgeY(in: rect)
        let left = PipaGeometry.stringX(0, in: rect)
        let right = PipaGeometry.stringX(PipaGeometry.stringCount - 1, in: rect)
        return ZStack {
            // 山口
            fretLine(x1: left - 7, y: nutY, x2: right + 7, width: 2.6, opacity: 0.75)
            // 相 on the neck, 品 on the soundboard
            ForEach(1..<PipaGeometry.positionCount, id: \.self) { position in
                let xiang = PipaGeometry.isXiang(position)
                fretLine(x1: left - 4,
                         y: PipaGeometry.positionY(position, in: rect),
                         x2: right + 4,
                         width: xiang ? 1.7 : 1.1,
                         opacity: xiang ? 0.60 : 0.42)
            }
            // 覆手
            PipaGeometry.bridgePath(in: rect)
                .fill(Color(red: 0.13, green: 0.06, blue: 0.03))
            PipaGeometry.bridgePath(in: rect)
                .stroke(Color(red: 0.05, green: 0.02, blue: 0.01), lineWidth: 1)
            // Four string seats on the bridge
            ForEach(0..<PipaGeometry.stringCount, id: \.self) { string in
                Circle()
                    .fill(boneColor)
                    .frame(width: 4, height: 4)
                    .position(x: PipaGeometry.stringX(string, in: rect), y: bridgeY)
            }
            // 轸子
            ForEach(0..<PipaGeometry.pegPoints(in: rect).count, id: \.self) { index in
                let peg = PipaGeometry.pegPoints(in: rect)[index]
                Circle()
                    .fill(woodDark)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(boneColor.opacity(0.5), lineWidth: 1))
                    .position(peg)
            }
        }
    }

    private func fretLine(x1: CGFloat, y: CGFloat, x2: CGFloat,
                          width: CGFloat, opacity: Double) -> some View {
        Path { path in
            path.move(to: CGPoint(x: x1, y: y))
            path.addLine(to: CGPoint(x: x2, y: y))
        }
        .stroke(boneColor.opacity(opacity), lineWidth: width)
    }

    // MARK: The four strings

    private func strings(in rect: CGRect) -> some View {
        let nutY = PipaGeometry.nutY(in: rect)
        let bridgeY = PipaGeometry.bridgeY(in: rect)
        return ForEach(0..<PipaGeometry.stringCount, id: \.self) { string in
            let x = PipaGeometry.stringX(string, in: rect)
            let sag = stringSag[string]
            Path { path in
                path.move(to: CGPoint(x: x, y: nutY))
                path.addQuadCurve(to: CGPoint(x: x, y: bridgeY),
                                  control: CGPoint(x: x + sag, y: (nutY + bridgeY) / 2))
            }
            .stroke(LinearGradient(colors: [stringLight, stringDark],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: stringWidth[string])
            .offset(x: shimmerString == string ? shimmerOffset : 0)
        }
    }

    // MARK: Stop positions

    private func stopPositions(in rect: CGRect) -> some View {
        ForEach(0..<PipaGeometry.stringCount, id: \.self) { string in
            ForEach(0..<PipaGeometry.positionCount, id: \.self) { fret in
                let point = CGPoint(x: PipaGeometry.stringX(string, in: rect),
                                    y: PipaGeometry.positionY(fret, in: rect))
                let isSelected = selection.string == string && selection.fret == fret
                let isLit = litCell?.string == string && litCell?.fret == fret
                let isPressing = pressing?.string == string && pressing?.fret == fret
                Circle()
                    .fill(isLit ? Color.orange
                                : Color.white.opacity(isPressing ? 0.95 : isSelected ? 0.65 : 0.28))
                    .frame(width: isLit || isPressing ? 9 : 5,
                           height: isLit || isPressing ? 9 : 5)
                    .overlay(
                        Circle()
                            .stroke(Color.orange.opacity(isSelected ? 0.85 : 0), lineWidth: 1.2)
                    )
                    .shadow(color: isLit ? Color.orange.opacity(0.8) : .clear, radius: isLit ? 5 : 0)
                    .position(point)
                    .animation(.easeOut(duration: 0.18), value: isLit)
            }
        }
    }
}

struct PipaBoardView_Previews: PreviewProvider {
    static var previews: some View {
        PipaBoardView(selection: .constant((3, 7)), litCell: .constant(nil)) { _, _, _ in }
            .environmentObject(AudioEngine())
            .preferredColorScheme(.dark)
    }
}
