import Foundation
import SwiftUI
import Combine

@MainActor
open class Interactor<V: ViewModel> {
    
    /// The associated view model.
    public let viewModel: V
    
    public init(viewModel: V) {
        self.viewModel = viewModel
    }

    deinit {
        cancellationBag.cancelAll()
    }
    
    /// Prepares the interactor. Override this function to perform any
    /// additional setup, initialize content...
    open func prepare() {
    }

    /// Calls `prepare()` once per interactor lifetime, ignoring subsequent invocations.
    /// Invoked by the binding on the bound view's `onAppear`.
    func prepareIfNeeded() {
        guard !hasPrepared else { return }
        hasPrepared = true
        prepare()
    }
    
    
    //----------------------
    // MARK: Throwing tasks
    //----------------------
    
    /// Runs a synchronous throwing block, routing any thrown error through the interactor's
    /// error handling.
    ///
    /// If `block` throws, the error is forwarded to `handleError(_:)` (the interactor's error-handling
    /// chain) and then to `onFailure`, if provided. Use this to keep `do`/`catch` boilerplate out of
    /// views for synchronous work; for asynchronous work, use one of the `asyncTask(...)` functions
    /// instead.
    ///
    /// - Parameter block: The throwing work to perform.
    /// - Parameter onFailure: An optional closure called with the error after it has been handled.
    public func performThrowable(_ block: () throws -> Void, onFailure: ((Error) -> Void)? = nil) {
        do {
            try block()
        }
        catch {
            handleError(error)
            onFailure?(error)
        }
    }

    /// Handles an error by resolving it through the interactor's error-handling chain.
    ///
    /// This is the single funnel every error flows through when no explicit `onFailure` handler is
    /// provided (`performThrowable`, `asyncTask`, gated tasks…). Resolution happens in order:
    ///
    /// 1. The per-bind handler passed to `bind(_:onError:)`, if any. Returning `true` marks the error
    ///    as handled and stops here; returning `false` lets it fall through.
    /// 2. The ambient handler inherited from the environment, installed with `onInteractorError(_:)`
    ///    on an ancestor view, if any.
    ///
    /// If neither handles the error, it is dropped. Install at least one handler (or override this
    /// function) to surface errors.
    ///
    /// Override to customize how errors are handled — e.g. logging, mapping to domain-specific states,
    /// or routing to a different surface.
    ///
    /// - Parameter error: The error to handle.
    open func handleError(_ error: Error) {
        if let onError, onError(error) { return }
        ambientErrorHandler?(error)
    }

    /// The interactor's ambient busy state, driven by `asyncTask(_:onFailure:finally:)`.
    ///
    /// Doubles as the re-entrancy lock for that overload (a task is ignored while busy) and, on every
    /// change, notifies the busy handlers so a view can reflect it.
    public private(set) var isBusy = false

    /// Reports a busy transition through the interactor's busy-handling chain.
    ///
    /// Resolution mirrors `handleError(_:)`: the per-bind handler from `bind(_:onBusy:)` takes priority
    /// and, when absent, the ambient handler installed with `onInteractorBusy(_:)` on an ancestor view
    /// is used. If neither is set, the transition is simply not surfaced.
    ///
    /// - Parameter isBusy: Whether a task is now in flight.
    open func handleBusy(_ isBusy: Bool) {
        if let onBusy {
            onBusy(isBusy)
            return
        }
        ambientBusyHandler?(isBusy)
    }


    //-------------------
    // MARK: Async tasks
    //-------------------
    
    /// All asynchronous tasks (like API calls etc.) should always be implemented as synchronous
    /// functions in interactors, because we do not want to handle `async/await` or `Task` statements
    /// in views. You can implement them by calling one of the `asyncTask()` functions,
    /// that return immediately, in combination with a completion handler for legacy compatibility
    /// and testing purposes. These completion handlers should always be executed once (and only once),
    /// and contain a `CompletionResult` indicating the state of the task
    /// (`.succeed`, `.failed`, `.ignored` or `.cancelled`).
    ///
    /// Tasks are cancelled automatically when the interactor is torn down (or via `cancelTasks()`).
    /// Long-running work should check `Task.isCancelled` / use cancellation-aware APIs to stop early.
    public enum CompletionResult: Equatable, Sendable {
        /// The task has successfully completed.
        case succeed
        /// The task failed.
        case failed
        /// The task was ignored because another one was already running with the same gate.
        case ignored
        /// The task was cancelled before it could finish (e.g. the interactor was torn down).
        case cancelled
    }
    
