import Foundation

/// Decides which sessions render as full cards (glyph, subtitle, activity/status line, pills,
/// elapsed) versus one-line compact rows — the pure part of that decision, split out of
/// `NotchContentView` so it is testable without SwiftUI (#21).
enum SessionLayout {
    /// A busy panel that never stops growing is its own kind of unreadable — this bounds how
    /// many full cards can be on screen at once.
    static let maxFullCards = 3

    struct Split: Equatable {
        let fullCards: [AgentSession]
        let compactRows: [AgentSession]
    }

    /// `sessions` is expected in `SessionStore`'s existing order — needsAction sessions first
    /// (by recency), then everyone else by recency. This function only decides presentation; it
    /// never re-derives that ordering itself.
    static func split(sessions: [AgentSession], cap: Int = maxFullCards) -> Split {
        let busy = sessions.filter(isBusy)

        guard !busy.isEmpty else {
            // Nothing is working: keep the historical behavior of a single full card for the
            // most recent session, so the panel is never just a bare list of rows.
            guard let mostRecent = sessions.first else {
                return Split(fullCards: [], compactRows: [])
            }
            let rest = sessions.filter { $0.id != mostRecent.id }
            return Split(fullCards: [mostRecent], compactRows: rest)
        }

        // `busy` preserves the store's order, so this is already "needsAction first, then
        // working/active by most recent" — exactly the required full-card order.
        let fullCards = Array(busy.prefix(cap))
        let fullCardIDs = Set(fullCards.map(\.id))
        let compactRows = sessions
            .filter { !fullCardIDs.contains($0.id) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        return Split(fullCards: fullCards, compactRows: compactRows)
    }

    private static func isBusy(_ session: AgentSession) -> Bool {
        switch session.status {
        case .needsAction, .working, .active: true
        case .idle, .done, .ended: false
        }
    }
}
