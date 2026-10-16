//
//  BoxListView.swift
//  Stockroom
//
//  The shelf: boxes grouped by location (case/spacing variants merged, as
//  in the web app), searchable across every field, and filterable by tags.
//  Tag filtering requires ALL selected tags — same rule as index.html.
//  Tags are picked from a toolbar menu; active ones show as chips.
//

import SwiftUI

struct BoxListView: View {
    @Environment(BoxStore.self) private var store
    @Binding var selection: String?
    @Binding var showingSettings: Bool

    @State private var query = ""
    @State private var selectedTags: Set<String> = []   // normalized keys
    @State private var pendingDelete: Box?
    @State private var newBox: Box?
    @State private var scanning = false
    /// Choosing boxes for a label sheet. Held as ids, not a filtered list,
    /// so picks survive searching (same design as the web Select mode).
    @State private var choosing = false
    @State private var picked: Set<String> = []
    /// Non-nil presents the print sheet. The boxes travel WITH the
    /// presentation (sheet(item:)) — a separate isPresented flag let the
    /// sheet render before the list was set, giving a blank page.
    @State private var printJob: PrintJob?

    var body: some View {
        List(selection: choosing ? .constant(nil) : $selection) {
            if !selectedTags.isEmpty {
                Section { activeFilterChips }
            }
            ForEach(sections, id: \.key) { section in
                Section {
                    ForEach(section.boxes) { box in
                        row(for: box)
                            .tag(box.id)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    pendingDelete = box
                                }
                            }
                    }
                } header: {
                    HStack {
                        Label(section.title, systemImage: "mappin.and.ellipse")
                        Spacer()
                        Text("\(section.boxes.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Stockroom")
        .searchable(text: $query, prompt: "Box, contents, location, tag")
        .overlay { emptyState }
        .refreshable { await store.sync() }
        .toolbar {
          if choosing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { choosing = false; picked.removeAll() }
            }
            ToolbarItem(placement: .principal) {
                Text(picked.isEmpty ? "Choose Boxes" : "\(picked.count) Selected").font(.headline)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("All Shown") { picked.formUnion(filtered.map(\.id)) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Print", systemImage: "printer") {
                    startPrinting(store.visibleBoxes.filter { picked.contains($0.id) })
                }
                .disabled(picked.isEmpty)
            }
          } else {
            ToolbarItem(placement: .topBarLeading) {
                SyncStatusButton { showingSettings = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !store.allTags.isEmpty { tagMenu }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if LabelScannerSheet.isAvailable {
                    Button("Scan Label", systemImage: "qrcode.viewfinder") { scanning = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Box", systemImage: "plus") {
                    newBox = Box.blank(boxNumber: store.suggestedNextBoxNumber)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !store.visibleBoxes.isEmpty { printMenu }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
            }
          }
        }
        .sheet(item: $printJob) { job in
            LabelPrintView(boxes: job.boxes)
        }
        .fullScreenCover(isPresented: $scanning) {
            LabelScannerSheet { id in
                query = ""
                selectedTags.removeAll()   // make sure the scanned box isn't filtered out
                selection = id
            }
        }
        .sheet(item: $newBox) { box in
            BoxEditorView(box: box, isNew: true) { saved in selection = saved.id }
                .presentationSizing(.page)
        }
        .confirmationDialog(
            pendingDelete.map { "Delete Box \($0.box)?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { box in
            Button("Delete Box \(box.box)", role: .destructive) {
                if selection == box.id { selection = nil }
                store.delete(id: box.id)
            }
        } message: { _ in
            Text("It will be removed from every device on the next sync.")
        }
    }

    // MARK: Label printing

    private var printMenu: some View {
        Menu {
            Button("All Shown (\(filtered.count))", systemImage: "square.stack") {
                startPrinting(filtered)
            }
            .disabled(filtered.isEmpty)
            Button("Choose Boxes…", systemImage: "checkmark.circle") {
                picked.removeAll()
                choosing = true
            }
        } label: {
            Label("Print Labels", systemImage: "printer")
        }
    }

    @ViewBuilder private func row(for box: Box) -> some View {
        if choosing {
            let on = picked.contains(box.id)
            Button {
                if on { picked.remove(box.id) } else { picked.insert(box.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    BoxRow(box: box)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
        } else {
            BoxRow(box: box)
        }
    }

    private func startPrinting(_ boxes: [Box]) {
        guard !boxes.isEmpty else { return }
        printJob = PrintJob(boxes: boxes)
        choosing = false
        picked.removeAll()
    }

    // MARK: Tag filter

    private var tagMenu: some View {
        Menu {
            ForEach(store.allTags, id: \.self) { tag in
                let key = BoxStore.normalizedKey(tag)
                Toggle(tag, isOn: Binding(
                    get: { selectedTags.contains(key) },
                    set: { on in if on { selectedTags.insert(key) } else { selectedTags.remove(key) } }
                ))
            }
            if !selectedTags.isEmpty {
                Divider()
                Button("Clear Filters", systemImage: "xmark.circle", role: .destructive) {
                    selectedTags.removeAll()
                }
            }
        } label: {
            Label("Filter by Tag",
                  systemImage: selectedTags.isEmpty
                    ? "line.3.horizontal.decrease"
                    : "line.3.horizontal.decrease.circle.fill")
        }
        .menuActionDismissBehavior(.disabled)   // pick several tags without reopening
    }

    /// Shows which filters are on; tap a chip to remove it.
    private var activeFilterChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(store.allTags.filter { selectedTags.contains(BoxStore.normalizedKey($0)) }, id: \.self) { tag in
                Button {
                    selectedTags.remove(BoxStore.normalizedKey(tag))
                } label: {
                    HStack(spacing: 4) {
                        Text(tag)
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor, in: .capsule)
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove filter \(tag)")
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
    }

    // MARK: Empty states

    @ViewBuilder private var emptyState: some View {
        if !store.isConfigured && store.visibleBoxes.isEmpty {
            ContentUnavailableView {
                Label("Connect to Your Mac", systemImage: "desktopcomputer")
            } description: {
                Text("Enter your Stockroom server's Tailscale address and sync token.")
            } actions: {
                Button("Open Settings") { showingSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if store.visibleBoxes.isEmpty {
            ContentUnavailableView("No Boxes Yet", systemImage: "shippingbox",
                                   description: Text("Boxes added on any device appear here."))
        } else if sections.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    // MARK: Filtering & grouping

    private struct LocationSection {
        let key: String
        let title: String
        let boxes: [Box]
    }

    private var filtered: [Box] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return store.visibleBoxes.filter { box in
            let boxTags = Set(box.tags.map(BoxStore.normalizedKey))
            guard selectedTags.isSubset(of: boxTags) else { return false }
            guard !terms.isEmpty else { return true }
            let haystack = ([box.box, box.contents, box.location] + box.tags)
                .joined(separator: " ").lowercased()
            return terms.allSatisfy { haystack.contains($0) }   // every word must match somewhere
        }
    }

    private var sections: [LocationSection] {
        let preferred = Dictionary(store.allLocations.map { (BoxStore.normalizedKey($0), $0) },
                                   uniquingKeysWith: { a, _ in a })
        let groups = Dictionary(grouping: filtered) { BoxStore.normalizedKey($0.location) }
        return groups.map { key, boxes in
            LocationSection(key: key,
                            title: key.isEmpty ? "No Location" : (preferred[key] ?? boxes[0].location),
                            boxes: boxes.sorted(by: Self.boxOrder))
        }
        .sorted { a, b in
            if a.key.isEmpty != b.key.isEmpty { return !a.key.isEmpty }   // "No Location" last
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// Numeric box numbers sort numerically (2 before 10); anything else naturally.
    nonisolated static func boxOrder(_ a: Box, _ b: Box) -> Bool {
        if let x = Int(a.box), let y = Int(b.box), x != y { return x < y }
        return a.box.localizedStandardCompare(b.box) == .orderedAscending
    }
}

/// One print request; identity per request so re-printing re-presents.
struct PrintJob: Identifiable {
    let id = UUID()
    let boxes: [Box]
}

// MARK: - Row

struct BoxRow: View {
    let box: Box

    var body: some View {
        HStack(spacing: 12) {
            BoxPhotoView(box: box, style: .thumbnail)
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(box.box.isEmpty ? "Unnumbered" : "Box \(box.box)")
                    .font(.headline)
                    .monospacedDigit()
                if !box.contents.isEmpty {
                    Text(box.contents.split(whereSeparator: \.isNewline).joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !box.tags.isEmpty {
                    Text(box.tags.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
