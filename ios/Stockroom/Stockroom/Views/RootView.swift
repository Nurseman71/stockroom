//
//  RootView.swift
//  Stockroom
//
//  The Duo layout lives here. Mostly it is just a
//  NavigationSplitView: unfolded (regular width) it shows the box list and
//  the selected box side by side; folded onto the 5.4" outer display, or
//  squeezed into half of Split View (compact width), SwiftUI collapses the
//  same view into a push-navigation stack. Folding mid-task keeps the
//  selection, because the selection is state here, not a pushed screen.
//

import SwiftUI

struct RootView: View {
    @Environment(BoxStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var selection: String?
    @State private var showingSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var labelNotFound = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var window = WindowGeometry()

    /// Unfolded flat in landscape, the crease runs down the middle of the
    /// SCREEN. Returns the list width that puts the pane divider exactly on
    /// it, or nil in every other posture (folded, portrait, Split View).
    ///
    /// NavigationSplitView can't do this: iOS caps the sidebar width (it
    /// stopped at ~44% on the simulated Duo), so this posture gets a plain
    /// two-pane HStack instead. The Duo's vertical status bar insets the
    /// window on one side, hence measuring the full screen width from the
    /// safe-area insets rather than using the view's own width.
    /// (A geometric stand-in until Apple documents its fold APIs.)
    private var hingeListWidth: CGFloat? {
        guard sizeClass == .regular,
              window.fullWidth > window.size.height,
              window.fullWidth >= 700 else { return nil }
        return (window.fullWidth / 2 - window.leadingInset).rounded()
    }

    var body: some View {
        Group {
            if let listWidth = hingeListWidth {
                HStack(spacing: 0) {
                    NavigationStack { list }
                        .frame(width: listWidth)
                    Divider()
                    detail
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    list.navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 460)
                } detail: {
                    detail
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .onGeometryChange(for: WindowGeometry.self) { proxy in
            WindowGeometry(size: proxy.size,
                           leadingInset: proxy.safeAreaInsets.leading,
                           trailingInset: proxy.safeAreaInsets.trailing)
        } action: { window = $0 }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .task {
            if !store.isConfigured { showingSettings = true }
            await store.runAutoSync()
        }
        // A printed label scanned with the stock Camera app arrives here as a
        // Universal Link (https://<host>/?boxid=...). Only the id is used.
        .onOpenURL { url in openLabel(url) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { openLabel(url) }
        }
        .alert("Box Not Found", isPresented: $labelNotFound) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That label's box isn't on this iPhone — it may have been deleted.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.requestSync() }
        }
        .onChange(of: store.boxes) {
            // A box deleted (here or on another device) shouldn't stay selected.
            if let id = selection, store.box(id: id) == nil { selection = nil }
        }
    }

    private func openLabel(_ url: URL) {
        guard let id = LabelCode.boxID(from: url.absoluteString) else { return }
        if store.box(id: id) != nil { selection = id; return }
        Task {   // maybe created on another device since the last sync
            await store.sync()
            if store.box(id: id) != nil { selection = id } else { labelNotFound = true }
        }
    }

    /// The box list. Folded / Split View get the big "at the shelf" buttons;
    /// decided here from the WINDOW's size class, because inside a split
    /// view the sidebar column always reports itself as compact.
    private var list: some View {
        BoxListView(selection: $selection, showingSettings: $showingSettings,
                    atShelfLayout: sizeClass == .compact)
    }

    private var detail: some View {
        NavigationStack {
            if let id = selection, let box = store.box(id: id) {
                BoxDetailView(box: box)
            } else {
                ContentUnavailableView(
                    "No Box Selected",
                    systemImage: "shippingbox",
                    description: Text("Pick a box from the list.")
                )
            }
        }
    }
}

nonisolated struct WindowGeometry: Equatable {
    var size: CGSize = .zero
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    var fullWidth: CGFloat { size.width + leadingInset + trailingInset }
}
