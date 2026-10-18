import SwiftUI
import RagaCore
import DesignSystem

/// The tala wheel (web geometry, TalaSpec.wheelDots): dots from
/// the top clockwise, anga gaps, the samam dot in gold, the live
/// beat in accent, and the combination name + formula at centre.
struct TalaWheelView: View {
    let talaId: String
    let jatiId: String
    let currentBeat: Int

    @Environment(\.colorScheme) private var scheme

    private var samamGold: Color {
        scheme == .dark
            ? Color(red: 1.0, green: 0.82, blue: 0.4)
            : Color(red: 0.85, green: 0.6, blue: 0.09)
    }

    var body: some View {
        let dots = TalaSpec.wheelDots(talaId: talaId, jatiId: jatiId)
        GeometryReader { geo in
            let scale = geo.size.width / 280
            ZStack {
                ForEach(dots.indices, id: \.self) { i in
                    let dot = dots[i]
                    let isCurrent = i == currentBeat
                    Circle()
                        .fill(isCurrent ? Studio.accent
                              : dot.isSamam ? samamGold : Color.clear)
                        .overlay(
                            Circle().strokeBorder(
                                isCurrent ? Studio.accent
                                    : dot.isSamam ? samamGold : Studio.muted,
                                lineWidth: (isCurrent || dot.isSamam ? 2.5 : 2) * scale))
                        .frame(width: dot.radius * 2 * scale,
                               height: dot.radius * 2 * scale)
                        .position(x: dot.x * scale, y: dot.y * scale)
                }
                VStack(spacing: 4) {
                    Text(TalaSpec.comboName(talaId: talaId, jatiId: jatiId))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(
                            TalaSpec.isAdi(talaId: talaId, jatiId: jatiId)
                                ? samamGold : Studio.text)
                    Text(TalaSpec.cycleLine(talaId: talaId, jatiId: jatiId))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 170 * scale)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