    public typealias CompletionHandler = (CompletionResult) -> Void
    
    /// Performs an asynchronous task, locked by the interactor's ambient busy flag.
    ///
    /// While the task runs the interactor is marked busy; a second call is ignored until it finishes.
    /// Busy transitions are reported to the busy handlers (`bind(_:onBusy:)` and, failing that,
    /// `onInteractorBusy(_:)`) so a view can drive a spinner or overlay.
    ///
    /// - Parameter task: The task to perform.
    /// - Parameter onFailure: A closure performed when an error is encountered during
    /// the task execution. When this parameter is `nil` the error is forwarded to
    /// `handleError(_:)` (the interactor's error-handling chain).
    /// - Parameter finally: A closure performed when the task has completed or failed.
    ///
    /// - Note: The task won't be executed if the interactor is already busy.
    public func asyncTask(_ task: @escaping () async throws -> Void, onFailure: ((Error) -> Void)? = nil, finally: CompletionHandler? = nil) {
        asyncTask(
            lockGetter: { [weak self] in
                self?.isBusy ?? false
            },
            lockSetter: { [weak self] value in
                guard let self else { return }
                isBusy = value
                handleBusy(value)
            },
            task: task,
            onFailure: onFailure,
            finally: finally
        )
    }
    
    /// Performs an asynchronous task using a custom lock.
    ///
    /// - Parameter lockGetter: A closure returning the current lock value.
    /// - Parameter lockSetter: A closure for updating the lock value.
    /// - Parameter task: The task to perform.
    /// - Parameter onFailure: A closure performed when an error is encountered during
    /// the task execution. When this parameter is `nil` the error is forwarded to
    /// `handleError(_:)` (the interactor's error-handling chain).
    /// - Parameter finally: A closure performed when the task has completed or failed.
    ///
    /// - Note: The task won't be executed if the lock is already set.
    public func asyncTask(
        lockGetter: @escaping () -> Bool,
        lockSetter: @escaping (Bool) -> Void,
        task: @escaping () async throws -> Void,
        onFailure: ((Error) -> Void)? = nil,
        finally: CompletionHandler? = nil
    ) {
        guard !lockGetter() else {
            finally?(.ignored)
            return
        }
        lockSetter(true)

        let id = UUID()
        let handle = Task { @MainActor [weak self] in
            defer {
                lockSetter(false)
                self?.cancellationBag.remove(id)
            }

            do {
                try await task()
                finally?(.succeed)
            }
            catch {
                if Task.isCancelled {
                    finally?(.cancelled)
                } else if let onFailure {
                    onFailure(error)
                    finally?(.failed)
                } else {
                    self?.handleError(error)
                    finally?(.failed)
                }
            }
        }
        cancellationBag.insert(id, handle)
    }
    
    /// Performs an asynchronous task guarded by a custom gate.
    ///
    /// - Parameter gate: The `TaskGate` guarding the task.
    /// - Parameter task: The task to perform.
    /// - Parameter finally: A closure performed when the task has completed or failed.
    ///
    /// - Note: The task won't be executed if the gate is already closed.
    public func asyncTask(gate: TaskGate, task: @escaping () async throws -> Void, finally: CompletionHandler? = nil) {

        guard gate.tryClose() else {
            finally?(.ignored)
            return
        }

        let id = UUID()
        let handle = Task { @MainActor [weak self] in
            defer {
                gate.open()
                self?.cancellationBag.remove(id)
            }

            do {
                try await task()
                finally?(.succeed)
            }
            catch {
                if Task.isCancelled {
                    finally?(.cancelled)
                } else {
                    self?.handleError(error)
                    finally?(.failed)
                }
            }
        }
        cancellationBag.insert(id, handle)
    }

