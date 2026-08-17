import SwiftUI

/// A view that renders a `Loadable` value, switching over its state so the call site doesn't have to.
///
/// You only provide the loaded content; `loading` and `failed` have sensible defaults you can override.
/// For collection values, an `empty:` override is available and shown when the loaded collection is
/// empty. `.idle` renders like `.loading`.
///
/// ```swift
/// LoadableView(viewModel.feed) { posts in
///     List(posts) { PostRow(post: $0) }
/// } empty: {
///     ContentUnavailableView("No posts", systemImage: "tray")
/// }
/// ```
public struct LoadableView<Value, Content: View>: View {

    public var body: some View {
        switch state {
            case .idle, .loading:
                loading()
            case .failed(let error):
                failed(error)
            case .loaded(let value):
                if let isEmpty, isEmpty(value), let empty {
                    empty()
                } else {
                    content(value)
                }
        }
    }
    
    
    //---------------
    // MARK: Private
    //---------------
    
    private let state: Loadable<Value>
    private let content: (Value) -> Content
    private let loading: () -> AnyView
    private let failed: (Error) -> AnyView
    private let empty: (() -> AnyView)?     // nil for non-collection values
    private let isEmpty: ((Value) -> Bool)? // nil for non-collection values
}

extension LoadableView {

    /// Creates a view for any `Loadable` value.
    ///
    /// - Parameter state: The `Loadable` to render.
    /// - Parameter content: The view for the loaded value.
    /// - Parameter loading: The view shown while loading (and when idle). Defaults to a `ProgressView`.
    /// - Parameter failed: The view shown on failure. Defaults to the error's `localizedDescription`.
    public init<Loading: View, Failed: View>(
        _ state: Loadable<Value>,
        @ViewBuilder content: @escaping (Value) -> Content,
        @ViewBuilder loading: @escaping () -> Loading = { ProgressView() },
        @ViewBuilder failed: @escaping (Error) -> Failed = { Text($0.localizedDescription) }
    ) {
        self.state = state
        self.content = content
        self.loading = { AnyView(loading()) }
        self.failed = { AnyView(failed($0)) }
        self.empty = nil
        self.isEmpty = nil
    }
}

extension LoadableView where Value: Collection {

    /// Creates a view for a `Loadable` collection, with a dedicated view for the empty case.
    ///
    /// - Parameters state: The `Loadable` collection to render.
    /// - Parameter content: The view for the loaded, non-empty collection.
    /// - Parameter loading: The view shown while loading (and when idle). Defaults to a `ProgressView`.
    /// - Parameter failed: The view shown on failure. Defaults to the error's `localizedDescription`.
    /// - Parameter empty: The view shown when the loaded collection is empty.
    public init<Loading: View, Failed: View, Empty: View>(
        _ state: Loadable<Value>,
        @ViewBuilder content: @escaping (Value) -> Content,
        @ViewBuilder loading: @escaping () -> Loading = { ProgressView() },
        @ViewBuilder failed: @escaping (Error) -> Failed = { Text($0.localizedDescription) },
        @ViewBuilder empty: @escaping () -> Empty
    ) {
        self.state = state
        self.content = content
        self.loading = { AnyView(loading()) }
        self.failed = { AnyView(failed($0)) }
        self.empty = { AnyView(empty()) }
        self.isEmpty = { $0.isEmpty }
    }
}
