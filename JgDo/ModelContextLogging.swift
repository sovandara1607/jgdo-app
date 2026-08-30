import Foundation
import SwiftData
import os

extension ModelContext {
    /// `fetch(_:)`, but logs (instead of silently swallowing) any failure
    /// and returns an empty array — the shape every "load a list" call
    /// site in the app already wants on failure, without each one
    /// repeating its own do/catch just to avoid a bare `try?`.
    func fetchLogged<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, using logger: Logger) -> [T] {
        do {
            return try fetch(descriptor)
        } catch {
            logger.error("Fetch of \(String(describing: T.self), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
