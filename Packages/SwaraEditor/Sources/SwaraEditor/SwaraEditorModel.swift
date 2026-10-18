import Foundation
import RagaCore

/// Picker sheet state (web swOpenPicker). One state machine drives
/// append, insert and edit flows:
/// - append/insert: the length stepper is held locally and applied to
///   the new chip at pick time;
/// - edit: the stepper writes the chip's beats live (and saves) before
///   any pick; the selection is prefilled from the chip; stack mode
///   starts on when the chip's stack has more than one entry.
public struct PickerState: Identifiable {
    public enum Action: Equatable {
        case append
        case insertAt(index: Int)
        case edit(index: Int)
    }
    public let id = UUID()
    public var action: Action
    public var title: String
    public var octave: Int = 0
    public var stackOn: Bool
    public var selection: [StackEntry]
    public var beats: Double
    /// "Now: <label>" line shown in edit mode.
    public var currentLabel: String?

    public init(action: Action, title: String, stackOn: Bool,
                selection: [StackEntry] = [], beats: Double,
                currentLabel: String? = nil) {
        self.action = action
        self.title = title
        self.stackOn = stackOn
        self.selection = selection
        self.beats = beats
        self.currentLabel = currentLabel
    }

    public var isEdit: Bool { if case .edit = action { return true }; return false }
}

/// The swara editor's view model — host-agnostic. The host (LoopLab in
/// P1, Compose in P2) supplies persistence and interlock closures.
/// Auto-save mirrors the web: every edit saves; a never-saved empty
/// phrase stays unsaved; emptying a saved phrase saves the empty phrase.
@MainActor
public final class SwaraEditorModel: ObservableObject {
    @Published public var phrase: Phrase
    @Published public var rawMode = false
    @Published public var rawText = ""
    @Published public var picker: PickerState?
    @Published public var copyConfirmed = false

    public let library: any RagaLibrary
    public let player: PhraseAdapter
    /// Playback context key for the editor surface.
    public let contextKey: String

    private var storedExists: Bool
    private let onSave: (Phrase) -> Void
    private let onDelete: () -> Void
    private let onSongRaga: (String?) -> Void
    private let onPlayStart: () -> Void
    private let contextValid: () -> Bool

    public init(phrase: Phrase,
                hadSavedPhrase: Bool,
                contextKey: String,
                library: any RagaLibrary,
                player: PhraseAdapter,
                onSave: @escaping (Phrase) -> Void,
                onDelete: @escaping () -> Void,
                onSongRaga: @escaping (String?) -> Void,
                onPlayStart: @escaping () -> Void = {},
                contextValid: @escaping () -> Bool = { true }) {
        self.phrase = phrase
        self.storedExists = hadSavedPhrase
        self.contextKey = contextKey
        self.library = library
        self.player = player
        self.onSave = onSave
        self.onDelete = onDelete
        self.onSongRaga = onSongRaga
        self.onPlayStart = onPlayStart
        self.contextValid = contextValid
    }

    // MARK: - Derived

    public var raga: Raga? { phrase.ragaId.flatMap { library.raga(id: $0) } }
    public var ragaName: String { raga?.name ?? "Chromatic" }
    public var pickerSthanas: [String] {
        raga.map(RagaCatalog.pickerList(for:)) ?? Swara.chromatic
    }
    public var isPlaying: Bool { player.isPlaying(contextKey: contextKey) }

    // MARK: - Persistence

    public func save() {
        if phrase.chips.isEmpty && !storedExists { return }
        onSave(phrase)
        storedExists = true
    }

    // MARK: - Setup changes

    /// Apply a raga chosen in the browse sheet (the interim pick
    /// flow until the real RagaBrowser lands in P3): the pick goes
    /// through the library's adoption — a scale-signature or name
    /// match resolves to the editor-table id, anything else is
    /// registered personally (rb-…) — then becomes the phrase's raga.
    public func applyBrowsedRaga(_ raga: Raga) {
        let id = library.adoptPick(RagaPick(
            sourceId: raga.id, name: raga.name,
            aro: raga.aro, ava: raga.ava))
        setRaga(id: id)
    }

