import SwiftUI

/// Validation belongs to the caller. This control only renders a message and keeps
/// the label, help and error available independently of the placeholder or color.
public struct CardsField: View {
    private let title: String
    private let prompt: String
    private let help: String?
    private let error: String?
    @Binding private var text: String
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.cardsIncreasedContrast) private var forceContrast
    private var increasedContrast: Bool { systemContrast == .increased || forceContrast }
    @FocusState private var focused: Bool

    public init(_ title: String, text: Binding<String>, prompt: String = "",
                help: String? = nil, error: String? = nil) {
        self.title = title
        _text = text
        self.prompt = prompt
        self.help = help
        self.error = error
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CardsSpacing.small) {
            Text(title).fontWeight(.medium)
            TextField(title, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(CardsSpacing.small)
                .frame(minHeight: 32)
                .background(CardsColor.surface.color, in: RoundedRectangle(cornerRadius: CardsRadius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: CardsRadius.control)
                        .strokeBorder(error == nil ? CardsColor.secondaryText.color : CardsColor.danger.color,
                                      style: StrokeStyle(lineWidth: error == nil && !increasedContrast ? 1 : 2,
                                                         dash: enabled ? [] : [4, 3]))
                }
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: CardsRadius.control + 3)
                            .stroke(CardsColor.accent.color, lineWidth: 3)
                            .padding(-4)
                    }
                }
                .accessibilityLabel(title)
                .accessibilityValue(error.map { text + ". " + $0 } ?? text)
                .accessibilityHint([help, error].compactMap { $0 }.joined(separator: ". "))
                .help([help, error].compactMap { $0 }.joined(separator: ". "))
            if let help {
                Text(help).cardsText(.caption).foregroundStyle(CardsColor.secondaryText.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .cardsText(.caption)
                    .foregroundStyle(CardsColor.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !enabled {
                Label(String(localized: "Недоступно", bundle: .module), systemImage: "nosign")
                    .cardsText(.caption).foregroundStyle(CardsColor.secondaryText.color)
            }
        }
        .cardsText()
        .foregroundStyle(CardsColor.text.color)
    }
}
