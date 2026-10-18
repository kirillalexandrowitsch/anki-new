import SwiftUI

public struct CardsPanel<Content: View>: View {
    private let title: String?
    private let content: Content
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.cardsIncreasedContrast) private var forceContrast
    private var increasedContrast: Bool { systemContrast == .increased || forceContrast }

    public init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CardsSpacing.large) {
            if let title {
                Text(title).cardsText(.sectionTitle).accessibilityAddTraits(.isHeader)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CardsSpacing.panel)
        .foregroundStyle(CardsColor.text.color)
        .background(CardsColor.surface.color, in: RoundedRectangle(cornerRadius: CardsRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: CardsRadius.panel)
                .strokeBorder(increasedContrast ? CardsColor.secondaryText.color : CardsColor.separator.color,
                              lineWidth: 1)
        }
    }
}
