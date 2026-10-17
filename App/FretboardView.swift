import SwiftUI

/// Position board: one row per string, thirty-one positions each including the
/// open string. Tap any cell to sound it; drag horizontally across the board to
/// strum.
struct FretboardView: View {
    @EnvironmentObject private var audio: AudioEngine

    @Binding var selection: (string: Int, fret: Int)
    @Binding var litCell: (string: Int, fret: Int)?

    let onPluck: (Int, Int) -> Void

    private let stringNames = ["缠弦", "老弦", "中弦", "子弦"]
    private let fretCount = PipaTuning.positionCount   // 32: open string + six xiang + twenty-five frets
    /// Real position-marker locations on a Pipa soundboard.
    private let markers = Set([7, 12, 19, 25])

    var body: some View {
        VStack(spacing: 0) {
            // Position scale
            HStack(spacing: 0) {
                Color.clear.frame(width: 64)
                HStack(spacing: 0) {
                    ForEach(0..<fretCount, id: \.self) { fret in
                        Text(markers.contains(fret) ? "\(fret)" : "")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: cellWidth, height: 16)
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            Divider().overlay(Color.white.opacity(0.2))

            // The four strings
            ForEach(0..<4) { string in
                HStack(spacing: 0) {
                    Text(stringNames[string])
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 64, alignment: .trailing)
                        .padding(.trailing, 8)
                    HStack(spacing: 0) {
                        ForEach(0..<fretCount, id: \.self) { fret in
                            cell(string: string, fret: fret)
                        }
                    }
                }
                Divider().overlay(Color.white.opacity(0.12))
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.sRGB, red: 0.11, green: 0.10, blue: 0.13, opacity: 1))
        )
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    audio.strum(ascending: value.translation.width > 0)
                }
        )
    }

    private func cell(string: Int, fret: Int) -> some View {
        let isSelected = selection.string == string && selection.fret == fret
        let isLit = litCell?.string == string && litCell?.fret == fret
        let isMarker = markers.contains(fret)

        return Button {
            onPluck(string, fret)
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(fillColor(isLit: isLit, isSelected: isSelected, isMarker: isMarker))
                .frame(width: cellWidth, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(isSelected ? Color.orange : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func fillColor(isLit: Bool, isSelected: Bool, isMarker: Bool) -> Color {
        if isLit { return Color.orange.opacity(0.85) }
        if isMarker { return Color(.sRGB, red: 0.26, green: 0.24, blue: 0.30, opacity: 1) }
        return Color(.sRGB, red: 0.18, green: 0.17, blue: 0.21, opacity: 1)
    }

    private let cellWidth: CGFloat = 26
}

struct FretboardView_Previews: PreviewProvider {
    static var previews: some View {
        FretboardView(selection: .constant((3, 7)), litCell: .constant(nil)) { _, _ in }
            .environmentObject(AudioEngine())
            .preferredColorScheme(.dark)
    }
}
