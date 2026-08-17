import Foundation

/// The loading state of a single piece of content.
///
/// Orthogonal to the view model's ambient `errorMessage` / `isWaiting`: a `.failed` here is the
/// error of *this* content's load, and a screen may hold several independent `Loadable` values.
/// There is deliberately no `.empty` case — emptiness is a property of the loaded value, derived by
/// the consumer (see `isEmpty` for collections), so `Loadable` works equally for a single element
/// (`Loadable<Post>`) or a collection (`Loadable<[Post]>`).
public enum Loadable<Value> {
    /// No load has been requested yet.
    case idle
    /// A load is in progress.
    case loading
    /// The content loaded successfully.
    case loaded(Value)
    /// The load failed with an error.
    case failed(Error)
}

extension Loadable {

    /// The loaded value, if currently in the `.loaded` state.
    public var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    /// The failure, if currently in the `.failed` state.
    public var error: Error? {
        if case .failed(let error) = self { return error }
        return nil
    }

    /// Indicates whether a load is currently in progress (the `.loading` state).
    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// Indicates whether the content has loaded successfully (the `.loaded` state).
    public var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

extension Loadable where Value: Collection {

    /// Indicates whether the loaded collection is empty. `false` in any state other than `.loaded`.
    public var isEmpty: Bool {
        value?.isEmpty ?? false
    }
}
