import SwiftUI
import UniformTypeIdentifiers
#if canImport(QuickLook)
import QuickLook
#endif

/// Describes how the destination of a navigation intent should be presented.
///
/// The presentation *style* is a View concern: the view model only emits an intent (a destination),
/// and the View decides — per destination — how to present it. Build one with the static helpers,
/// e.g. `.push { SomeView() }`, `.sheet { SomeView() }` or `.alert("Title") { Button(…) }`.
///
/// Some styles are platform-specific and are only available where the underlying SwiftUI API exists:
/// `.fullScreenCover` (not macOS), `.quickLook` (where QuickLook is available), `.fileImporter`
/// (iOS/macOS/visionOS).
public struct IntentPresentation {

    /// The kind of presentation to perform for a navigation intent.
    public enum Style {
        /// Pushes the destination onto the surrounding navigation stack (native SwiftUI `.navigationDestination`).
        case push
        /// Presents the destination in a sheet (native SwiftUI `.sheet`).
        case sheet
        #if !os(macOS)
        /// Presents the destination in a full-screen cover (native SwiftUI `.fullScreenCover`). Unavailable on macOS.
        case fullScreenCover
        #endif
        /// Presents an alert (native SwiftUI `.alert`).
        case alert
        /// Presents a confirmation dialog / action sheet (native SwiftUI `.confirmationDialog`).
        case confirmationDialog
        #if canImport(QuickLook)
        /// Presents a Quick Look preview of a file URL (native SwiftUI `.quickLookPreview`).
        case quickLook
        #endif
        #if os(iOS) || os(macOS) || os(visionOS)
        /// Presents a native file importer / document picker (native SwiftUI `.fileImporter`).
        case fileImporter
        #endif
        /// Runs a side effect without presenting anything (e.g. a destination that only updates local
        /// screen state).
        case perform
    }

    /// The presentation style this value describes.
    public let style: Style

    /// Pushes the given view onto the surrounding navigation stack.
    public static func push<Content: View>(@ViewBuilder _ content: () -> Content) -> IntentPresentation {
        .init(style: .push, content: AnyView(content()))
    }

    /// Presents the given view in a sheet.
    /// - Parameter onDismiss: A closure run once the sheet has been dismissed.
    public static func sheet<Content: View>(onDismiss: (() -> Void)? = nil, @ViewBuilder _ content: () -> Content) -> IntentPresentation {
        .init(style: .sheet, content: AnyView(content()), onDismiss: onDismiss)
    }

    /// Presents an already-built view in a sheet. Accepts an existential (e.g. `any EntryEditorView`),
    /// which Swift opens into the concrete `Content` — so the caller need not erase to `AnyView`.
    public static func sheet<Content: View>(onDismiss: (() -> Void)? = nil, view: Content) -> IntentPresentation {
        .init(style: .sheet, content: AnyView(view), onDismiss: onDismiss)
    }

    #if !os(macOS)
    /// Presents the given view in a full-screen cover. Unavailable on macOS.
    /// - Parameter onDismiss: A closure run once the cover has been dismissed.
    public static func fullScreenCover<Content: View>(onDismiss: (() -> Void)? = nil, @ViewBuilder _ content: () -> Content) -> IntentPresentation {
        .init(style: .fullScreenCover, content: AnyView(content()), onDismiss: onDismiss)
    }
    #endif

    /// Presents an alert with the given title and actions.
    /// - Parameters:
    ///   - title: The alert's title.
    ///   - actions: A view builder producing the alert's buttons.
    public static func alert<Actions: View>(
        _ title: String,
        @ViewBuilder actions: () -> Actions)
        -> IntentPresentation
    {
        .init(style: .alert, alertTitle: title, alertActions: AnyView(actions()))
    }

    /// Presents an alert with the given title, actions and message.
    ///
    /// - Parameter title: The alert's title.
    /// - Parameter actions: A view builder producing the alert's buttons.
    /// - Parameter message: A view builder producing the alert's message.
    public static func alert<Actions: View, Message: View>(
        _ title: String,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder message: () -> Message)
        -> IntentPresentation
    {
        .init(style: .alert, alertTitle: title, alertMessage: AnyView(message()), alertActions: AnyView(actions()))
    }

    /// Presents a confirmation dialog with the given title and actions.
    /// - Parameters:
    ///   - title: The dialog's title. When empty, the title is hidden.
    ///   - actions: A view builder producing the dialog's buttons.
    public static func confirmationDialog<Actions: View>(
        _ title: String = "",
        @ViewBuilder actions: () -> Actions)
        -> IntentPresentation
    {
        .init(style: .confirmationDialog, alertTitle: title, alertActions: AnyView(actions()))
    }

