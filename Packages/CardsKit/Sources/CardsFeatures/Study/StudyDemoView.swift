import CardsCore
import Foundation
import SwiftUI

/// Explicit opt-in, disposable UI demonstration until the persistent adapter in T020.
public struct StudyDemoView: View {
    @State private var model: StudySessionModel
    @Environment(\.dismiss) private var dismiss
    public init(clock: any CardsCore.Clock) {
        _model = State(initialValue: StudySessionModel(service: DemoStudySession(), clock: clock))
    }
    public var body: some View {
        StudyView(model: model, title: "Пробное занятие",
                  notice: "Синтетические карточки. Оценки действуют только в этом окне; коллекция и расписание не меняются.") {
            dismiss()
        }.interactiveDismissDisabled()
    }
}

private enum DemoStudyError: Error { case invalidCommand }

private actor DemoStudySession: StudySessionService {
    private let cards = [
        StudyPresentation(cardID: CardID(), question: "resilient", answer: "стойкий, быстро восстанавливающийся",
                          pronunciation: "/rɪˈzɪliənt/", example: "She remained resilient in difficult times."),
        StudyPresentation(cardID: CardID(), question: "opportunity", answer: "возможность"),
        StudyPresentation(cardID: CardID(), question: "improve", answer: "улучшать")
    ]
    private var rated: Set<CardID> = []
    private var commands: [CommandID: StudyRatingCommand] = [:]
    func next(skipping: Set<CardID>, preferred: CardID?) -> StudyNext {
        let available = cards.filter { !rated.contains($0.cardID) && !skipping.contains($0.cardID) }
        if let card = available.first(where: { $0.cardID == preferred }) ?? available.first { return .question(card) }
        return .completed(.availableViewed)
    }
    func rate(_ command: StudyRatingCommand) throws {
        if let existing = commands[command.id] {
            guard existing == command else { throw CollectionRepositoryError.commandIDReused }
            return
        }
        guard let card = cards.first(where: { $0.cardID == command.cardID }),
              card.revision == command.expectedRevision, !rated.contains(card.cardID) else {
            throw DemoStudyError.invalidCommand
        }
        commands[command.id] = command; rated.insert(command.cardID)
    }
}
