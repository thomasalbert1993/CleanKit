import Testing
import Observation
import SwiftUI
@testable import CleanKit

// A concrete, protocol-conforming view model — the shape library consumers are expected to write.
private enum TestDestination: Equatable {
    case details(Int)
}

private struct TestError: Error {}

@Observable
@MainActor
private final class TestViewModel: NavigableViewModel {
    var isWaiting = false
    var navigation: NavigationIntent<TestDestination>?

    // Screen-specific state added directly on the leaf class (the case that failed under inheritance).
    var title = ""
    var feed: Loadable<[Int]> = .idle
}

@MainActor
private final class CountingInteractor: Interactor<TestViewModel> {
    private(set) var prepareCount = 0
    override func prepare() {
        super.prepare()
        prepareCount += 1
    }
}

private final class Flag: @unchecked Sendable {
    var value = false
}

private final class Counter: @unchecked Sendable {
    var value = 0
}

private final class ResultBox: @unchecked Sendable {
    var value: Interactor<TestViewModel>.CompletionResult?
}

@MainActor
@Test func customStateOnLeafClassIsObserved() {
    let vm = TestViewModel()
    let fired = Flag()
    withObservationTracking { _ = vm.title } onChange: { fired.value = true }
    vm.title = "Home"
    #expect(fired.value, "A stored property declared on the @Observable leaf class must be tracked")
}

@MainActor
@Test func navigationIsObservedAndConsumable() {
    let vm = TestViewModel()
    let interactor = Interactor(viewModel: vm)

    let fired = Flag()
    withObservationTracking { _ = vm.navigation } onChange: { fired.value = true }

    let token = interactor.navigate(to: .details(42))
    #expect(fired.value, "Emitting a navigation intent must invalidate observers of `navigation`")
    #expect(vm.navigation?.token == token)
    #expect(vm.navigation?.destination == .details(42))

    interactor.consumeNavigation(token: token)
    #expect(vm.navigation == nil)
}

@MainActor
@Test func prepareResetsTransientState() {
    let vm = TestViewModel()
    vm.isWaiting = true

    Interactor(viewModel: vm).prepareIfNeeded()

    #expect(vm.isWaiting == false, "The binding entry point must clear the ambient waiting flag before preparing")
}

@MainActor
@Test func prepareRunsOnlyOncePerInteractor() {
    let interactor = CountingInteractor(viewModel: TestViewModel())

    interactor.prepareIfNeeded()
    interactor.prepareIfNeeded()
    interactor.prepareIfNeeded()

    #expect(interactor.prepareCount == 1, "prepare() must run exactly once regardless of re-appearances")
}

@MainActor
@Test func didAppearAndDidDisappearObserversFire() {
    let interactor = Interactor(viewModel: TestViewModel())
    let token = interactor.navigate(to: .details(1))

    let presented = Flag()
    let dismissed = Flag()
    interactor.observeNavigation(token: token, .didAppear) { presented.value = true }
    interactor.observeNavigation(token: token, .didDisappear) { dismissed.value = true }

    interactor.handleNavigationEvent(.didAppear, for: token)
    #expect(presented.value)
    #expect(!dismissed.value, "didDisappear must not fire on appearance")

    interactor.handleNavigationEvent(.didDisappear, for: token)
    #expect(dismissed.value)
}

@MainActor
@Test func observersAreReleasedAfterDismiss() {
    let interactor = Interactor(viewModel: TestViewModel())
    let token = interactor.navigate(to: .details(1))

    let count = Counter()
    interactor.observeNavigation(token: token, .didAppear) { count.value += 1 }

    interactor.handleNavigationEvent(.didAppear, for: token) // fires (1)
    interactor.handleNavigationEvent(.didDisappear, for: token) // releases the one-shot rules
    interactor.handleNavigationEvent(.didAppear, for: token) // observers gone → no-op

    #expect(count.value == 1)
}

@MainActor
@Test func minimumExposureFiresAfterThreshold() async {
    let interactor = Interactor(viewModel: TestViewModel())
    let token = interactor.navigate(to: .details(1))

    let fired = Flag()
    interactor.observeNavigation(token: token, .minimumExposure(0.05)) { fired.value = true }
    interactor.handleNavigationEvent(.didAppear, for: token)

    try? await Task.sleep(for: .seconds(0.25))
    #expect(fired.value, "minimumExposure must fire once the destination stays long enough")
}