    /// Presents a confirmation dialog with the given title, actions and message.
    /// - Parameters:
    ///   - title: The dialog's title. When empty, the title is hidden.
    ///   - actions: A view builder producing the dialog's buttons.
    ///   - message: A view builder producing the dialog's message.
    public static func confirmationDialog<Actions: View, Message: View>(
        _ title: String = "",
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder message: () -> Message)
        -> IntentPresentation
    {
        .init(style: .confirmationDialog, alertTitle: title, alertMessage: AnyView(message()), alertActions: AnyView(actions()))
    }

    #if canImport(QuickLook)
    /// Presents a native Quick Look preview of a file URL.
    public static func quickLook(_ url: URL) -> IntentPresentation {
        .init(style: .quickLook, quickLookURL: url)
    }
    #endif

    #if os(iOS) || os(macOS) || os(visionOS)
    /// Presents a native file importer (document picker).
    /// - Parameters:
    ///   - contentTypes: The content types the user is allowed to select.
    ///   - allowsMultipleSelection: Whether more than one file may be selected.
    ///   - completion: A closure receiving the selected URLs, or an error.
    public static func fileImporter(
        contentTypes: [UTType],
        allowsMultipleSelection: Bool = false,
        completion: @escaping (Result<[URL], Error>) -> Void)
        -> IntentPresentation
    {
        .init(
            style: .fileImporter,
            fileImporterContentTypes: contentTypes,
            fileImporterAllowsMultiple: allowsMultipleSelection,
            fileImporterCompletion: completion)
    }
    #endif

    /// Runs a side effect without presenting anything — for destinations that only update local
    /// screen state.
    public static func perform(_ action: @escaping () -> Void) -> IntentPresentation {
        .init(style: .perform, action: action)
    }
    
    
    //---------------
    // MARK: Private
    //---------------
    
    fileprivate var content = AnyView(EmptyView())
    fileprivate var alertTitle = ""
    fileprivate var alertMessage = AnyView(EmptyView())
    fileprivate var alertActions = AnyView(EmptyView())
    fileprivate var action: (() -> Void)?
    fileprivate var onDismiss: (() -> Void)?
    fileprivate var quickLookURL: URL?
    fileprivate var fileImporterContentTypes: [UTType] = []
    fileprivate var fileImporterAllowsMultiple = false
    fileprivate var fileImporterCompletion: ((Result<[URL], Error>) -> Void)?
}

struct NavigationIntentModifier<V: NavigableViewModel>: ViewModifier {

    let interactor: Interactor<V>
    let presentation: (V.Destination) -> IntentPresentation

    @State private var pushedContent: AnyView?
    @State private var sheetContent: AnyView?
    @State private var coverContent: AnyView?

    @State private var sheetOnDismiss: (() -> Void)?
    @State private var coverOnDismiss: (() -> Void)?

    @State private var quickLookURL: URL?

    @State private var isPushing = false
    @State private var isPresentingSheet = false
    @State private var isPresentingCover = false

    @State private var isPresentingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = AnyView(EmptyView())
    @State private var alertActions = AnyView(EmptyView())

    @State private var isPresentingDialog = false
    @State private var dialogTitle = ""
    @State private var dialogMessage = AnyView(EmptyView())
    @State private var dialogActions = AnyView(EmptyView())

    @State private var isPresentingFileImporter = false
    @State private var fileImporterContentTypes: [UTType] = []
    @State private var fileImporterAllowsMultiple = false
    @State private var fileImporterCompletion: ((Result<[URL], Error>) -> Void)?

    @State private var alertToken: NavigationToken?
    @State private var dialogToken: NavigationToken?
    @State private var fileImporterToken: NavigationToken?
    @State private var quickLookToken: NavigationToken?

