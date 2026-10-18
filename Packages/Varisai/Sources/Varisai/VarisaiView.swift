import SwiftUI
import DesignSystem
import AudioKit

/// Varisai Studio (web varisai/index.html): the seven lessons,
/// each opening its practice screen. All lessons are in
/// Mayamalavagowla; there is no raga selector (web parity).
public struct VarisaiView: View {
    private let onPlayStart: () -> Void
    /// The app's one shared sequence player (P-E), handed down
    /// to each lesson's adapter.
    private let sequencePlayer: SequencePlayer

    public init(onPlayStart: @escaping () -> Void,
                sequencePlayer: SequencePlayer) {
        self.onPlayStart = onPlayStart
        self.sequencePlayer = sequencePlayer
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(VarisaiData.lessons) { lesson in
                    NavigationLink {
                        VarisaiLessonView(lesson: lesson,
                                          onPlayStart: onPlayStart,
                                          sequencePlayer: sequencePlayer)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(lesson.num) · \(lesson.name)")
                            Text(lesson.desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .studioList()
            .navigationTitle("Varisai Studio")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
