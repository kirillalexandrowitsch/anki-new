import AppKit
import SwiftUI

/// Native dynamic colors resolve with the view appearance, including previews.
/// No asset compiler is required by command-line SwiftPM on the macOS 15 toolchain.
public enum CardsColor: String, CaseIterable, Sendable {
    case window, surface, secondarySurface, text, secondaryText, separator
    case accent, accentFill, success, warning, danger

    public var color: Color {
        let pair: (UInt32, UInt32) = switch self {
        case .window: (0xF6F6F8, 0x1C1D22)
        case .surface: (0xFFFFFF, 0x272930)
        case .secondarySurface: (0xEFEFF4, 0x22242B)
        case .text: (0x24262D, 0xF4F5F8)
        case .secondaryText: (0x656B78, 0xB2B8C6)
        case .separator: (0xDDE0E8, 0x434753)
        case .accent: (0x4F5FF5, 0x8792FF)
        case .accentFill: (0x4F5FF5, 0x4F5FF5)
        // Slightly darker light variants keep actual text/control pairs above 4.5:1.
        case .success: (0x20865B, 0x6BD3A2)
        case .warning: (0xA7650A, 0xF2BE64)
        case .danger: (0xB32939, 0xFF8B95)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? pair.1 : pair.0
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

public enum CardsSpacing {
    public static let xSmall: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    public static let panel: CGFloat = 24
    public static let section: CGFloat = 32
}

public enum CardsRadius {
    public static let control: CGFloat = 8
    public static let panel: CGFloat = 12
    public static let card: CGFloat = 16
}

public enum CardsTextStyle: CaseIterable, Sendable {
    case windowTitle, sectionTitle, body, caption, studyWord, translation

    var size: CGFloat {
        switch self {
        case .windowTitle: 28
        case .sectionTitle: 20
        case .body: 15
        case .caption: 13
        case .studyWord: 40
        case .translation: 22
        }
    }

    var weight: Font.Weight {
        switch self {
        case .windowTitle, .sectionTitle, .studyWord: .semibold
        default: .regular
        }
    }

    var relativeStyle: Font.TextStyle {
        switch self {
        case .windowTitle: .largeTitle
        case .sectionTitle, .translation: .title2
        case .body: .body
        case .caption: .caption
        case .studyWord: .largeTitle
        }
    }
}

/// An additional app text multiplier; system scaling still applies via ScaledMetric.
/// macOS versions without a system text-size preference can use this environment.
public enum CardsTextScale: CGFloat, CaseIterable, Sendable {
    case standard = 1
    case enlarged = 1.35
}

private struct CardsIncreasedContrastKey: EnvironmentKey {
    static let defaultValue = false
}

private struct CardsTextScaleKey: EnvironmentKey {
    static let defaultValue = CardsTextScale.standard
}

extension EnvironmentValues {
    /// A preview/app override can increase contrast; it never lowers the system setting.
    public var cardsIncreasedContrast: Bool {
        get { self[CardsIncreasedContrastKey.self] }
        set { self[CardsIncreasedContrastKey.self] = newValue }
    }

    public var cardsTextScale: CardsTextScale {
        get { self[CardsTextScaleKey.self] }
        set { self[CardsTextScaleKey.self] = newValue }
    }
}

private struct CardsTypography: ViewModifier {
    let style: CardsTextStyle
    @Environment(\.cardsTextScale) private var textScale
    @ScaledMetric private var systemScale: CGFloat

    init(style: CardsTextStyle) {
        self.style = style
        _systemScale = ScaledMetric(wrappedValue: 1, relativeTo: style.relativeStyle)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: style.size * textScale.rawValue * systemScale, weight: style.weight))
    }
}

extension View {
    public func cardsText(_ style: CardsTextStyle = .body) -> some View {
        modifier(CardsTypography(style: style))
    }
}