    public func setRaga(id: String?) {
        phrase.ragaId = id
        onSongRaga(id)
        if let id { library.recordUse(id: id) }
        save()
        restartIfPlaying()
    }

    public func setSaOffset(_ value: Int) {
        phrase.saOffset = value
        save()
        restartIfPlaying()
    }

    public func setTempo(_ value: Int) {
        phrase.tempo = min(120, max(30, value))
        save()
        restartIfPlaying()
    }

    public func setLoop(_ value: Bool) {
        phrase.loop = value
        save()
    }

    public func deletePhrase() {
        player.stop()
        onDelete()
    }

    // MARK: - Playback

    public func togglePlay() {
        if isPlaying { player.stop() }
        else {
            onPlayStart()
            player.play(phrase: phrase, contextKey: contextKey, contextValid: contextValid)
        }
    }

    public func restartIfPlaying() {
        if isPlaying {
            player.play(phrase: phrase, contextKey: contextKey, contextValid: contextValid)
        }
    }

    public func stopPlayback() { player.stop() }

    // MARK: - Raw JSON mode

    public func enterRawMode() {
        player.stop()
        rawText = Self.rawText(for: phrase)
        rawMode = true
    }

    public func exitRawMode() { rawMode = false }

    /// Apply the raw JSON through the full sanitizer. Returns an error
    /// message on failure (web alerts), nil on success.
    public func applyRawJSON() -> String? {
        guard let data = rawText.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return "Invalid JSON — check the text and try again."
        }
        guard let clean = PhraseSanitizer.sanitize(
            data: data, isKnownRaga: { library.raga(id: $0) != nil }) else {
            return "That doesn't look like a valid phrase — check the chips and try again."
        }
        player.stop()
        phrase = clean
        onSongRaga(clean.ragaId)
        save()
        rawMode = false
        return nil
    }

    /// The web raw format: header fields in order, then the chips one
    /// per line as compact JSON.
    public static func rawText(for phrase: Phrase) -> String {
        let ragaJSON = phrase.ragaId.map { "\"\($0)\"" } ?? "null"
        var lines = [
            "{",
            "  \"ragaId\": \(ragaJSON),",
            "  \"saOffset\": \(phrase.saOffset),",
            "  \"tempo\": \(phrase.tempo),",
            "  \"loop\": \(phrase.loop ? "true" : "false"),",
        ]
        if phrase.chips.isEmpty {
            lines.append("  \"chips\": []")
        } else {
            lines.append("  \"chips\": [")
            let chipLines = phrase.chips.map { "    " + chipText($0) }
            lines.append(chipLines.joined(separator: ",\n"))
            lines.append("  ]")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// One chip as compact JSON with the web key order (k, stack,
    /// beats). Built by hand: JSONEncoder does not guarantee key
    /// order, and the raw text format is exact.
    public static func chipText(_ chip: Chip) -> String {
        switch chip.kind {
        case .note:
            let stack = chip.stack.map { entry -> String in
                if entry.isHold { return "{\"hold\":true}" }
                let st = entry.st ?? ""
                return "{\"st\":\"" + st + "\",\"oct\":\(entry.oct)}"
            }.joined(separator: ",")
            return "{\"k\":\"note\",\"stack\":[\(stack)],\"beats\":\(JSJSON.formatNumber(chip.beats))}"
        case .hold, .gap:
            return "{\"k\":\"\(chip.kind.rawValue)\",\"beats\":\(JSJSON.formatNumber(chip.beats))}"
        }
    }

    // MARK: - Picker flows

    public func openAppendPicker() {
        picker = PickerState(action: .append, title: "Append swara",
                             stackOn: false, beats: 1)
    }

    public func openEditPicker(index: Int) {
        guard phrase.chips.indices.contains(index) else { return }
        let chip = phrase.chips[index]
        let prefill: [StackEntry]
        switch chip.kind {
        case .note: prefill = chip.stack
        case .hold: prefill = [.hold]
        case .gap: prefill = []
        }
        picker = PickerState(
            action: .edit(index: index),
            title: "Edit chip #\(index + 1)",
            stackOn: chip.kind == .note && chip.stack.count > 1,
            selection: prefill,
            beats: chip.beats,
            currentLabel: "Now: \(SwaraLabel.chipLabel(chip))")
    }

    /// The insert popover in edit mode: opens an append-style picker
    /// that splices at the chosen position.
    public func openInsertPicker(before: Bool) {
        guard let current = picker, case .edit(let index) = current.action else { return }
        let at = before ? index : index + 1
        picker = PickerState(
            action: .insertAt(index: at),
            title: "Insert \(before ? "before" : "after") chip #\(index + 1)",
            stackOn: false, beats: 1)
    }

    public func pickerTapSthana(_ st: String) {
        guard var state = picker else { return }
        if state.stackOn {
            state.selection.append(StackEntry(st: st, oct: state.octave))
            picker = state
        } else {
            commit(kind: .note([StackEntry(st: st, oct: state.octave)]))
        }
    }

    public func pickerTapHold() {
        guard var state = picker else { return }
        if state.stackOn {
            state.selection.append(.hold)
            picker = state
        } else {
            commit(kind: .hold)
        }
    }

    public func pickerTapGap() { commit(kind: .gap) }
    public func pickerTapClear() { commit(kind: .clear) }

    public func pickerRemoveSelection(at index: Int) {
        guard var state = picker, state.selection.indices.contains(index) else { return }
        state.selection.remove(at: index)
        picker = state
    }

    public func pickerToggleStack() {
        guard var state = picker else { return }
        state.stackOn.toggle()
        picker = state
    }

    public func pickerSetOctave(_ octave: Int) {
        guard var state = picker else { return }
        state.octave = octave
        picker = state
    }

    /// The length stepper. Edit mode writes the chip live and saves
    /// before any pick (web onDuration); append/insert hold it locally.
    public func pickerSetBeats(_ value: Double) {
        guard var state = picker else { return }
        state.beats = min(8, max(0.25, (value * 4).rounded() / 4))
        picker = state
        if case .edit(let index) = state.action,
           phrase.chips.indices.contains(index) {
            phrase.chips[index].beats = state.beats
            save()
        }
    }

    public func pickerDone() {
        guard let state = picker, !state.selection.isEmpty else { return }
        commit(kind: .note(state.selection))
    }

    public func closePicker() { picker = nil }

    private enum CommitKind {
        case note([StackEntry])
        case hold, gap, clear
    }

    private func commit(kind: CommitKind) {
        guard let state = picker else { return }
        player.stop()
        switch state.action {
        case .append:
            if case .clear = kind { picker = nil; return } // append-mode no-op
            phrase.chips.append(chip(for: kind, beats: state.beats))
        case .insertAt(let index):
            if case .clear = kind { picker = nil; return }
            let at = min(max(index, 0), phrase.chips.count)
            phrase.chips.insert(chip(for: kind, beats: state.beats), at: at)
        case .edit(let index):
            guard phrase.chips.indices.contains(index) else { picker = nil; return }
            let beats = phrase.chips[index].beats
            switch kind {
            case .clear:
                phrase.chips.remove(at: index)
            default:
                phrase.chips[index] = chip(for: kind, beats: beats)
            }
        }
        save()
        picker = nil
    }

    private func chip(for kind: CommitKind, beats: Double) -> Chip {
        switch kind {
        case .note(let stack): return .note(stack, beats: beats)
        case .hold: return .hold(beats: beats)
        case .gap: return .gap(beats: beats)
        case .clear: return .gap(beats: beats) // unreachable (handled by callers)
        }
    }
}