@MainActor
@Test func minimumExposureDoesNotFireIfDismissedEarly() async {
    let interactor = Interactor(viewModel: TestViewModel())
    let token = interactor.navigate(to: .details(1))

    let fired = Flag()
    interactor.observeNavigation(token: token, .minimumExposure(0.25)) { fired.value = true }
    interactor.handleNavigationEvent(.didAppear, for: token)
    interactor.handleNavigationEvent(.didDisappear, for: token) // leaves before the threshold

    try? await Task.sleep(for: .seconds(0.4))
    #expect(!fired.value, "minimumExposure must not fire when the destination leaves early")
}

@MainActor
@Test func asyncTaskIgnoresReentryWhileLocked() async {
    let vm = TestViewModel()
    let interactor = Interactor(viewModel: vm)
    vm.isWaiting = true // simulate an in-flight task

    var result: Interactor<TestViewModel>.CompletionResult?
    interactor.asyncTask({ /* never runs */ }, finally: { result = $0 })

    #expect(result == .ignored)
}

@MainActor
@Test func asyncTaskIgnoresReentryWhileGateClosed() {
    let interactor = Interactor(viewModel: TestViewModel())
    let gate = TaskGate()
    #expect(gate.tryClose()) // simulate a guarded task already in flight

    var result: Interactor<TestViewModel>.CompletionResult?
    interactor.asyncTask(gate: gate, task: { /* never runs */ }, finally: { result = $0 })

    #expect(result == .ignored)
    #expect(gate.isClosed)
}

@MainActor
@Test func loadDrivesLoadableThroughSuccess() async {
    let vm = TestViewModel()
    let interactor = Interactor(viewModel: vm)

    interactor.load(\.feed) { [1, 2, 3] }
    #expect(vm.feed.isLoading)

    while vm.feed.isLoading { await Task.yield() }
    #expect(vm.feed.value == [1, 2, 3])
}

@MainActor
@Test func loadCapturesErrorInLoadableNotAmbientChannel() async {
    let vm = TestViewModel()
    let interactor = Interactor(viewModel: vm)
    let ambientCalled = Flag()
    interactor.ambientErrorHandler = { _ in ambientCalled.value = true }

    interactor.load(\.feed) { throw TestError() }
    while vm.feed.isLoading { await Task.yield() }

    #expect(vm.feed.error is TestError)
    #expect(!ambientCalled.value, "A Loadable failure must not leak into the interactor's error-handling chain")
}

@MainActor
@Test func loadIgnoresReentryWhileLoading() async {
    let vm = TestViewModel()
    let interactor = Interactor(viewModel: vm)
    let secondRan = Flag()

    interactor.load(\.feed) {
        try await Task.sleep(for: .seconds(10)) // keeps the first load in flight
        return [1]
    }
    interactor.load(\.feed) {
        secondRan.value = true
        return [999]
    }

    await Task.yield()
    #expect(vm.feed.isLoading)
    #expect(!secondRan.value, "A reload must be ignored while a load for the same key path is in flight")

    interactor.cancelTasks()
}

@MainActor
@Test func cancelledLoadResetsToIdle() async {
    let vm = TestViewModel()
    let interactor = Interactor(viewModel: vm)
    let started = Flag()

    interactor.load(\.feed) {
        started.value = true
        try await Task.sleep(for: .seconds(10))
        return [1]
    }
    while !started.value { await Task.yield() }
    #expect(vm.feed.isLoading)

    interactor.cancelTasks()
    while vm.feed.isLoading { await Task.yield() }

    if case .idle = vm.feed {} else {
        Issue.record("A cancelled load must reset the Loadable to .idle")
    }
}

@MainActor
@Test func loadableViewResolvesForAllVariants() {
    // Collection, with the empty: override (only available where Value: Collection).
    let list: Loadable<[Int]> = .loaded([1, 2, 3])
    _ = LoadableView(list) { items in Text("\(items.count)") } empty: { Text("empty") }.body

    // Collection, relying on default loading/failed and no empty:.
    _ = LoadableView(list) { items in Text("\(items.count)") }.body

    // Single element (no empty: available), failed state.
    let single: Loadable<Int> = .failed(TestError())
    _ = LoadableView(single) { value in Text("\(value)") }.body

    // Idle with fully custom chrome.
    let idle: Loadable<Int> = .idle
    _ = LoadableView(idle) { Text("\($0)") } loading: { Text("…") } failed: { _ in Text("err") }.body
}

@MainActor
@Test func loadableAccessors() {
    let emptyList: Loadable<[Int]> = .loaded([])
    #expect(emptyList.isLoaded)
    #expect(emptyList.isEmpty)

    let fullList: Loadable<[Int]> = .loaded([1])
    #expect(!fullList.isEmpty)

    let single: Loadable<Int> = .loaded(7)
    #expect(single.value == 7)

    let failed: Loadable<Int> = .failed(TestError())
    #expect(failed.error is TestError)
    #expect(!failed.isLoaded)
}

