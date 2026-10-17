import SwiftUI

/// Studio components (PARITY-PLAN §10): the web suite's card,
/// segmented control, chip and button language as SwiftUI. Behaviour
/// stays native; only the visual language matches the web.

/// A web .card: panel fill, 1px border, 14pt radius, 16pt padding.
public struct StudioCard<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Studio.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Studio.border, lineWidth: 1))
    }
}

/// A web .card h2: 14pt, uppercase, letterspaced, muted.
public struct StudioSectionTitle: View {
    private let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.subheadline)
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Studio.muted)
    }
}

/// A web .seg: panel2 track, selected segment accent-filled with a
/// white semibold label.
public struct StudioSegmented<Value: Hashable>: View {
    private let items: [(value: Value, label: String)]
    @Binding private var selection: Value

    public init(items: [(Value, String)], selection: Binding<Value>) {
        self.items = items.map { (value: $0.0, label: $0.1) }
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                Button(item.label) { selection = item.value }
                    .font(.callout.weight(selection == item.value ? .semibold : .regular))
                    .foregroundStyle(selection == item.value ? Color.white : Studio.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(selection == item.value ? Studio.accent : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Studio.panel2, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A web pill chip: panel2 fill + border; selected = accent-soft fill
/// with an accent border.
public struct StudioChip: View {
    private let title: String
    private let selected: Bool
    private let action: () -> Void

    public init(_ title: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(title, action: action)
            .font(.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(Studio.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? Studio.accentSoft : Studio.panel2,
                        in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Studio.accent : Studio.border,
                                             lineWidth: 1))
            .buttonStyle(.plain)
    }
}

/// The transport play button: a 54pt accent circle with a white glyph.
public struct StudioRoundButton: View {
    private let systemImage: String
    private let diameter: CGFloat
    private let filled: Bool
    private let action: () -> Void

    public init(systemImage: String, diameter: CGFloat = 54, filled: Bool = true,
                action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.diameter = diameter
        self.filled = filled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundStyle(filled ? Color.white : Studio.text)
                .frame(width: diameter, height: diameter)
                .background(filled ? Studio.accent : Studio.panel2, in: Circle())
                .overlay(Circle().strokeBorder(filled ? Color.clear : Studio.border,
                                               lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Accent-filled primary button (web .btn primary).
public struct StudioPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Studio.accent.opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Bordered transparent secondary button (web .btn).
public struct StudioSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(Studio.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Studio.panel2.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Studio.border, lineWidth: 1))
    }
}

public extension View {
    /// The studio screen background (web body background).
    func studioBackground() -> some View {
        background(Studio.bg.ignoresSafeArea())
    }

    /// Studio styling for a List/Form: transparent chrome over the
    /// studio background, rows on panels.
    func studioList() -> some View {
        scrollContentBackground(.hidden)
            .background(Studio.bg.ignoresSafeArea())
            .listRowBackground(Studio.panel)
    }
}
