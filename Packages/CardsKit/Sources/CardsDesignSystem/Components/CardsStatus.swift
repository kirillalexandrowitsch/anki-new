import SwiftUI

public enum CardsMessageKind: CaseIterable, Sendable {
    case information, success, warning, error

    var symbol: String {
        switch self {
        case .information: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .information: CardsColor.accent.color
        case .success: CardsColor.success.color
        case .warning: CardsColor.warning.color
        case .error: CardsColor.danger.color
        }
    }
}

public struct CardsBanner: View {
    private let kind: CardsMessageKind
    private let title: String
    private let message: String

    public init(_ kind: CardsMessageKind, title: String, message: String) {
        self.kind = kind
        self.title = title
        self.message = message
    }

    public var body: some View {
        HStack(alignment: .top, spacing: CardsSpacing.medium) {
            Image(systemName: kind.symbol).foregroundStyle(kind.color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CardsSpacing.xSmall) {
                Text(title).fontWeight(.semibold)
                Text(message)
            }
            .foregroundStyle(CardsColor.text.color)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .cardsText()
        .padding(CardsSpacing.large)
        .background(kind.color.opacity(0.08), in: RoundedRectangle(cornerRadius: CardsRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: CardsRadius.panel).strokeBorder(kind.color, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .onChange(of: title + ". " + message) { _, announcement in
            AccessibilityNotification.Announcement(announcement).post()
        }
    }
}

public struct CardsEmptyState<Action: View>: View {
    private let title: String
    private let symbol: String
    private let message: String
    private let action: Action

    public init(_ title: String, symbol: String, message: String, @ViewBuilder action: () -> Action) {
        self.title = title
        self.symbol = symbol
        self.message = message
        self.action = action()
    }

    public var body: some View {
        VStack(spacing: CardsSpacing.large) {
            Image(systemName: symbol).font(.system(size: 32)).accessibilityHidden(true)
            Text(title).cardsText(.sectionTitle).accessibilityAddTraits(.isHeader)
            Text(message).cardsText().foregroundStyle(CardsColor.secondaryText.color)
            action
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(CardsSpacing.panel)
        .foregroundStyle(CardsColor.text.color)
    }
}

extension CardsEmptyState where Action == EmptyView {
    public init(_ title: String, symbol: String, message: String) {
        self.init(title, symbol: symbol, message: message) { EmptyView() }
    }
}

/// Progress is indeterminate unless the caller has a real measured fraction.
/// Disable the operation's trigger in the caller while it is running.
public struct CardsLoadingState: View {
    private let title: String
    private let progress: Double?

    public init(_ title: String, progress: Double? = nil) {
        self.title = title
        self.progress = progress.map { min(1, max(0, $0)) }
    }

    public var body: some View {
        HStack(spacing: CardsSpacing.medium) {
            if let progress {
                ProgressView(value: progress).frame(maxWidth: 180)
                Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
            }
            Text(title).fixedSize(horizontal: false, vertical: true)
        }
        .cardsText()
        .foregroundStyle(CardsColor.text.color)
        .padding(CardsSpacing.large)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
