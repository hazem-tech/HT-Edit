//
//  RemovalHover.swift
//  HT Edit
//

import Foundation

/// When the timeline's hover card for a removed part shows and hides.
///
/// - It shows only after the pointer rests on a part's top bar for `dwell`,
///   like a tooltip, so sweeping across the timeline never pops cards.
/// - Once a card shows, moving onto another part's bar switches to it at once.
/// - Leaving the bar (or the card) starts one `grace` period, long enough to
///   move from the bar down onto the card. Further pointer movement never
///   restarts it, so the card always goes away once the pointer has left.
///
/// Pure state: the view runs the timers this asks for and reports back.
nonisolated struct RemovalHover: Equatable, Sendable {
    static let dwell: Duration = .milliseconds(350)
    static let grace: Duration = .milliseconds(200)

    enum Timer: Equatable, Sendable {
        /// Call `dwellElapsed(for:)` with this part after `dwell`.
        case dwell(part: Int)
        /// Call `graceElapsed()` after `grace`.
        case grace
    }

    /// The part whose card is showing.
    private(set) var shown: Int?
    /// The part the pointer rests on, waiting for the dwell to show it.
    private(set) var pending: Int?
    private(set) var isOnBar = false
    private(set) var isOnCard = false
    /// The grace period is running.
    private(set) var isHiding = false

    /// The pointer moved over part `part`'s top bar, or off every bar (`nil`).
    mutating func pointer(over part: Int?) -> Timer? {
        guard let part else {
            pending = nil
            isOnBar = false
            return beginHiding()
        }
        if shown != nil {
            shown = part
            pending = nil
            isOnBar = true
            isHiding = false
            return nil
        }
        guard pending != part else { return nil }
        pending = part
        return .dwell(part: part)
    }

    /// The pointer rested on `part` long enough.
    mutating func dwellElapsed(for part: Int) {
        guard shown == nil, pending == part else { return }
        shown = part
        pending = nil
        isOnBar = true
    }

    /// The pointer entered or left the card.
    mutating func card(isInside: Bool) -> Timer? {
        isOnCard = isInside
        if isInside {
            isHiding = false
            return nil
        }
        return beginHiding()
    }

    mutating func graceElapsed() {
        guard isHiding else { return }
        isHiding = false
        if !isOnBar, !isOnCard { shown = nil }
    }

    /// Hides everything at once (scrolling, zooming, the parts changed).
    mutating func dismiss() {
        self = RemovalHover()
    }

    /// Starts the grace period, unless it's running already or nothing shows.
    private mutating func beginHiding() -> Timer? {
        guard shown != nil, !isOnCard, !isOnBar, !isHiding else { return nil }
        isHiding = true
        return .grace
    }
}
