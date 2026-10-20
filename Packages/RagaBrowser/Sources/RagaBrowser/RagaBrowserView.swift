import SwiftUI
import RagaCore
import AudioKit
import DesignSystem

/// The RagaBrowser (web raga/index.html) over the compiled
/// 87-raga catalog, with the detail pushed inside one navigation
/// stack. Layout since v1.5.26 (his redesign — the old four-way
/// segmented bar felt congested): a search pill on top, a
/// scrolling chip rail for the three collections (Favourites,
/// Melakartas, Hindustani), and the search-by-swaras card
/// revealed while the search is engaged. Search is global over
/// the whole catalog, not a fourth collection. In pick mode it
/// is the live RagaPicker the swara editors present: a banner
/// explains the flow and the detail gains "✓ Use this raga".
public struct RagaBrowserView: View {
    public enum Mode { case browse, pick }

    private let library: any RagaLibrary
    private let mode: Mode
    private let onPick: ((Raga) -> Void)?
    private let onCancel: (() -> Void)?
    /// Fired when a scale starts, so the shell can stop the song
    /// and any phrase (the Varisai/Tala onPlayStart pattern — the
    /// focus registry alone cannot stop the song, which is never
    /// registered; v1.5.14).
    private let onPlayStart: () -> Void

    @StateObject private var adapter: ScaleAdapter
    @State private var collection: Collection = .favourites
    @State private var query = ""
    @State private var selectedClasses: Set<String> = []
    @State private var melSegment = 0
    @State private var openChakra: Int?
    @State private var favourites: [Raga] = []
    @FocusState private var searchFocused: Bool

    private enum Collection: Hashable, CaseIterable {
        case favourites, melakartas, hindustani
        var label: String {
            switch self {
            case .favourites: return "Favourites"
            case .melakartas: return "Melakartas"
            case .hindustani: return "Hindustani"
            }
        }
    }

    /// Filtering = the search owns the screen (typed text or at
    /// least one swara class). Mere focus shows the swara card
    /// but leaves the collection list in place.
    private var isFiltering: Bool {
        !query.isEmpty || !selectedClasses.isEmpty
    }
    private var searchEngaged: Bool { searchFocused || isFiltering }
    private var results: [Raga] {
        RagaCatalog.all.filter {
            RagaSearch.matches($0, nameQuery: query,
                               selectedClasses: selectedClasses)
        }
    }

    private func exitSearch() {
        query = ""
        selectedClasses = []
        searchFocused = false
    }

    private func selectCollection(_ picked: Collection) {
        if isFiltering { exitSearch() }
        collection = picked
    }

    public init(library: any RagaLibrary, mode: Mode = .browse,
                sequencePlayer: SequencePlayer,
                onPick: ((Raga) -> Void)? = nil,
                onCancel: (() -> Void)? = nil,
                onPlayStart: @escaping () -> Void = {}) {
        self.library = library
        self.mode = mode
        self.onPick = onPick
        self.onCancel = onCancel
        self.onPlayStart = onPlayStart
        _adapter = StateObject(wrappedValue: ScaleAdapter(player: sequencePlayer))
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
                searchBar
                collectionRail
                if searchEngaged { swaraCard }
                content
            }
            .animation(.easeInOut(duration: 0.2), value: searchEngaged)
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
                                   onPick: mode == .pick ? onPick : nil,
                                   onPlayStart: onPlayStart)
                }
            }
            .onAppear { favourites = library.favourites() }
            .onDisappear { adapter.stop() }
        }
    }

    private func resolve(_ id: String) -> Raga? {
        RagaCatalog.all.first { $0.id == id } ?? library.raga(id: id)
    }

    // MARK: - Search header (v1.5.26)

    /// The pill: magnifier + field + clear button, panel2 capsule;
    /// accent ring while focused. Cancel appears beside it while
    /// the search is engaged.
    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Studio.muted)
                TextField("Search ragas", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Studio.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Studio.panel2, in: Capsule())
            .overlay(Capsule().strokeBorder(
                searchFocused ? Studio.accent : Studio.border,
                lineWidth: searchFocused ? 1.5 : 1))
            if searchEngaged {
                Button("Cancel") { exitSearch() }
                    .foregroundStyle(Studio.accent)
            }
        }
        .padding(.horizontal)
    }

    /// The collections as a horizontally scrolling chip rail.
    /// Chips size to their words — the rail scrolls instead of
    /// squeezing (the segmented bar's congestion). A trailing
    /// fade hints the rail continues. While filtering, no chip
    /// is selected: the search owns the screen, and tapping a
    /// chip exits the search back to that collection.
    private var collectionRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Collection.allCases, id: \.self) { item in
                    StudioChip(item.label,
                               selected: !isFiltering && collection == item) {
                        selectCollection(item)
                    }
                }
            }
            .padding(.horizontal)
        }
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [Studio.bg.opacity(0), Studio.bg],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 28)
                .allowsHitTesting(false)
        }
    }

    /// FlowStack items must be Identifiable; the class names are
    /// unique, so the name is its own id.
    private struct SwaraClassItem: Identifiable {
        let cls: String
        var id: String { cls }
    }

    /// The search-by-swaras card, revealed while the search is
    /// engaged: the twelve collapsed classes as chips; results
    /// must contain them all (RagaSearch).
    private var swaraCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("SEARCH BY SWARAS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Studio.muted)
                FlowStack(items: RagaSearch.classes.map(SwaraClassItem.init),
                          spacing: 7, rowSpacing: 7) { item in
                    StudioChip(item.cls, selected: selectedClasses.contains(item.cls)) {
                        if selectedClasses.contains(item.cls) {
                            selectedClasses.remove(item.cls)
                        } else {
                            selectedClasses.insert(item.cls)
                        }
                    }
                }
                Text(isFiltering
                     ? "Contain all selected · \(results.count) ragas"
                     : "Find ragas that contain all the swaras you tap.")
                    .font(.footnote)
                    .foregroundStyle(Studio.muted)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Sections

    @ViewBuilder
    private var content: some View {
        if isFiltering {
            searchResults
        } else {
            switch collection {
            case .favourites: favouritesSection
            case .melakartas: melakartasSection
            case .hindustani: hindustaniSection
            }
        }
    }

    private var searchResults: some View {
        List {
            Section("\(results.count) ragas") {
                ForEach(results, id: \.id) { raga in
                    NavigationLink(value: raga.id) { rowLabel(raga) }
                }
            }
        }
        .studioList()
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
