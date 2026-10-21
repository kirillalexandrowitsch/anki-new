import CardsCore
import Foundation
import Observation
import SwiftUI

@MainActor @Observable public final class AppearanceModel {
    private let store: any AppPreferencesStore
    public private(set) var value: AppPreferences
    public private(set) var error: String?
    public init(store: any AppPreferencesStore) { self.store = store; value = store.load() }
    public var colorScheme: ColorScheme? {
        switch value.theme { case .system: nil; case .light: .light; case .dark: .dark }
    }
    public func set(theme: AppTheme) { var next = value; next.theme = theme; save(next) }
    public func set(language: AppLanguage) { var next = value; next.language = language; save(next) }
    private func save(_ next: AppPreferences) {
        do { try store.save(next); value = store.load(); error = nil }
        catch { value = store.load(); self.error = "Не удалось сохранить внешний вид. Показаны сохранённые значения. Повторите изменение." }
    }
}

@MainActor @Observable public final class StudyPreferencesModel {
    public enum Field: Hashable { case new, review }
    private let repository: any StudyPreferencesRepository
    public private(set) var saved: StudyPreferencesSnapshot?
    public private(set) var newText = ""
    public private(set) var reviewText = ""
    public private(set) var error: String?
    public private(set) var isSaving = false
    private var pending: Task<Void, Never>?
    private var active = true
    public init(repository: any StudyPreferencesRepository) { self.repository = repository }
    public var isValid: Bool { parsed != nil }
    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), (0...9999).contains(value) else { return nil }
        return value
    }
    private var parsed: StudyPreferences? {
        guard let new = Self.number(newText), let review = Self.number(reviewText) else { return nil }
        return try? StudyPreferences(newLimit: new, reviewLimit: review)
    }
    public func load() async {
        guard active, !isSaving else { return }
        do {
            let result = try await repository.load()
            guard active else { return }
            saved = result; restoreText(); error = nil
        } catch { self.error = "Не удалось прочитать учебные настройки. Повторите загрузку." }
    }
    public func edit(_ field: Field, text: String) {
        guard active, saved != nil, !isSaving else { return }
        pending?.cancel()
        switch field { case .new: newText = text; case .review: reviewText = text }
        error = nil
        guard isValid else { return }
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)); try Task.checkCancellation() }
            catch { return }
            await self?.persist()
        }
    }
    public func persist() async {
        guard active, !isSaving, let saved, let value = parsed, value != saved.value else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let result = try await repository.save(SaveStudyPreferences(expectedRevision: saved.revision, value: value))
            guard active else { return }
            self.saved = result; restoreText(); error = nil
        } catch {
            // A conflict may mean another window committed; never show our failed draft as saved.
            let current = try? await repository.load()
            guard active else { return }
            self.saved = current ?? saved; restoreText()
            self.error = "Не удалось сохранить учебные настройки. Показаны сохранённые значения. Повторите изменение."
        }
    }
    public func endEditing() {
        guard active, !isSaving else { return }
        pending?.cancel()
        guard isValid else { restoreText(); return }
        pending = Task { [weak self] in await self?.persist() }
    }
    public func cancelPending() { pending?.cancel(); pending = nil; restoreText() }
    public func stop() { active = false; cancelPending() }
    private func restoreText() {
        newText = saved.map { String($0.value.newLimit) } ?? ""
        reviewText = saved.map { String($0.value.reviewLimit) } ?? ""
    }
}
