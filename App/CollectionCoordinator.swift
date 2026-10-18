import CardsCore
import Foundation
import Observation

/// One per App, shared by every window. UI callbacks must pass their captured context.
@MainActor @Observable
final class CollectionCoordinator {
    private let access: any CollectionAccess
    private var request = UUID()
    private var stopping: [UUID: @MainActor () -> Void] = [:]
    private var pendingClose: CollectionContext?
    private(set) var context: CollectionContext?
    private(set) var isOpening = false
    private(set) var error: (any Error)?

    init(access: any CollectionAccess) { self.access = access }

    func open() async {
        guard context == nil, !isOpening else { return }
        let attempt = UUID()
        request = attempt
        isOpening = true
        error = nil
        do {
            if let retired = pendingClose {
                try await access.close(generation: retired.generation)
                if pendingClose == retired { pendingClose = nil }
                guard request == attempt else { return }
            }
            let opened = try await access.open()
            guard request == attempt, !Task.isCancelled else {
                do { try await access.close(generation: opened.generation) }
                catch { pendingClose = opened; throw error }
                if request == attempt { isOpening = false }
                return
            }
            context = opened
            isOpening = false
        } catch {
            guard request == attempt else { return }
            self.error = error
            isOpening = false
        }
    }

    func close() async {
        request = UUID() // invalidate results before suspending or cancelling observations
        let attempt = request
        isOpening = false
        error = nil
        let previous = context ?? pendingClose
        context = nil
        pendingClose = previous
        let callbacks = Array(stopping.values)
        stopping.removeAll()
        callbacks.forEach { $0() }
        guard let previous else { return } // pending open cleans up its own result
        do {
            try await access.close(generation: previous.generation)
            if pendingClose == previous { pendingClose = nil }
        }
        catch { if request == attempt { self.error = error } }
    }

    @discardableResult
    func accept(_ captured: CollectionContext, update: () -> Void) -> Bool {
        guard context == captured else { return false }
        update()
        return true
    }

    /// Register Task.cancel, GRDB observation cancellation, audio stop, etc.
    @discardableResult
    func onClose(_ captured: CollectionContext, stop: @escaping @MainActor () -> Void) -> UUID? {
        guard context == captured else { stop(); return nil }
        let id = UUID()
        stopping[id] = stop
        return id
    }

    func removeObservation(_ id: UUID) { stopping.removeValue(forKey: id) }
}
