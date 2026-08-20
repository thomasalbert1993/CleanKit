# CleanKit

A lightweight, opinionated micro-framework for building SwiftUI screens with a clean separation of
concerns: **declarative Views**, a passive **`@Observable` ViewModel**, and an **Interactor** that
holds all the imperative logic. Views stay free of `async`/`Task`; the Interactor owns side effects,
task gating, cancellation, and navigation intents.

- **Zero dependencies.** Pure Swift + SwiftUI.
- **`@Observable`-native.** Fine-grained invalidation, no Combine.
- **Concurrency-safe.** Everything is `@MainActor`; tasks are gated and cancelled on teardown.

## Requirements

| Platform | Minimum |
|---|---|
| iOS | 17 |
| macOS | 14 |
| tvOS | 17 |
| watchOS | 10 |
| visionOS | 1 |

Swift 6.3 / Xcode 26. Some presentation styles are platform-gated (see [Navigation](#navigation)).

## Installation

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/thomasalbert1993/CleanKit", from: "1.0.0")
]
```

Then add `"CleanKit"` to your target's dependencies.

## Core concepts

| Type | Role |
|---|---|
| `ViewModel` | Passive, observable state a View renders (protocol). |
| `NavigableViewModel` | A `ViewModel` that can emit navigation intents. |
| `Interactor<V>` | Owns the logic: async tasks, error handling, navigation, loading. |
| `IntentPresentation` | How the View presents a navigation destination. |
| `Loadable<T>` | The load state of one piece of content. |
| `LoadableView` | Renders a `Loadable` with sensible, overridable defaults. |

## A complete screen

### 1. The ViewModel — a passive `@Observable` state container

```swift
import CleanKit

enum HomeDestination {
    case detail(id: Int)
}

@Observable
@MainActor
final class HomeViewModel: NavigableViewModel {
    var navigation: NavigationIntent<HomeDestination>?

    var feed: Loadable<[Post]> = .idle              // per-content load state
}
```

> Declare view models as `@Observable` classes. CleanKit uses protocols (not a base class) because
> `@Observable` does not track stored properties added in a subclass.

### 2. The Interactor — all the logic

```swift
@MainActor
final class HomeInteractor: Interactor<HomeViewModel> {

    // Inject whatever you like via a custom init — CleanKit is DI-agnostic.
    private let repository: PostRepository

    init(viewModel: HomeViewModel, repository: PostRepository) {
        self.repository = repository
        super.init(viewModel: viewModel)
    }

    // Called once, on the bound view's first appearance.
    override func prepare() {
        super.prepare()
        loadFeed()
    }

    func loadFeed() {
        load(\.feed) { try await repository.fetchPosts() }
    }

    func openDetail(_ id: Int) {
        navigate(to: .detail(id: id))
    }
}
```

### 3. The View — declarative, no `async`

```swift
struct HomeView: View {
    @State private var interactor = HomeInteractor(
        viewModel: HomeViewModel(),
        repository: LivePostRepository()
    )

    var body: some View {
        NavigationStack {
            LoadableView(interactor.viewModel.feed) { posts in
                List(posts) { post in
                    Button(post.title) { interactor.openDetail(post.id) }
                }
            } empty: {
                ContentUnavailableView("No posts", systemImage: "tray")
            }
            .navigationTitle("Home")
        }
        .bind(interactor) { destination in
            switch destination {
                case .detail(let id):
                    .push { DetailView(id: id) }
            }
        }
    }
}
```

`.bind(interactor)` calls `prepare()` once and wires navigation. Use `.bind(interactor, onNavigation:)`
when the view model is a `NavigableViewModel`.

### Last-minute setup with `setup:`

Both `bind` overloads accept an optional `setup:` closure, run **after** the interactor is initialised
but **before** `prepare()` — on the bound view's first appearance. It receives the **concrete**
interactor type, so you can configure subclass-specific members that aren't available at `init` time.

The typical case is a View exposing a callback (e.g. `onSelect`) that only exists once the View is
composed by its parent — too late for the interactor's initializer, but exactly what `setup:` is for:

```swift
struct ItemListView: View {
    @State private var interactor = ItemListInteractor(viewModel: ItemListViewModel())

    // Provided by the parent view.
    let onSelect: (Item) -> Void

    var body: some View {
        List(interactor.viewModel.items) { item in
            Button(item.title) { interactor.select(item) }
        }
        .bind(interactor) { interactor in
            interactor.onSelect = onSelect        // wired before prepare()
        }
    }
}
```

`setup:` composes with navigation too: `.bind(interactor, setup: { … }, onNavigation: { … })`.

## Async work without `async` in the View

Interactors expose synchronous methods that kick off async work internally:

```swift
func submit() {
    asyncTask {
        try await api.submit(form)
    }
    // On failure the error is routed to the interactor's error handlers (see below).
    // Guarded by the interactor's busy flag: a second call while busy is ignored.
}
```

Variants:

- `asyncTask(_:onFailure:finally:)` — gated by the interactor's ambient busy flag.
- `asyncTask(gate:)` / `asyncTask(gateKey:)` — gated by a custom `TaskGate`.
- `performThrowable(_:onFailure:)` — synchronous throwing work.

Every task is **cancelled automatically** when the interactor is torn down (or via `cancelTasks()`).
Cancellation is cooperative — long work should honour `Task.isCancelled` / use cancellation-aware APIs.
A cancelled task reports `.cancelled` and does **not** surface an error.

## Error & busy handling

Errors and the busy state are surfaced through **closures**, not view model properties — the view model
is a plain marker (`AnyObject, Observable`). Each has a two-tier chain: a **per-bind** handler that
takes priority, and an **ambient** handler scoped to the view subtree.

```swift
// Per-bind: this screen handles its own error / spinner.
.bind(interactor,
      onError: { error in showToast(error); return true },   // return true = handled, stop
      onBusy: { isBusy = $0 })

// Ambient: a fallback for every interactor bound below, e.g. at the app root.
RootView()
    .onInteractorError { error in log(error) }
    .onInteractorBusy { showGlobalOverlay($0) }
```

- **Errors** — the per-bind `onError` returns `Bool`: `true` marks it handled and stops; `false` falls
  through to the ambient `onInteractorError`. If neither handles it, the error is dropped.
- **Busy** — driven by `asyncTask(_:onFailure:finally:)`. When present, per-bind `onBusy` takes over;
  otherwise the ambient `onInteractorBusy` fires. Bridge the `Bool` into your own `@State` for display.

## Loadable content

`Loadable<T>` models one piece of content, independently of the interactor's error and busy handlers:

```swift
var feed: Loadable<[Post]> = .idle
```

Drive it with `load(_:)`, which manages `.loading → .loaded / .failed`, captures the error **in the
`Loadable`** (not through the error handlers), gates per key path, and resets to `.idle` if cancelled:

```swift
func loadFeed() {
    load(\.feed) { try await repository.fetchPosts() }
}
```

Render it with `LoadableView` — you only provide the loaded content; `loading` and `failed` have
defaults, and `empty:` is available for collections:

```swift
LoadableView(vm.feed) { posts in
    List(posts) { PostRow(post: $0) }
} loading: {
    ProgressView()
} failed: { error in
    Text(error.localizedDescription)
} empty: {
    ContentUnavailableView("No posts", systemImage: "tray")
}
```

## Navigation

The view model emits an *intent* (a destination); the View decides *how* to present it via
`IntentPresentation`:

```swift
.bind(interactor) { destination in
    switch destination {
        case .detail(let id): .push { DetailView(id: id) }
        case .settings:       .sheet { SettingsView() }
        case .confirmDelete:  .alert("Delete?") { Button("Delete", role: .destructive) { … } }
    }
}
```

Available styles: `.push`, `.sheet`, `.alert`, `.confirmationDialog`, `.perform`, plus platform-gated
`.fullScreenCover` (not macOS), `.quickLook` (where QuickLook is available), and `.fileImporter`
(iOS/macOS/visionOS).

### Observing a destination's lifecycle

`navigate(to:)` returns a token you can observe — driven automatically by the destination's SwiftUI
lifecycle:

```swift
let token = navigate(to: .detail(id: id))
observe(token, .didAppear)          { analytics.log("detail_shown") }
observe(token, .minimumExposure(2)) { analytics.log("detail_impression") } // visible ≥ 2s
observe(token, .didDisappear)       { analytics.log("detail_closed") }
```

`.minimumExposure(x)` fires as soon as the destination has stayed on screen for `x` seconds, and
never fires if it leaves earlier.

## Dependency injection

CleanKit is **DI-agnostic** — nothing to configure. Interactors are plain classes, so use whatever
you already use:

- **Constructor injection** (as in the example above), or
- **[swift-dependencies](https://github.com/pointfreeco/swift-dependencies)**, **Factory**, etc. —
  e.g. `@Dependency(\.repository) var repository` works inside an interactor with no CleanKit support.

## License

MIT — see [LICENSE](LICENSE).
