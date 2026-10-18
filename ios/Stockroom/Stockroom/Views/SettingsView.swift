//
//  SettingsView.swift
//  Stockroom
//
//  One-time connection setup. The address goes in UserDefaults (it isn't
//  secret); the token goes straight into the Keychain and is never shown
//  again — leave the field blank to keep the saved one.
//

import SwiftUI

struct SettingsView: View {
    @Environment(BoxStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var token = ""
    @State private var error: String?
    @State private var confirmingForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://your-mac.tailnet.ts.net:8788", text: $url)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(store.hasToken ? "Saved — leave blank to keep" : "Sync token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Mac Server")
                } footer: {
                    Text("Use the Tailscale HTTPS address (the same one your printed labels point to). The token is in stockroom_token.txt on the Mac — copy it there and paste here with Universal Clipboard. It's stored only in this iPhone's Keychain.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section("Status") {
                    LabeledContent("Sync", value: store.syncState.summary)
                    LabeledContent("Last synced") {
                        if let last = store.lastSynced {
                            Text(last, format: .relative(presentation: .named))
                        } else {
                            Text("Never")
                        }
                    }
                    LabeledContent("Boxes", value: "\(store.visibleBoxes.count)")
                    if store.hasUnsyncedChanges {
                        LabeledContent("Waiting to upload",
                                       value: "\(store.pendingIDs.count) boxes, \(store.pendingPhotos.count) photos")
                    }
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        store.requestSync()
                    }
                    .disabled(!store.isConfigured)
                }

                if store.hasToken {
                    Section {
                        Button("Forget Token", role: .destructive) { confirmingForget = true }
                    } footer: {
                        Text("Boxes already on this iPhone stay here; syncing stops until a token is entered again.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Forget the sync token?", isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("Forget Token", role: .destructive) { store.signOut() }
            }
            .onAppear { url = store.serverURLString }
        }
    }

    private func save() {
        do {
            try store.configure(serverURL: url, token: token.isEmpty ? nil : token)
            token = ""
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Toolbar sync indicator

struct SyncStatusButton: View {
    @Environment(BoxStore.self) private var store
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            switch store.syncState {
            case .syncing:
                ProgressView()
            case .notConfigured:
                Image(systemName: "icloud.slash")
            case .offline:
                Image(systemName: "wifi.slash").foregroundStyle(.orange)
            case .failed:
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.red)
            case .idle:
                Image(systemName: store.hasUnsyncedChanges ? "arrow.triangle.2.circlepath.icloud" : "checkmark.icloud")
                    .foregroundStyle(store.hasUnsyncedChanges ? Color.orange : Color.green)
            }
        }
        .accessibilityLabel("Sync status: \(store.syncState.summary)")
    }
}

extension BoxStore.SyncState {
    var summary: String {
        switch self {
        case .notConfigured: "Not set up"
        case .idle: "Up to date"
        case .syncing: "Syncing…"
        case .offline(let why): "Offline — \(why)"
        case .failed(let why): why
        }
    }
}