    /// Performs an asynchronous task guarded by a gate identified by a given key.
    ///
    /// - Parameter gateKey: The key identifying the gate to use.
    /// - Parameter task: The task to perform.
    /// - Parameter finally: A closure performed when the task has completed or failed.
    ///
    /// - Note: The task won't be executed if the gate is already closed.
    public func asyncTask(gateKey: String, task: @escaping () async throws -> Void, finally: CompletionHandler? = nil) {
        asyncTask(gate: keyedGates[gateKey], task: task, finally: finally)
    }
    
    /// Cancels every in-flight task started via `asyncTask`.
    public func cancelTasks() {
        cancellationBag.cancelAll()
    }


    //------------------------
    // MARK: Loadable content
    //------------------------

    /// Loads a single piece of content into a `Loadable` property of the view model.
    ///
    /// Drives the state machine automatically: `.loading` → `.loaded` on success, `.failed` on error.
    /// Unlike `asyncTask`, the error is captured in the `Loadable` itself and is **not** forwarded to
    /// the interactor's error-handling chain. Each `Loadable` property is gated independently, so a reload while a
    /// load for the same key path is already in flight is ignored; different properties load in parallel.
    /// If cancelled (e.g. the interactor is torn down), the property is reset to `.idle`.
    ///
    /// - Parameter keyPath: The view model's `Loadable` property to drive.
    /// - Parameter task: The asynchronous work producing the content.
    public func load<T>(_ keyPath: ReferenceWritableKeyPath<V, Loadable<T>>, task: @escaping () async throws -> T) {
        let gate = loadGates[keyPath]
        guard gate.tryClose() else { return }

        viewModel[keyPath: keyPath] = .loading

        let id = UUID()
        let handle = Task { @MainActor [weak self] in
            guard let self else { return }
            
            defer {
                gate.open()
                cancellationBag.remove(id)
            }

            do {
                let value = try await task()
                viewModel[keyPath: keyPath] = .loaded(value)
            }
            catch {
                viewModel[keyPath: keyPath] = Task.isCancelled ? .idle : .failed(error)
            }
        }
        cancellationBag.insert(id, handle)
    }
    
    
    //--------------------------------------------
    // MARK: Observing notifications & publishers
    //--------------------------------------------

    /// Observes a given notification.
    ///
    /// - Parameter name: The notification name to observe.
    /// - Parameter object: The filtering target object.
    /// - Parameter handler: The callback to perform.
    ///
    /// - Note: The `handler` is always performed on main thread.
    public func observe(_ name: Notification.Name, for object: AnyObject? = nil, handler: @escaping (Notification) -> Void) {
        observe(NotificationCenter.default.publisher(for: name, object: object), dropFirst: false, handler: handler)
    }

    /// Observes a set of notifications.
    ///
    /// - Parameter names: The notification names to observe.
    /// - Parameter object: The filtering target object.
    /// - Parameter handler: The callback to perform.
    ///
    /// - Note: The `handler` is always performed on main thread.
    public func observe(_ names: Notification.Name..., for object: AnyObject? = nil, handler: @escaping (Notification) -> Void) {
        for name in names {
            observe(name, for: object, handler: handler)
        }
    }

    /// Observes a given publisher.
    ///
    /// - Parameter publisher: The publisher to observe.
    /// - Parameter dropFirst: Indicates whether the initial value should be dropped.
    /// - Parameter handler: The callback to perform.
    ///
    /// - Note: The `handler` is always performed on main thread.
    public func observe<T>(_ publisher: T, dropFirst: Bool = true, handler: @escaping (T.Output) -> Void) where T: Publisher, T.Failure == Never {
        publisher
            .receive(on: RunLoop.main)
            .dropFirst(dropFirst ? 1 : 0)
            .sink { value in
                handler(value)
            }
            .store(in: &cancellables)
    }

    
    
    //---------------
    // MARK: Private
    //---------------
    
    private struct NavigationHandler {
        let id = UUID()
        let event: NavigationEvent
        let handler: () -> Void
        var hasFired = false
    }
    
    private let cancellationBag = CancellationBag()
    private var keyedGates = TaskGateMap<String>()
    private var loadGates = TaskGateMap<AnyKeyPath>()
    private var navigationObservers = [NavigationToken: [NavigationHandler]]()
    private var exposureTimers = [NavigationToken: [Task<Void, Never>]]()
    private var cancellables: Set<AnyCancellable> = []
    private var hasPrepared = false
    
