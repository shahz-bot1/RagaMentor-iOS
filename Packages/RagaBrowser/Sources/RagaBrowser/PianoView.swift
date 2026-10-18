import SwiftUI
import RagaCore
import DesignSystem

/// The v14 piano: display + highlight only, no tap handlers (web
/// parity). Layout comes from RagaCore's PianoGeometry — the exact
/// web rule: keys resize proportionally to the container, Sa's left
/// edge sits at 0 and Sa′ ends at exactly 100%, with the neighbour
/// keys bleeding off both ends. Only in-scale keys (rel 0…12) are
/// tinted and labelled; the playing note lights accent.
struct PianoView: View {
    /// Sa's pitch class (0–11) — decides which rels are white keys.
    let saPitchClass: Int
    /// Labels by rel (0…12), present exactly for in-scale keys.
    let labels: [Int: String]
    /// Rel semitone currently sounding (0…12), or nil.
    let highlightRel: Int?

    var body: some View {
        GeometryReader { geo in
            let keys = PianoGeometry.keys(saPitchClass: saPitchClass)
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                ForEach(keys.filter { !$0.isBlack }, id: \.rel) { key in
                    keyView(key, containerW: w, containerH: h)
                }
                ForEach(keys.filter { $0.isBlack }, id: \.rel) { key in
                    keyView(key, containerW: w, containerH: h)
                }
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .frame(height: 110)
    }

    private func keyView(_ key: PianoKeyGeometry,
                         containerW: CGFloat, containerH: CGFloat) -> some View {
        let inScale = labels[key.rel] != nil
        let isNow = highlightRel == key.rel
        let fill: Color
        if isNow {
            fill = Studio.accent
        } else if key.isBlack {
            fill = inScale ? Color(red: 0.118, green: 0.227, blue: 0.373)
                           : Color(red: 0.133, green: 0.133, blue: 0.133)
        } else {
            fill = inScale ? Color(red: 0.859, green: 0.918, blue: 0.996)
                           : Color(red: 0.973, green: 0.973, blue: 0.973)
        }
        let keyW = CGFloat(key.width) / 100 * containerW
        let keyH = key.isBlack ? containerH * 0.62 : containerH
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
            if let label = labels[key.rel] {
                Text(label)
                    .font(.system(size: key.isBlack ? 9 : 10,
                                  weight: inScale ? .bold : .medium))
                    .foregroundStyle(isNow ? .white
                        : key.isBlack
                            ? Color(red: 0.49, green: 0.72, blue: 1.0)
                            : Studio.accent)
                    .padding(.bottom, key.isBlack ? 5 : 6)
            }
        }
        .frame(width: keyW, height: keyH)
        .position(x: CGFloat(key.left + key.width / 2) / 100 * containerW,
                  y: keyH / 2)
    }
}
