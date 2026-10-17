import SwiftUI
import RagaCore
import DesignSystem

/// The swara picker sheet (web swOpenPicker): octave segmented control,
/// the raga's sthana grid (or all 16 when Chromatic), hold/gap/clear
/// specials, the ¼-step length stepper, and stack mode with its
/// ordered selection strip. In edit mode an insert menu (＋) offers
/// Insert before/after.
public struct SwaraPickerSheet: View {
    @ObservedObject public var model: SwaraEditorModel
    @State private var showInsertMenu = false

    public init(model: SwaraEditorModel) {
        self.model = model
    }

    public var body: some View {
        if let picker = model.picker {
            content(picker)
        } else {
            Color.clear
        }
    }

    private func content(_ picker: PickerState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(picker.title).font(.headline)
                Spacer()
                if picker.isEdit {
                    Menu {
                        Button("Insert before") {
                            model.openInsertPicker(before: true)
                        }
                        Button("Insert after") {
                            model.openInsertPicker(before: false)
                        }
                    } label: {
                        Text("＋").font(.title3.weight(.medium))
                    }
                }
            }

            if let current = picker.currentLabel {
                Text(current).foregroundStyle(.secondary).font(.callout)
            }

            Picker("Octave", selection: Binding(
                get: { picker.octave }, set: { model.pickerSetOctave($0) })) {
                Text("low (˙S)").tag(-1)
                Text("middle").tag(0)
                Text("high (S˙)").tag(1)
            }
            .pickerStyle(.segmented)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 8)], spacing: 8) {
                ForEach(model.pickerSthanas, id: \.self) { st in
                    let picked = picker.stackOn && picker.selection.contains {
                        !$0.isHold && $0.st == st && $0.oct == picker.octave
                    }
                    Button(st) { model.pickerTapSthana(st) }
                        .buttonStyle(.bordered)
                        .tint(picked ? DesignTokens.accent : .secondary)
                        .font(.callout.weight(.medium))
                }
            }

            HStack(spacing: 8) {
                Button(", hold") { model.pickerTapHold() }.buttonStyle(.bordered)
                Button("– gap") { model.pickerTapGap() }.buttonStyle(.bordered)
                Button("✕ clear") { model.pickerTapClear() }.buttonStyle(.bordered)
                Spacer()
            }

            HStack {
                Text("Length").foregroundStyle(.secondary)
                Spacer()
                Button("−") { model.pickerSetBeats(picker.beats - 0.25) }
                    .buttonStyle(.bordered)
                    .disabled(picker.beats <= 0.25)
                Text(Swara.durationLabel(picker.beats))
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 74)
                Button("＋") { model.pickerSetBeats(picker.beats + 0.25) }
                    .buttonStyle(.bordered)
                    .disabled(picker.beats >= 8)
            }

            HStack(alignment: .top, spacing: 10) {
                Button("Stack ＋") { model.pickerToggleStack() }
                    .buttonStyle(.bordered)
                    .tint(picker.stackOn ? DesignTokens.accent : .secondary)
                if picker.stackOn {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if picker.selection.isEmpty {
                                Text("tap swaras…").foregroundStyle(.secondary)
                            }
                            ForEach(Array(picker.selection.enumerated()), id: \.offset) { idx, entry in
                                Button {
                                    model.pickerRemoveSelection(at: idx)
                                } label: {
                                    HStack(spacing: 3) {
                                        Text(selectionLabel(entry))
                                        Text("×").foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .font(.callout)
                            }
                        }
                    }
                    Button("Done") { model.pickerDone() }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignTokens.accent)
                        .disabled(picker.selection.isEmpty)
                }
            }

            Text(picker.stackOn
                 ? "tap several in order · tap a selected chip to remove · then ✓ Done"
                 : (model.raga.map { "\($0.name) · tap a swara, or hold/gap/clear" }
                    ?? "Chromatic · all 16 sthanas"))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding()
        .presentationDetents([.medium, .large])
    }

    /// Selection strip label (web selLabel): ASCII apostrophe/dot form.
    private func selectionLabel(_ entry: StackEntry) -> String {
        if entry.isHold { return "," }
        let st = entry.st ?? ""
        return st + (entry.oct > 0 ? "'" : entry.oct < 0 ? "." : "")
    }
}