    var onError: ((Error) -> Bool)?
    var ambientErrorHandler: ((Error) -> Void)?

    var onBusy: ((Bool) -> Void)?
    var ambientBusyHandler: ((Bool) -> Void)?

    internal func handleNavigationEvent(_ event: NavigationEvent, for token: NavigationToken) {
        switch event {

            case .didAppear:
                guard var rules = navigationObservers[token] else { return }
                for index in rules.indices where !rules[index].hasFired {
                    switch rules[index].event {

                        case .didAppear:
                            rules[index].hasFired = true
                            rules[index].handler()

                        case .minimumExposure(let duration):
                            // Fire once the destination has stayed on screen for `duration`.
                            // `.didDisappear` cancels this timer, so an early exit never fires.
                            let ruleID = rules[index].id
                            let timer = Task { @MainActor [weak self] in
                                try? await Task.sleep(for: .seconds(duration))
                                guard !Task.isCancelled else { return }
                                self?.fireExposure(ruleID, for: token)
                            }
                            exposureTimers[token, default: []].append(timer)

                        case .didDisappear:
                            break
                    }
                }
                navigationObservers[token] = rules

            case .didDisappear:
                // The destination is no longer exposed: cancel pending exposure timers...
                exposureTimers[token]?.forEach { $0.cancel() }
                exposureTimers[token] = nil
                // ...fire the dismissal observers...
                navigationObservers[token]?
                    .filter { !$0.hasFired }
                    .forEach { if case .didDisappear = $0.event { $0.handler() } }
                // ...and drop the one-shot rules now that this presentation is over.
                navigationObservers[token] = nil

            case .minimumExposure:
                break // Only meaningful as a rule descriptor, never delivered as a live event.
        }
    }

    private func fireExposure(_ ruleID: UUID, for token: NavigationToken) {
        guard var rules = navigationObservers[token],
              let index = rules.firstIndex(where: { $0.id == ruleID }),
              !rules[index].hasFired
        else { return }

        rules[index].hasFired = true
        let handler = rules[index].handler
        navigationObservers[token] = rules
        handler()
    }
}

extension Interactor {
    
    /// Updates the navigation state to a given destination.
    ///
    /// - Parameter destination: The target destination.
    ///
    /// - Returns: A `NavigationToken` identifying this intent, used to observe the destination's
    /// lifecycle via `observe(_:_:_:)`.
    ///
    /// - Note: The navigation binding clears the `navigation` state automatically. Register any
    /// lifecycle observers right after calling this, using the returned token.
    @discardableResult
    public func navigate(to destination: V.Destination) -> NavigationToken where V: NavigableViewModel {
        let intent = NavigationIntent(destination: destination)
        viewModel.navigation = intent
        return intent.token
    }

    /// Clears the navigation intent, assuming it's been handled.
    ///
    /// - Parameter token: The navigation intent's token.
    public func consumeNavigation(token: NavigationToken) where V: NavigableViewModel {
        guard let intent = viewModel.navigation, intent.token == token else { return }
        viewModel.navigation = nil
    }

    /// Observes a lifecycle event for a presented destination.
    ///
    /// Register observers right after `navigate(to:)`, using the token it returns. Each observer is
    /// one-shot and is released once the destination is dismissed.
    ///
    /// - Parameter token: The `NavigationToken` returned by `navigate(to:)`.
    /// - Parameter event: The `NavigationEvent` to observe.
    /// - Parameter handler: The closure to perform when the event is triggered.
    public func observeNavigation(token: NavigationToken, _ event: NavigationEvent, _ handler: @escaping () -> Void) where V: NavigableViewModel {
        let rule = NavigationHandler(event: event, handler: handler)
        navigationObservers[token, default: []].append(rule)
    }
}

extension View {

