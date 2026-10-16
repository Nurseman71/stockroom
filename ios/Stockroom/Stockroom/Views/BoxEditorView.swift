//
//  BoxEditorView.swift
//  Stockroom
//
//  Add or edit a box. Nothing touches the store until Save, so Cancel
//  really discards — including a photo you just took.
//
//  When the sheet is wide (unfolded Duo) the photo sits in its own column beside the
//  form; folded, it's the first section of the form.
//

import SwiftUI
import PhotosUI

struct BoxEditorView: View {
    @Environment(BoxStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Side-by-side photo + form once the editor itself is wide enough.
    /// Measured rather than read from the size class: on the unfolded Duo
    /// a sheet can be a compact-width card even on the big screen.
    @State private var width: CGFloat = 0
    private var isWide: Bool { width >= 640 }

    let isNew: Bool
    let onSaved: (Box) -> Void

    @State private var draft: Box
    /// A photo taken/picked in this session, not yet saved.
    @State private var newPhoto: Data?
    @State private var removePhoto = false
    @State private var newTag = ""

    @State private var showingCamera = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var identifying = false
    @State private var identifyError: String?
    @State private var errorTitle = "Couldn't Identify Items"
    @State private var identifiedCount: Int?
    @State private var confirmingDiscard = false

    @FocusState private var focus: Field?
    private enum Field { case number, location, contents, tag }

    init(box: Box, isNew: Bool, onSaved: @escaping (Box) -> Void = { _ in }) {
        _draft = State(initialValue: box)
        self.isNew = isNew
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Group {
                if isWide {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView { photoPanel.padding() }
                            .frame(width: 360)
                            .background(Color(.systemGroupedBackground))
                        Divider()
                        form(includePhoto: false)
                    }
                } else {
                    form(includePhoto: true)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .navigationTitle(isNew ? "New Box" : "Edit Box \(original?.box ?? draft.box)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmingDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
            }
            .interactiveDismissDisabled(hasChanges)
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker { image in setPhoto(image) }
                    .ignoresSafeArea()
            }
            .onChange(of: libraryItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        setPhoto(image)
                    }
                    libraryItem = nil
                }
            }
            .alert(errorTitle, isPresented: Binding(
                get: { identifyError != nil }, set: { if !$0 { identifyError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(identifyError ?? "")
            }
            .onAppear { if isNew { focus = .number } }
        }
    }

    // MARK: Form

    private func form(includePhoto: Bool) -> some View {
        Form {
            if includePhoto {
                Section { photoPanel }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Box") {
                    TextField("Number", text: $draft.box)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .focused($focus, equals: .number)
                        .submitLabel(.next)
                        .onSubmit { focus = .location }
                }
                TextField("Location (e.g. Basement)", text: $draft.location)
                    .focused($focus, equals: .location)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .onSubmit { focus = .contents }
                if !locationSuggestions.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(locationSuggestions, id: \.self) { loc in
                                Button(loc) { draft.location = loc; focus = .contents }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                    .controlSize(.small)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            } footer: {
                if let clash = numberClash {
                    Label("Box \(clash.box) already exists\(clash.location.isEmpty ? "" : " in \(clash.location)").",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                TextField("One item per line", text: $draft.contents, axis: .vertical)
                    .lineLimit(4...20)
                    .focused($focus, equals: .contents)
            } header: {
                Text("Contents")
            } footer: {
                if let n = identifiedCount {
                    Text(n == 0 ? "Nothing new found — everything identified was already listed."
                                : "Added \(n) item\(n == 1 ? "" : "s") from the photo. Review and edit before saving.")
                }
            }

            Section("Tags") {
                if !draft.tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(draft.tags, id: \.self) { tag in
                            Button {
                                draft.tags.removeAll { $0 == tag }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(tag)
                                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                                }
                                .font(.subheadline)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.15), in: .capsule)
                                .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove tag \(tag)")
                        }
                    }
                    .padding(.vertical, 4)
                }
                TextField("Add a tag", text: $newTag)
                    .focused($focus, equals: .tag)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { addTag(newTag) }
                if !tagSuggestions.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(tagSuggestions, id: \.self) { tag in
                                Button(tag) { addTag(tag) }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                    .controlSize(.small)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    // MARK: Photo

    private var photoPanel: some View {
        VStack(spacing: 12) {
            ZStack {
                if let image = currentPhotoImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if !removePhoto && draft.photoFilename != nil {
                    BoxPhotoView(box: draft, style: .hero)
                } else {
                    Rectangle().fill(Color(.tertiarySystemFill))
                    VStack(spacing: 6) {
                        Image(systemName: "camera").font(.largeTitle)
                        Text("No photo").font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .clipShape(.rect(cornerRadius: 16))

            HStack {
                if CameraPicker.isAvailable {
                    Button("Camera", systemImage: "camera") { showingCamera = true }
                }
                PhotosPicker(selection: $libraryItem, matching: .images) {
                    Label("Library", systemImage: "photo.on.rectangle")
                }
                if hasPhoto {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        newPhoto = nil
                        removePhoto = true
                        identifiedCount = nil
                    }
                }
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)

            Button {
                Task { await identify() }
            } label: {
                if identifying {
                    HStack(spacing: 8) { ProgressView(); Text("Identifying…") }
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Identify Items in Photo", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasPhoto || identifying || !store.isConfigured)
        }
        .padding(.vertical, 4)
    }

    private var hasPhoto: Bool { newPhoto != nil || (!removePhoto && draft.photoFilename != nil) }

    private var currentPhotoImage: UIImage? { newPhoto.flatMap(UIImage.init(data:)) }

    private func setPhoto(_ image: UIImage) {
        guard let jpeg = PhotoPrep.jpeg(from: image) else { return }
        newPhoto = jpeg
        removePhoto = false
        identifiedCount = nil
    }

    private func identify() async {
        let jpeg: Data? = newPhoto ?? store.localPhotoURL(for: draft).flatMap {
            try? Data(contentsOf: $0)
        }
        guard let jpeg else {
            errorTitle = "Couldn't Identify Items"
            identifyError = "The photo hasn't finished downloading yet. Try again in a moment."
            return
        }
        identifying = true
        defer { identifying = false }
        do {
            let text = try await store.identifyItems(in: jpeg)
            identifiedCount = mergeItems(text)
        } catch {
            errorTitle = "Couldn't Identify Items"
            identifyError = error.localizedDescription
        }
    }

    /// Appends identified items not already listed (case-insensitive).
    /// Returns how many were added.
    private func mergeItems(_ text: String) -> Int {
        var existing = Set(draft.contents.split(whereSeparator: \.isNewline)
            .map { BoxStore.normalizedKey(String($0)) })
        var additions: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            // The prompt asks for bare names, but strip list markers anyway.
            let item = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*•·").union(.whitespaces))
            guard !item.isEmpty, existing.insert(BoxStore.normalizedKey(item)).inserted else { continue }
            additions.append(item)
        }
        guard !additions.isEmpty else { return 0 }
        let base = draft.contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = additions.joined(separator: "\n")
        draft.contents = base.isEmpty ? added : base + "\n" + added
        return additions.count
    }

    // MARK: Suggestions & validation

    private var original: Box? { isNew ? nil : store.box(id: draft.id) }

    private var hasChanges: Bool {
        newPhoto != nil || removePhoto || original.map { o in
            o.box != draft.box || o.location != draft.location || o.contents != draft.contents || o.tags != draft.tags
        } ?? (!draft.box.isEmpty || !draft.location.isEmpty || !draft.contents.isEmpty || !draft.tags.isEmpty)
    }

    private var canSave: Bool {
        !draft.box.trimmingCharacters(in: .whitespaces).isEmpty || !draft.contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var numberClash: Box? {
        let number = draft.box.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty else { return nil }
        return store.visibleBoxes.first {
            $0.id != draft.id && $0.box.caseInsensitiveCompare(number) == .orderedSame
        }
    }

    private var locationSuggestions: [String] {
        let typed = BoxStore.normalizedKey(draft.location)
        return store.allLocations.filter { loc in
            let key = BoxStore.normalizedKey(loc)
            return key != typed && (typed.isEmpty || key.contains(typed))
        }
        .prefix(6).map { $0 }
    }

    private var tagSuggestions: [String] {
        let have = Set(draft.tags.map(BoxStore.normalizedKey))
        let typed = BoxStore.normalizedKey(newTag)
        return store.allTags.filter { tag in
            let key = BoxStore.normalizedKey(tag)
            return !have.contains(key) && (typed.isEmpty || key.contains(typed))
        }
        .prefix(8).map { $0 }
    }

    private func addTag(_ raw: String) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { newTag = "" }
        guard !tag.isEmpty,
              !draft.tags.contains(where: { BoxStore.normalizedKey($0) == BoxStore.normalizedKey(tag) }) else { return }
        // Reuse an existing tag's spelling so "yellow" joins "Yellow".
        let canonical = store.allTags.first { BoxStore.normalizedKey($0) == BoxStore.normalizedKey(tag) } ?? tag
        draft.tags.append(canonical)
    }

    // MARK: Save

    private func save() {
        if !newTag.trimmingCharacters(in: .whitespaces).isEmpty { addTag(newTag) }
        var box = draft
        do {
            if let newPhoto {
                box = try store.attachPhoto(newPhoto, to: box)
            } else if removePhoto {
                box = store.removePhoto(from: box)
            }
        } catch {
            errorTitle = "Couldn't Save"
            identifyError = "Couldn't save the photo: \(error.localizedDescription)"
            return
        }
        // Keep a location typed in a different case consistent with existing ones.
        if let match = store.allLocations.first(where: {
            BoxStore.normalizedKey($0) == BoxStore.normalizedKey(box.location)
        }) { box.location = match }
        store.save(box)
        onSaved(box)
        dismiss()
    }
}