    private func tracked(_ view: AnyView, _ token: NavigationToken) -> AnyView {
        AnyView(
            view
                .onAppear { interactor.handleNavigationEvent(.didAppear, for: token) }
                .onDisappear { interactor.handleNavigationEvent(.didDisappear, for: token) }
        )
    }

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: $isPushing) {
                if let pushedContent { pushedContent }
            }
            .sheet(isPresented: $isPresentingSheet, onDismiss: { sheetOnDismiss?() }) {
                if let sheetContent { sheetContent }
            }
            .cleanKitFullScreenCover(isPresented: $isPresentingCover, onDismiss: { coverOnDismiss?() }) {
                if let coverContent { coverContent }
            }
            .alert(alertTitle, isPresented: $isPresentingAlert) {
                alertActions
            } message: {
                alertMessage
            }
            .confirmationDialog(dialogTitle, isPresented: $isPresentingDialog, titleVisibility: dialogTitle.isEmpty ? .hidden : .visible) {
                dialogActions
            } message: {
                dialogMessage
            }
            .cleanKitQuickLookPreview($quickLookURL)
            .cleanKitFileImporter(
                isPresented: $isPresentingFileImporter,
                // Fall back to a broad type when none is configured: an empty `allowedContentTypes`
                // makes SwiftUI log a fault on every render (and would let the user select nothing).
                // The real content types are always set before the importer is actually presented.
                allowedContentTypes: fileImporterContentTypes.isEmpty ? [.item] : fileImporterContentTypes,
                allowsMultipleSelection: fileImporterAllowsMultiple)
            { result in
                fileImporterCompletion?(result)
            }
            .onChange(of: interactor.viewModel.navigation) { _, newValue in
                guard let intent = newValue else { return }
                let route = presentation(intent.destination)
                let token = intent.token
                switch route.style {
                    case .push:
                        pushedContent = tracked(route.content, token)
                        isPushing = true
                    case .sheet:
                        sheetContent = tracked(route.content, token)
                        sheetOnDismiss = route.onDismiss
                        isPresentingSheet = true
                    #if !os(macOS)
                    case .fullScreenCover:
                        coverContent = tracked(route.content, token)
                        coverOnDismiss = route.onDismiss
                        isPresentingCover = true
                    #endif
                    case .alert:
                        alertTitle = route.alertTitle
                        alertMessage = route.alertMessage
                        alertActions = route.alertActions
                        alertToken = token
                        interactor.handleNavigationEvent(.didAppear, for: token)
                        isPresentingAlert = true
                    case .confirmationDialog:
                        dialogTitle = route.alertTitle
                        dialogMessage = route.alertMessage
                        dialogActions = route.alertActions
                        dialogToken = token
                        interactor.handleNavigationEvent(.didAppear, for: token)
                        isPresentingDialog = true
                    #if canImport(QuickLook)
                    case .quickLook:
                        quickLookURL = route.quickLookURL
                        quickLookToken = token
                        interactor.handleNavigationEvent(.didAppear, for: token)
                    #endif
                    #if os(iOS) || os(macOS) || os(visionOS)
                    case .fileImporter:
                        fileImporterContentTypes = route.fileImporterContentTypes
                        fileImporterAllowsMultiple = route.fileImporterAllowsMultiple
                        fileImporterCompletion = route.fileImporterCompletion
                        fileImporterToken = token
                        interactor.handleNavigationEvent(.didAppear, for: token)
                        isPresentingFileImporter = true
                    #endif
                    case .perform:
                        route.action?()
                }
                interactor.consumeNavigation(token: token)
            }
            .onChange(of: isPushing) { _, isPushing in if !isPushing { pushedContent = nil } }
            .onChange(of: isPresentingSheet) { _, isPresenting in if !isPresenting { sheetContent = nil } }
            .onChange(of: isPresentingCover) { _, isPresenting in if !isPresenting { coverContent = nil } }
            .onChange(of: isPresentingAlert) { _, isPresenting in
                if !isPresenting, let alertToken {
                    interactor.handleNavigationEvent(.didDisappear, for: alertToken)
                    self.alertToken = nil
                }
            }
            .onChange(of: isPresentingDialog) { _, isPresenting in
                if !isPresenting, let dialogToken {
                    interactor.handleNavigationEvent(.didDisappear, for: dialogToken)
                    self.dialogToken = nil
                }
            }
            .onChange(of: isPresentingFileImporter) { _, isPresenting in
                if !isPresenting, let fileImporterToken {
                    interactor.handleNavigationEvent(.didDisappear, for: fileImporterToken)
                    self.fileImporterToken = nil
                }
            }
            // Quick Look resets the binding to `nil` when the user dismisses the preview.
            .onChange(of: quickLookURL) { _, url in
                if url == nil, let quickLookToken {
                    interactor.handleNavigationEvent(.didDisappear, for: quickLookToken)
                    self.quickLookToken = nil
                }
            }
    }
}

/// These wrappers apply the platform-specific SwiftUI presentation modifiers where they exist, and
/// return the view unchanged elsewhere, so the shared `NavigationIntentModifier` body stays one clean
/// chain across all platforms.
private extension View {

    @ViewBuilder
    func cleanKitFullScreenCover<C: View>(
        isPresented: Binding<Bool>,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> C
    ) -> some View {
        #if os(macOS)
        self
        #else
        self.fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    @ViewBuilder
    func cleanKitQuickLookPreview(_ url: Binding<URL?>) -> some View {
        #if canImport(QuickLook)
        self.quickLookPreview(url)
        #else
        self
        #endif
    }

    @ViewBuilder
    func cleanKitFileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onCompletion: @escaping (Result<[URL], Error>) -> Void
    ) -> some View {
        #if os(iOS) || os(macOS) || os(visionOS)
        self.fileImporter(
            isPresented: isPresented,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: allowsMultipleSelection,
            onCompletion: onCompletion)
        #else
        self
        #endif
    }
}