    /// Binds an interactor to the view, driving its lifecycle.
    ///
    /// Attach this to the root of a view to connect it to its interactor. When the view appears, the
    /// optional `setup` closure runs first, then `prepareIfNeeded()` is invoked so the interactor
    /// prepares exactly once per lifetime.
    ///
    /// - Parameter interactor: The interactor to bind to the view.
    /// - Parameter setup: An optional closure to configure the interactor before it prepares, called
    /// on the view's `onAppear`.
    /// - Parameter onError: An optional per-bind error handler, consulted by the interactor before the
    /// ambient `onInteractorError(_:)` handler. Return `true` if you handled the error, or `false` to
    /// let it propagate down the chain.
    /// - Parameter onBusy: An optional per-bind busy handler, called with the interactor's busy state
    /// as it changes. When provided it takes priority over the ambient `onInteractorBusy(_:)` handler.
    ///
    /// - Returns: A view bound to the given interactor.
    public func bind<V: ViewModel, I: Interactor<V>>(
        _ interactor: I,
        setup: ((I) -> Void)? = nil,
        onError: ((Error) -> Bool)? = nil,
        onBusy: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(InteractorModifier(interactor: interactor, setup: setup, onError: onError, onBusy: onBusy))
    }

    /// Binds a navigable interactor to the view, driving its lifecycle and navigation.
    ///
    /// Behaves like `bind(_:setup:)` but additionally observes the view model's `navigation` intents
    /// and presents them. Whenever the interactor navigates to a destination, `onNavigation` maps that
    /// destination to an `IntentPresentation` describing how it should be presented (e.g. push, sheet).
    ///
    /// - Parameter interactor: The interactor to bind to the view.
    /// - Parameter setup: An optional closure to configure the interactor before it prepares, called
    /// on the view's `onAppear`.
    /// - Parameter onError: An optional per-bind error handler, consulted by the interactor before the
    /// ambient `onInteractorError(_:)` handler. Return `true` if you handled the error, or `false` to
    /// let it propagate down the chain.
    /// - Parameter onBusy: An optional per-bind busy handler, called with the interactor's busy state
    /// as it changes. When provided it takes priority over the ambient `onInteractorBusy(_:)` handler.
    /// - Parameter onNavigation: A closure mapping a navigation destination to the presentation used
    /// to display it.
    ///
    /// - Returns: A view bound to the given interactor, presenting its navigation destinations.
    public func bind<V: NavigableViewModel, I: Interactor<V>>(
        _ interactor: I,
        setup: ((I) -> Void)? = nil,
        onError: ((Error) -> Bool)? = nil,
        onBusy: ((Bool) -> Void)? = nil,
        onNavigation: @escaping (V.Destination) -> IntentPresentation
    ) -> some View {
        bind(interactor, setup: setup, onError: onError, onBusy: onBusy).modifier(NavigationIntentModifier(interactor: interactor, presentation: onNavigation))
    }
    
    /// Installs a fallback error handler for every interactor bound within this view's subtree.
    ///
    /// The handler flows down through the environment, so it applies to this view and its descendants
    /// only — apply it on an ancestor of the `bind(_:)`-ed views (typically near the root of a feature
    /// or app). It is consulted by `handleError(_:)` after the per-bind `onError` handler (which takes
    /// priority); it is the last handler in the chain, so if it is absent the error is dropped.
    ///
    /// - Parameter callback: The closure invoked with any error not already handled by a per-bind
    /// `onError` handler.
    ///
    /// - Returns: A view that scopes the handler to its subtree.
    public func onInteractorError(_ callback: @escaping (Error) -> Void) -> some View {
        modifier(InteractorErrorHandlerModifier(callback: callback))
    }

    /// Installs a fallback busy handler for every interactor bound within this view's subtree.
    ///
    /// The handler flows down through the environment, so it applies to this view and its descendants
    /// only — apply it on an ancestor of the `bind(_:)`-ed views (typically near the root of a feature
    /// or app) to drive a shared loading overlay. It is called with the busy state whenever it changes,
    /// unless a per-bind `bind(_:onBusy:)` handler is provided, which takes priority.
    ///
    /// - Parameter callback: The closure invoked with the interactor's busy state as it changes.
    ///
    /// - Returns: A view that scopes the handler to its subtree.
    public func onInteractorBusy(_ callback: @escaping (Bool) -> Void) -> some View {
        modifier(InteractorBusyHandlerModifier(callback: callback))
    }
}

private struct InteractorModifier<V: ViewModel, I: Interactor<V>>: ViewModifier {