@MainActor
@Test func cancelTasksCancelsInFlightWork() async {
    let interactor = Interactor(viewModel: TestViewModel())
    let outcome = ResultBox()

    await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
        let started = Flag()
        interactor.asyncTask(gate: TaskGate(), task: {
            started.value = true
            try await Task.sleep(for: .seconds(10)) // long-running; must be cancelled
        }, finally: { result in
            outcome.value = result
            finished.resume()
        })

        Task { @MainActor in
            while !started.value { await Task.yield() }
            interactor.cancelTasks()
        }
    }

    #expect(outcome.value == .cancelled)
}

@MainActor
@Test func releasingInteractorCancelsInFlightWork() async {
    let outcome = ResultBox()
    let started = Flag()

    do {
        let interactor = Interactor(viewModel: TestViewModel())
        interactor.asyncTask(gate: TaskGate(), task: {
            started.value = true
            try await Task.sleep(for: .seconds(10))
        }, finally: { outcome.value = $0 })

        while !started.value { await Task.yield() }
        // `interactor` leaves scope here → deinit must cancel the in-flight task.
    }

    try? await Task.sleep(for: .seconds(0.3))
    #expect(outcome.value == .cancelled)
}

//---------------------
// MARK: Error handling
//---------------------

// The resolution chain is exercised entirely on the interactor's own state (`onError` /
// `ambientErrorHandler`), so these tests carry no shared state and are safe to run in parallel.
@MainActor
private struct ErrorHandlingTests {

    @Test func handleErrorIsNoOpWhenNoHandlersInstalled() {
        let interactor = Interactor(viewModel: TestViewModel())

        // With neither a per-bind nor an ambient handler, the error is dropped — this must be a
        // safe no-op and never trap.
        interactor.handleError(TestError())
    }

    @Test func perBindHandlerTakesPriorityAndShortCircuits() {
        let interactor = Interactor(viewModel: TestViewModel())

        var caught: Error?
        interactor.onError = { caught = $0; return true }
        var ambientCalled = false
        interactor.ambientErrorHandler = { _ in ambientCalled = true }

        interactor.handleError(TestError())

        #expect(caught is TestError, "The per-bind handler must receive the error")
        #expect(!ambientCalled, "A handled per-bind error must not fall through to the ambient handler")
    }

    @Test func perBindHandlerCanDeclineAndFallThroughToAmbient() {
        let interactor = Interactor(viewModel: TestViewModel())

        interactor.onError = { _ in false } // declines: not handled
        var ambientCaught: Error?
        interactor.ambientErrorHandler = { ambientCaught = $0 }

        interactor.handleError(TestError())

        #expect(ambientCaught is TestError, "A declined per-bind error must fall through to the ambient handler")
    }

    @Test func ambientHandlerUsedWhenNoPerBindHandler() {
        let interactor = Interactor(viewModel: TestViewModel())

        var ambientCaught: Error?
        interactor.ambientErrorHandler = { ambientCaught = $0 }

        interactor.handleError(TestError())

        #expect(ambientCaught is TestError)
    }

    @Test func declinedErrorWithNoAmbientHandlerIsDropped() {
        let interactor = Interactor(viewModel: TestViewModel())

        var consulted = false
        interactor.onError = { _ in consulted = true; return false } // declines, and no ambient handler installed

        // The declined error has nowhere left to go; this must be a safe no-op.
        interactor.handleError(TestError())

        #expect(consulted, "The per-bind handler must still be consulted even when it declines")
    }

    @Test func asyncTaskFailureRoutesThroughErrorHierarchy() async {
        let vm = TestViewModel()
        let interactor = Interactor(viewModel: vm)

        let caught = Flag()
        interactor.onError = { _ in caught.value = true; return true }

        await withCheckedContinuation { continuation in
            interactor.asyncTask(gate: TaskGate(), task: { throw TestError() }, finally: { result in
                #expect(result == .failed)
                continuation.resume()
            })
        }

        #expect(caught.value, "An asyncTask failure with no explicit onFailure must route through handleError")
    }
}

@MainActor
@Test func asyncTaskRunsAndReopensGate() async {
    let interactor = Interactor(viewModel: TestViewModel())
    let gate = TaskGate()
    let didRun = Flag()

    await withCheckedContinuation { continuation in
        interactor.asyncTask(gate: gate, task: { didRun.value = true }, finally: { result in
            #expect(result == .succeed)
            continuation.resume()
        })
    }

    #expect(didRun.value)
    #expect(!gate.isClosed, "The gate must reopen once the task finishes")
}
