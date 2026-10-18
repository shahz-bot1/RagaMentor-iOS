import SwiftUI
import RagaCore
import DesignSystem

/// The v14 piano: display + highlight only, no tap handlers (web
/// parity). Geometry ported from the web: a rel −1…13 strip; white
/// key width = full width / (white keys in rel 0…12), with a +0.62
/// denominator correction when Sa is a black key; black keys are
/// 0.62× white width and 62% height. In-scale keys are tinted
/// (white #dbeafe, black #1e3a5f); the playing note lights accent.
struct PianoView: View {
    /// Sa's pitch class (0–11) — decides which rels are white keys.
    let saPitchClass: Int
    /// Pitch classes (rel Sa, 0–11) in the raga's scale.
    let scalePitchClasses: Set<Int>
    /// Rel semitone currently sounding (0…12+), or nil.
    let highlightRel: Int?
    /// Western labels when true, Sargam class names when false.
    let westernLabels: Bool

    private static let whitePitchClasses: Set<Int> = [0, 2, 4, 5, 7, 9, 11]
    private static let sargamByPitchClass =
        ["S", "R1", "R2", "G2", "G3", "M1", "M2", "P", "D1", "D2", "N2", "N3"]

    private func isWhite(rel: Int) -> Bool {
        Self.whitePitchClasses.contains(((saPitchClass + rel) % 12 + 12) % 12)
    }

    private func pitchClass(rel: Int) -> Int {
        ((rel % 12) + 12) % 12
    }

    private func label(rel: Int) -> String {
        if westernLabels {
            return ScaleNotation.western(pitchClass: saPitchClass + rel)
        }
        return Self.sargamByPitchClass[pitchClass(rel: rel)]
    }

    var body: some View {
        GeometryReader { geo in
            let whitesInSpan = (0...12).filter { isWhite(rel: $0) }.count
            let whiteW = geo.size.width
                / (CGFloat(whitesInSpan) + (isWhite(rel: 0) ? 0 : 0.62))
            let blackW = whiteW * 0.62
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach((-1...13).filter { isWhite(rel: $0) }, id: \.self) { rel in
                        keyView(rel: rel, width: whiteW,
                                height: geo.size.height, black: false)
                    }
                }
                ForEach((-1...13).filter { !isWhite(rel: $0) }, id: \.self) { rel in
                    let whitesBefore = (-1..<rel).filter { isWhite(rel: $0) }.count
                    keyView(rel: rel, width: blackW,
                            height: geo.size.height * 0.62, black: true)
                        .offset(x: CGFloat(whitesBefore) * whiteW - blackW / 2)
                }
            }
            .clipped()
        }
        .frame(height: 110)
    }

    private func keyView(rel: Int, width: CGFloat, height: CGFloat,
                         black: Bool) -> some View {
        let inScale = scalePitchClasses.contains(pitchClass(rel: rel))
        let isNow = highlightRel == rel
        let fill: Color = isNow
            ? Studio.accent
            : black
                ? (inScale ? Color(red: 0.118, green: 0.227, blue: 0.373) : Color(red: 0.08, green: 0.09, blue: 0.11))
                : (inScale ? Color(red: 0.859, green: 0.918, blue: 0.996) : Color.white)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
            Text(label(rel: rel))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isNow ? .white : (black ? .white : .black.opacity(0.65)))
                .padding(.bottom, 3)
        }
        .frame(width: width, height: height)
    }
}
