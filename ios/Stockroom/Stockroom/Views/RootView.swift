//
//  RootView.swift
//  Stockroom
//
//  The Duo layout lives here, and it is deliberately just a
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

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            BoxListView(selection: $selection, showingSettings: $showingSettings)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 460)
        } detail: {
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
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .task {
            if !store.isConfigured { showingSettings = true }
            await store.runAutoSync()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.requestSync() }
        }
        .onChange(of: store.boxes) {
            // A box deleted (here or on another device) shouldn't stay selected.
            if let id = selection, store.box(id: id) == nil { selection = nil }
        }
    }
}
