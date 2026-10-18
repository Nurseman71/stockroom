//
//  BoxEditorView.swift
//  Stockroom
//
//  Add or edit a box. Nothing touches the store until Save, so Cancel
//  really discards — including photos you just took.
//
//  Up to Box.maxPhotos photos per box: a large preview of the selected one,
//  a strip of all of them (the first is the cover), Make Cover and Remove.
//  When the sheet is wide (unfolded Duo) the photos sit in their own column
//  beside the form; folded, they're the first section of the form.
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
    /// The photos as they will be saved, cover first. Ones taken or picked
    /// in this edit carry their JPEG; the rest are already on the box.
    @State private var photos: [EditorPhoto]
    @State private var selectedPhoto: String?
    @State private var newTag = ""

    @State private var showingCamera = false
    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var identifying = false
    @State private var identifyError: String?
    @State private var errorTitle = "Couldn't Identify Items"
    @State private var identifiedCount: Int?
    @State private var confirmingDiscard = false

    @FocusState private var focus: Field?
    private enum Field { case number, location, contents, tag }

    init(box: Box, isNew: Bool, onSaved: @escaping (Box) -> Void = { _ in }) {
        _draft = State(initialValue: box)
        _photos = State(initialValue: box.photos.map { EditorPhoto(name: $0) })
        _selectedPhoto = State(initialValue: box.photos.first)
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
                CameraPicker { image in addPhoto(image) }
                    .ignoresSafeArea()
            }
            .onChange(of: libraryItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        guard remainingSlots > 0 else { break }
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            addPhoto(image)
                        }
                    }
                    libraryItems = []
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
                                : "Added \(n) item\(n == 1 ? "" : "s") from the photo\(photos.count == 1 ? "" : "s"). Review and edit before saving.")
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

    // MARK: Photos

    /// The stored box, whose photos BoxPhotoView can load or download.
    private var photoSource: Box { original ?? draft }

    private var remainingSlots: Int { Box.maxPhotos - photos.count }

    /// The selected photo's name, falling back to the cover.
    private var selectedName: String? {
        if let selectedPhoto, photos.contains(where: { $0.name == selectedPhoto }) { return selectedPhoto }
        return photos.first?.name
    }

    private var photoPanel: some View {
        VStack(spacing: 12) {
            ZStack {
                if let name = selectedName, let photo = photos.first(where: { $0.name == name }) {
                    if let preview = photo.preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                    } else {
                        BoxPhotoView(box: photoSource, style: .hero, name: name)
                    }
                } else {
                    Rectangle().fill(Color(.tertiarySystemFill))
                    VStack(spacing: 6) {
                        Image(systemName: "camera").font(.largeTitle)
                        Text("No photos").font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .clipShape(.rect(cornerRadius: 16))

            if !photos.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            Button { selectedPhoto = photo.name } label: {
                                thumbnail(photo)
                                    .frame(width: 64, height: 64)
                                    .clipShape(.rect(cornerRadius: 8))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(photo.name == selectedName ? Color.accentColor : .clear, lineWidth: 3)
                                    }
                                    .overlay(alignment: .bottomLeading) {
                                        if index == 0 && photos.count > 1 {
                                            Text("Cover")
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(.ultraThinMaterial, in: .rect(cornerRadius: 4))
                                                .padding(4)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Photo \(index + 1)\(index == 0 ? ", cover" : "")")
                            .accessibilityAddTraits(photo.name == selectedName ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }

            HStack {
                if CameraPicker.isAvailable {
                    Button("Camera", systemImage: "camera") { showingCamera = true }
                        .disabled(remainingSlots == 0)
                }
                PhotosPicker(selection: $libraryItems, maxSelectionCount: max(1, remainingSlots),
                             selectionBehavior: .ordered, matching: .images) {
                    Label("Library", systemImage: "photo.on.rectangle")
                }
                .disabled(remainingSlots == 0)
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)

            if let name = selectedName {
                HStack {
                    if photos.first?.name != name {
                        Button("Make Cover", systemImage: "star") { makeCover(name) }
                    }
                    Button("Remove", systemImage: "trash", role: .destructive) { removePhoto(name) }
                }
                .buttonStyle(.bordered)
                .labelStyle(.titleAndIcon)
                .controlSize(.small)

                Text(remainingSlots == 0 ? "\(Box.maxPhotos) of \(Box.maxPhotos) photos — the most a box can have"
                                         : "\(photos.count) of \(Box.maxPhotos) photos")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await identify() }
            } label: {
                if identifying {
                    HStack(spacing: 8) { ProgressView(); Text("Identifying…") }
                        .frame(maxWidth: .infinity)
                } else {
                    Label(photos.count > 1 ? "Identify Items in \(photos.count) Photos" : "Identify Items in Photo",
                          systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(photos.isEmpty || identifying || !store.isConfigured)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func thumbnail(_ photo: EditorPhoto) -> some View {
        if let preview = photo.preview {
            Image(uiImage: preview).resizable().scaledToFill()
        } else {
            BoxPhotoView(box: photoSource, style: .thumbnail, name: photo.name)
        }
    }

    private func addPhoto(_ image: UIImage) {
        guard remainingSlots > 0, let jpeg = PhotoPrep.jpeg(from: image) else { return }
        var name = Box.newPhotoName(for: draft.id)
        while photos.contains(where: { $0.name == name }) { name = Box.newPhotoName(for: draft.id) }
        photos.append(EditorPhoto(name: name, jpeg: jpeg, preview: EditorPhoto.preview(of: jpeg)))
        selectedPhoto = name
        identifiedCount = nil
    }

    private func makeCover(_ name: String) {
        guard let i = photos.firstIndex(where: { $0.name == name }) else { return }
        photos.insert(photos.remove(at: i), at: 0)
    }

    private func removePhoto(_ name: String) {
        guard let i = photos.firstIndex(where: { $0.name == name }) else { return }
        photos.remove(at: i)
        selectedPhoto = photos.isEmpty ? nil : photos[min(i, photos.count - 1)].name
        identifiedCount = nil
    }

    private func identify() async {
        var jpegs: [Data] = []
        for photo in photos {
            if let jpeg = photo.jpeg {
                jpegs.append(jpeg)
            } else if let url = store.localPhotoURL(for: photoSource, name: photo.name),
                      let data = try? Data(contentsOf: url) {
                jpegs.append(data)
            } else {
                errorTitle = "Couldn't Identify Items"
                identifyError = "A photo hasn't finished downloading yet. Try again in a moment."
                return
            }
        }
        guard !jpegs.isEmpty else { return }
        identifying = true
        defer { identifying = false }
        do {
            let text = try await store.identifyItems(in: jpegs)
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
        photos.map(\.name) != (original?.photos ?? []) || original.map { o in
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
            var newPhotos: [String: Data] = [:]
            for photo in photos { if let jpeg = photo.jpeg { newPhotos[photo.name] = jpeg } }
            box = try store.applyPhotos(photos.map(\.name), newPhotos: newPhotos, to: box)
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

/// One photo in the editor. `jpeg`/`preview` are set only for photos taken
/// or picked in this edit; saved ones are shown through BoxPhotoView.
private struct EditorPhoto: Identifiable {
    let name: String
    var jpeg: Data?
    var preview: UIImage?
    var id: String { name }

    /// Decoded once at a display size, not on every redraw.
    static func preview(of jpeg: Data) -> UIImage? {
        guard let image = UIImage(data: jpeg) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > 1200 else { return image }
        let f = 1200 / longest
        return image.preparingThumbnail(of: CGSize(width: (image.size.width * f).rounded(),
                                                   height: (image.size.height * f).rounded())) ?? image
    }
}
