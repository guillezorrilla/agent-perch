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
            // most recent session, so the panel is never just a bare list of rows. An Antigravity
            // IDE-workspace row is never eligible for that card — it is capped at `.idle` in the
            // source (never `isBusy`) precisely so it can't be mistaken for a real session, and
            // the exemption has to be repeated here too: it would otherwise still win the
            // fallback slot merely by being the single most recently touched folder (#29).
            guard let mostRecent = sessions.first(where: { !$0.isAntigravityWorkspace }) else {
                return Split(fullCards: [], compactRows: sessions)
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

/// What a session's status line should show — the pure decision behind
/// `FeaturedSessionCard.statusLine`, split out the same way `SessionLayout` was so it is testable
/// without SwiftUI (#21, #31).
///
/// A hookless session (Codex, the `agy` CLI — `AgentSession.supportsLiveStatus == false`) can
/// still be `.active`, and can still land on a full card via `SessionLayout`, but its `.active`
/// is only ever "recently touched and a live process," never a verified in-flight turn. Claiming
/// "Working…" for that is exactly the false claim issue #31 is about, so it always renders
/// `.neutral` instead — regardless of whether its status happens to be `.active` or `.idle`.
enum SessionStatusPresentation: Equatable {
    case needsAction
    case done
    /// A hook-verified tool call in progress, described in plain language.
    case activity(String)
    /// A hook-verified turn in progress with no activity description yet.
    case workingSpinner
    /// `.active`/`.idle` with nothing verified behind it — a status dot, no spinner, no text.
    case neutral

    static func of(_ session: AgentSession) -> SessionStatusPresentation {
        switch session.status {
        case .needsAction:
            return .needsAction
        case .done, .ended:
            return .done
        case .active, .idle, .working:
            guard session.supportsLiveStatus else { return .neutral }
            if session.status == .working, let activity = session.currentActivity {
                return .activity(activity)
            }
            return .workingSpinner
        }
    }
}
