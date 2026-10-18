import SwiftUI

public enum CardsButtonKind: String, CaseIterable, Sendable {
    case primary, secondary, destructive
}

/// Overrides exist only inside the preview gallery. Production controls always use
/// actual hover, isPressed, focus and isEnabled values; no focusable wrapper is added.
enum ButtonPreviewState: String, CaseIterable {
    case normal, hover, pressed, disabled, focus
}

public struct CardsButtonStyle: ButtonStyle {
    private let kind: CardsButtonKind
    private let previewState: ButtonPreviewState?

    public init(_ kind: CardsButtonKind = .primary) {
        self.kind = kind
        previewState = nil
    }

    init(_ kind: CardsButtonKind, preview: ButtonPreviewState) {
        self.kind = kind
        previewState = preview
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, preview: previewState)
    }
}

private struct StyledButton: View {
    let configuration: ButtonStyle.Configuration
    let kind: CardsButtonKind
    let preview: ButtonPreviewState?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.cardsIncreasedContrast) private var forceContrast
    private var increasedContrast: Bool { systemContrast == .increased || forceContrast }
    @State private var hovered = false

    private var enabled: Bool { isEnabled && preview != .disabled }
    private var pressed: Bool { enabled && (configuration.isPressed || preview == .pressed) }
    private var focus: Bool { isFocused || preview == .focus }
    private var hover: Bool { enabled && (hovered || preview == .hover) }
    private var foreground: Color {
        guard enabled else { return CardsColor.secondaryText.color }
        switch kind {
        case .primary: return .white
        case .secondary: return CardsColor.text.color
        case .destructive: return CardsColor.danger.color
        }
    }
    private var background: Color {
        guard enabled else { return CardsColor.secondarySurface.color }
        switch kind {
        case .primary: return CardsColor.accentFill.color
        case .secondary: return CardsColor.surface.color
        case .destructive: return CardsColor.danger.color.opacity(0.04)
        }
    }

    var body: some View {
        HStack(spacing: CardsSpacing.small) {
            if !enabled { Image(systemName: "nosign").accessibilityHidden(true) }
            configuration.label
        }
        .cardsText()
        .fontWeight(.medium)
        .multilineTextAlignment(.center)
        .padding(.horizontal, CardsSpacing.large)
        .padding(.vertical, CardsSpacing.small)
        .frame(minHeight: 32)
        .foregroundStyle(foreground)
        .background {
            RoundedRectangle(cornerRadius: CardsRadius.control)
                .fill(background)
                .overlay {
                    if hover || pressed {
                        RoundedRectangle(cornerRadius: CardsRadius.control)
                            .fill(.black.opacity(pressed ? (kind == .destructive ? 0.08 : 0.14) : 0.04))
                    }
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: CardsRadius.control)
                .strokeBorder(enabled ? borderColor : CardsColor.secondaryText.color,
                              style: StrokeStyle(lineWidth: increasedContrast ? 2 : 1,
                                                 dash: enabled ? [] : [4, 3]))
        }
        .overlay {
            if focus {
                RoundedRectangle(cornerRadius: CardsRadius.control + 3)
                    .stroke(CardsColor.accent.color, lineWidth: 3)
                    .padding(-4)
            }
        }
        .offset(y: pressed ? 1 : 0)
        .contentShape(RoundedRectangle(cornerRadius: CardsRadius.control))
        .onHover { hovered = $0 }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: CardsColor.accentFill.color
        case .secondary: increasedContrast ? CardsColor.secondaryText.color : CardsColor.separator.color
        case .destructive: CardsColor.danger.color
        }
    }
}
