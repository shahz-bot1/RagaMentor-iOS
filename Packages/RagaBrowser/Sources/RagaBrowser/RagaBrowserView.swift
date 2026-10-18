import SwiftUI
import RagaCore
import DesignSystem

/// The RagaBrowser (web raga/index.html): Search, Favourites,
/// Melakartas and Hindustani over the compiled 87-raga catalog,
/// with the detail pushed inside one navigation stack. In pick mode
/// it is the live RagaPicker the swara editors present: a banner
/// explains the flow and the detail gains "✓ Use this raga".
public struct RagaBrowserView: View {
    public enum Mode { case browse, pick }

    private let library: any RagaLibrary
    private let mode: Mode
    private let onPick: ((Raga) -> Void)?
    private let onCancel: (() -> Void)?

    @StateObject private var adapter = ScaleAdapter()
    @State private var section: Tab = .search
    @State private var query = ""
    @State private var selectedClasses: Set<String> = []
    @State private var melSegment = 0
    @State private var openChakra: Int?
    @State private var favourites: [Raga] = []

    private enum Tab: Hashable { case search, favourites, melakartas, hindustani }

    public init(library: any RagaLibrary, mode: Mode = .browse,
                onPick: ((Raga) -> Void)? = nil,
                onCancel: (() -> Void)? = nil) {
        self.library = library
        self.mode = mode
        self.onPick = onPick
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                if mode == .pick {
                    Text("🎼 **Pick a raga for your composition.** Open any raga and tap **Use this raga** — you'll go straight back with it applied, and it joins your Favourites in the composers.")
                        .font(.footnote)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Studio.panel, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Studio.accent, lineWidth: 1.5))
                        .padding(.horizontal)
                }
                StudioSegmented(
                    items: [(Tab.search, "Search"), (.favourites, "Favourites"),
                            (.melakartas, "Melakartas"), (.hindustani, "Hindustani")],
                    selection: $section)
                    .padding(.horizontal)
                content
            }
            .padding(.top, 10)
            .background(Studio.bg.ignoresSafeArea())
            .navigationTitle(mode == .pick ? "Pick a raga" : "Raga Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if mode == .pick, let onCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let raga = resolve(id) {
                    RagaDetailView(raga: raga, library: library, adapter: adapter,
                                   onPick: mode == .pick ? onPick : nil)
                }
            }
            .onAppear { favourites = library.favourites() }
            .onDisappear { adapter.stop() }
        }
    }

    private func resolve(_ id: String) -> Raga? {
        RagaCatalog.all.first { $0.id == id } ?? library.raga(id: id)
    }

    // MARK: - Sections

    @ViewBuilder
    private var content: some View {
        switch section {
        case .search: searchSection
        case .favourites: favouritesSection
        case .melakartas: melakartasSection
        case .hindustani: hindustaniSection
        }
    }

    private var searchSection: some View {
        VStack(spacing: 10) {
            TextField("Search by name", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)],
                      spacing: 8) {
                ForEach(RagaSearch.classes, id: \.self) { cls in
                    StudioChip(cls, selected: selectedClasses.contains(cls)) {
                        if selectedClasses.contains(cls) {
                            selectedClasses.remove(cls)
                        } else {
                            selectedClasses.insert(cls)
                        }
                    }
                }
            }
            .padding(.horizontal)

            if query.isEmpty && selectedClasses.isEmpty {
                Spacer()
                Text("Search by name, or tap swaras to find ragas that contain them all.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            } else {
                let results = RagaCatalog.all.filter {
                    RagaSearch.matches($0, nameQuery: query,
                                       selectedClasses: selectedClasses)
                }
                List {
                    Section("\(results.count) ragas") {
                        ForEach(results, id: \.id) { raga in
                            NavigationLink(value: raga.id) { rowLabel(raga) }
                        }
                    }
                }
                .studioList()
            }
        }
    }

    private var favouritesSection: some View {
        List {
            if favourites.isEmpty {
                Text("No favourites yet. Open a raga and tap the star to keep it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(favourites, id: \.id) { raga in
                NavigationLink(value: raga.id) { rowLabel(raga) }
            }
        }
        .studioList()
    }

    private var melakartasSection: some View {
        VStack(spacing: 10) {
            StudioSegmented(items: [(0, "M1 · 1–36"), (1, "M2 · 37–72"), (2, "All 72")],
                            selection: $melSegment)
                .padding(.horizontal)
                .onChange(of: melSegment) { _, _ in openChakra = nil }
            List {
                if melSegment == 2 {
                    // All 72: one flat list, no chakra grouping.
                    Section {
                        ForEach(flatMelakartas, id: \.id) { raga in
                            NavigationLink(value: raga.id) { rowLabel(raga) }
                        }
                    }
                } else {
                    ForEach(chakraGroups, id: \.chakra) { group in
                        chakraSection(group)
                    }
                }
            }
            .studioList()
        }
    }

    @ViewBuilder
    private func chakraSection(_ group: (chakra: Int, ragas: [Raga])) -> some View {
        Section {
            if openChakra == group.chakra {
                ForEach(group.ragas, id: \.id) { raga in
                    NavigationLink(value: raga.id) { rowLabel(raga) }
                }
            }
        } header: {
            Button {
                openChakra = openChakra == group.chakra ? nil : group.chakra
            } label: {
                HStack {
                    Text("Chakra \(group.chakra + 1) · \(Melakarta.chakraNames[group.chakra])")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Studio.text)
                    Spacer()
                    Text(openChakra == group.chakra ? "▾" : "▸")
                        .foregroundStyle(.secondary)
                }
            }
            .textCase(nil)
        }
    }

    private var flatMelakartas: [Raga] {
        RagaCatalog.all
            .filter { $0.melakartaNumber != nil }
            .sorted { ($0.melakartaNumber ?? 0) < ($1.melakartaNumber ?? 0) }
    }

    private var chakraGroups: [(chakra: Int, ragas: [Raga])] {
        let melakartas = RagaCatalog.all.filter { raga in
            guard let n = raga.melakartaNumber else { return false }
            switch melSegment {
            case 0: return n <= 36
            case 1: return n >= 37
            default: return true
            }
        }
        return Dictionary(grouping: melakartas) {
            Melakarta.chakraIndex(forNumber: $0.melakartaNumber ?? 1)
        }
        .sorted { $0.key < $1.key }
        .map { (chakra: $0.key, ragas: $0.value.sorted {
            ($0.melakartaNumber ?? 0) < ($1.melakartaNumber ?? 0)
        }) }
    }

    private var hindustaniSection: some View {
        List {
            ForEach(thaatGroups, id: \.thaat) { group in
                Section(group.thaat) {
                    ForEach(group.ragas, id: \.id) { raga in
                        NavigationLink(value: raga.id) { rowLabel(raga) }
                    }
                }
            }
        }
        .studioList()
    }

    private var thaatGroups: [(thaat: String, ragas: [Raga])] {
        var order: [String] = []
        var grouped: [String: [Raga]] = [:]
        for raga in RagaCatalog.all where raga.isHindustani {
            let thaat = raga.thaat ?? "Other"
            if grouped[thaat] == nil { order.append(thaat) }
            grouped[thaat, default: []].append(raga)
        }
        return order.map { (thaat: $0, ragas: grouped[$0] ?? []) }
    }

    private func rowLabel(_ raga: Raga) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(raga.name)
            Text(subtitle(raga))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func subtitle(_ raga: Raga) -> String {
        if let n = raga.melakartaNumber { return "Melakarta \(n) · \(raga.jati ?? "")" }
        if let parent = raga.parentMelakarta { return "Janya of \(parent) · \(raga.jati ?? "")" }
        if let thaat = raga.thaat { return "Hindustani · Thaat \(thaat)" }
        return raga.jati ?? ""
    }
}
