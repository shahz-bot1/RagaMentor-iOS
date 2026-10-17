import SwiftUI
import RagaCore

/// The interim raga browse sheet (parity plan §6 P1): the editor's
/// "RagaBrowser ›" entry opens this until the real RagaBrowser module
/// replaces it in P3. Same data as the browser (the 87-raga catalog
/// plus the curated editor table), grouped and searchable. A tap
/// adopts the raga through the library (signature → editor table,
/// else personal registry) and closes the sheet.
public struct RagaBrowseSheet: View {
    public var onPick: (Raga) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    public init(onPick: @escaping (Raga) -> Void) {
        self.onPick = onPick
    }

    private func matches(_ raga: Raga) -> Bool {
        query.isEmpty || raga.name.localizedCaseInsensitiveContains(query)
    }

    private var sections: [(title: String, ragas: [Raga])] {
        let all = RagaCatalog.all
        return [
            ("Editor ragas", RagaCatalog.curated),
            ("Melakartas", all.filter { $0.melakartaNumber != nil }),
            ("Janya ragas", all.filter { $0.parentMelakarta != nil }),
            ("Hindustani", all.filter { $0.isHindustani }),
        ]
        .map { (title: $0.title, ragas: $0.ragas.filter(matches)) }
        .filter { !$0.ragas.isEmpty }
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.ragas, id: \.id) { raga in
                            Button {
                                onPick(raga)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(raga.name).foregroundStyle(.primary)
                                    Text(raga.aro.joined(separator: " "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose a raga")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search ragas")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
