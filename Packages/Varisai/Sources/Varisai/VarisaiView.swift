import SwiftUI
import DesignSystem

/// Varisai Studio (web varisai/index.html): the seven lessons,
/// each opening its practice screen. All lessons are in
/// Mayamalavagowla; there is no raga selector (web parity).
public struct VarisaiView: View {
    private let onPlayStart: () -> Void

    public init(onPlayStart: @escaping () -> Void) {
        self.onPlayStart = onPlayStart
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(VarisaiData.lessons) { lesson in
                    NavigationLink {
                        VarisaiLessonView(lesson: lesson, onPlayStart: onPlayStart)
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
