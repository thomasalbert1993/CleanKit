import Foundation
import Observation

/// The base requirements for a view model.
///
/// Conforming types are the passive, observable state containers that views render and interactors
/// mutate. Declare them as `@Observable` classes so SwiftUI gets per-property invalidation:
///
/// ```swift
/// @Observable
/// @MainActor
/// final class HomeViewModel: ViewModel {
///     var isWaiting = false
///     // ... screen-specific state ...
/// }
/// ```
///
/// - Note: `@Observable` does not track stored properties added in a subclass, so view models
/// compose against these protocols rather than inheriting from a base class.
@MainActor
public protocol ViewModel: AnyObject, Observable {

    /// Whether a global asynchronous task is currently running.
    var isWaiting: Bool { get set }
}

/// A view model that can emit navigation intents to its view.
///
/// ```swift
/// @Observable
/// @MainActor
/// final class HomeViewModel: NavigableViewModel {
///     var isWaiting = false
///     var navigation: NavigationIntent<HomeDestination>?
///     // ... screen-specific state ...
/// }
/// ```
@MainActor
public protocol NavigableViewModel: ViewModel {
    associatedtype Destination

    /// The current navigation state.
    var navigation: NavigationIntent<Destination>? { get set }
}

/// A token for uniquely identifying a `NavigationIntent`.
public struct NavigationToken: Hashable, Identifiable, Sendable {
    public let id = UUID()
}

/// A navigation intent that a `NavigableViewModel` emits to the view.
/// It is uniquely identified with a `NavigationToken` and contains the expected `destination`.
public struct NavigationIntent<Destination> {
    /// The unique token for this navigation intent.
    public let token = NavigationToken()
    /// The navigation destination.
    public let destination: Destination
}

extension NavigationIntent: Equatable {
    /// Two intents are equal when they share the same token. Identity — not the destination — defines
    /// an intent, which lets `@Observable` skip redundant invalidations (e.g. clearing to `nil` twice)
    /// without requiring `Destination` to be `Equatable`.
    public static func == (lhs: NavigationIntent<Destination>, rhs: NavigationIntent<Destination>) -> Bool {
        lhs.token == rhs.token
    }
}

/// A lifecycle event observable for a presented navigation destination.
public enum NavigationEvent: Hashable, Sendable {
    /// The destination appeared on screen.
    case didAppear
    /// The destination left the screen.
    case didDisappear
    /// The destination remained continuously on screen for at least the given duration.
    /// Fires as soon as the threshold elapses; never fires if the destination leaves earlier.
    case minimumExposure(TimeInterval)
}
