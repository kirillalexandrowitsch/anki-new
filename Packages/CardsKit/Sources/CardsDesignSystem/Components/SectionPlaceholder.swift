import SwiftUI

/// A neutral shell state; it does not imply that a collection has been opened.
public struct SectionPlaceholder: View {
    private let title: String
    private let symbol: String
    private let message: String

    public init(title: String, symbol: String, message: String) {
        self.title = title
        self.symbol = symbol
        self.message = message
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
                .frame(maxWidth: 440)
        }
    }
}