    /// The interactor to bind.
    var interactor: I
    /// Some setup to apply to the interactor before calling `prepareIfNeeded`.
    var setup: ((I) -> Void)?
    /// The per-bind error handler forwarded to the interactor. Return `true` to mark an error as
    /// handled, `false` to let it fall through to the ambient handler.
    var onError: ((Error) -> Bool)?
    /// The per-bind busy handler forwarded to the interactor. When set it takes priority over the
    /// ambient busy handler.
    var onBusy: ((Bool) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .onAppear {
                setup?(interactor)
                interactor.onError = onError
                interactor.ambientErrorHandler = ambientErrorHandler?.handle
                interactor.onBusy = onBusy
                interactor.ambientBusyHandler = ambientBusyHandler?.handle
                interactor.prepareIfNeeded()
            }
    }


    //---------------
    // MARK: Private
    //---------------

    @Environment(\.interactorErrorHandler) private var ambientErrorHandler
    @Environment(\.interactorBusyHandler) private var ambientBusyHandler
}

/// Scopes the ambient error handler to a view subtree via the environment.
///
/// The carrier is held in `@State` so its identity stays stable across body evaluations: the
/// environment compares it by reference, so a stable instance avoids invalidating readers on every
/// pass. (Storing the closure directly in the environment would defeat comparison — SwiftUI cannot
/// compare closures — so it is wrapped in a reference type instead.)
private struct InteractorErrorHandlerModifier: ViewModifier {
    @State private var handler: InteractorErrorHandler

    init(callback: @escaping (Error) -> Void) {
        _handler = State(initialValue: InteractorErrorHandler(callback))
    }

    func body(content: Content) -> some View {
        content.environment(\.interactorErrorHandler, handler)
    }
}

/// Carries the ambient error handler through the environment.
///
/// A reference type so the environment compares it by identity (keeping the value stable); the
/// closure it wraps is never compared by SwiftUI — it only ever lives inside this class and, once
/// injected, inside the interactor.
@MainActor
private final class InteractorErrorHandler {
    let handle: (Error) -> Void

    init(_ handle: @escaping (Error) -> Void) {
        self.handle = handle
    }
}

private struct InteractorErrorHandlerKey: EnvironmentKey {
    static let defaultValue: InteractorErrorHandler? = nil
}

extension EnvironmentValues {
    /// The ambient error handler installed by `onInteractorError(_:)`, scoped to a view subtree.
    fileprivate var interactorErrorHandler: InteractorErrorHandler? {
        get { self[InteractorErrorHandlerKey.self] }
        set { self[InteractorErrorHandlerKey.self] = newValue }
    }
}

/// Scopes the ambient busy handler to a view subtree via the environment.
///
/// Mirrors `InteractorErrorHandlerModifier`: the carrier is held in `@State` for a stable identity so
/// the environment (which compares by reference) doesn't invalidate readers on every pass, and the
/// closure is wrapped in a reference type rather than stored directly (SwiftUI cannot compare closures).
private struct InteractorBusyHandlerModifier: ViewModifier {
    @State private var handler: InteractorBusyHandler

    init(callback: @escaping (Bool) -> Void) {
        _handler = State(initialValue: InteractorBusyHandler(callback))
    }

    func body(content: Content) -> some View {
        content.environment(\.interactorBusyHandler, handler)
    }
}

/// Carries the ambient busy handler through the environment.
///
/// A reference type so the environment compares it by identity; the closure it wraps is never compared
/// by SwiftUI — it only ever lives inside this class and, once injected, inside the interactor.
@MainActor
private final class InteractorBusyHandler {
    let handle: (Bool) -> Void

    init(_ handle: @escaping (Bool) -> Void) {
        self.handle = handle
    }
}

private struct InteractorBusyHandlerKey: EnvironmentKey {
    static let defaultValue: InteractorBusyHandler? = nil
}

extension EnvironmentValues {
    /// The ambient busy handler installed by `onInteractorBusy(_:)`, scoped to a view subtree.
    fileprivate var interactorBusyHandler: InteractorBusyHandler? {
        get { self[InteractorBusyHandlerKey.self] }
        set { self[InteractorBusyHandlerKey.self] = newValue }
    }
}
