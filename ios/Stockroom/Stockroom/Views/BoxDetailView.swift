//
//  BoxDetailView.swift
//  Stockroom
//
//  One box: photo, number, location, tags, and its contents as a
//  checklist-style list (one item per line, as entered).
//

import SwiftUI

struct BoxDetailView: View {
    let box: Box
    @State private var showingPhoto = false
    @State private var editing = false
    @State private var printing = false

    private var items: [String] {
        box.contents.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Width of this pane. Both Duo screens are nearly square (the box pane
    /// unfolded, the whole outer screen folded), so the photo goes BESIDE
    /// the heading and the contents list starts on the first screen instead
    /// of below the bottom edge. Only narrow panes (e.g. a Split View third)
    /// fall back to the photo-on-top layout.
    @State private var paneWidth: CGFloat = 0
    private var isWide: Bool { paneWidth >= 340 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isWide {
                    HStack(alignment: .top, spacing: 18) {
                        if box.photoFilename != nil {
                            let side = min(paneWidth * 0.4, 300)
                            photoButton(height: side)
                                .frame(width: side)
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            heading
                            tagChips
                            updatedLine
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    contentsCard
                } else {
                    if box.photoFilename != nil { photoButton(height: 280) }
                    heading
                    tagChips
                    contentsCard
                    updatedLine
                }
            }
            .padding()
            .frame(maxWidth: 720, alignment: .leading)   // readable line length when unfolded
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(box.box.isEmpty ? "Box" : "Box \(box.box)")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingPhoto) {
            PhotoViewer(box: box)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Print Label", systemImage: "printer") { printing = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = true }
            }
        }
        .sheet(isPresented: $printing) {
            LabelPrintView(boxes: [box])
        }
        .sheet(isPresented: $editing) {
            BoxEditorView(box: box, isNew: false)
                .presentationSizing(.page)
        }
    }

    // MARK: Pieces

    private func photoButton(height: CGFloat) -> some View {
        Button { showingPhoto = true } label: {
            BoxPhotoView(box: box, style: .hero)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Box photo, tap to enlarge")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(box.box.isEmpty ? "Unnumbered Box" : "Box \(box.box)")
                .font(.largeTitle.bold())
                .monospacedDigit()
            if !box.location.isEmpty {
                Label(box.location, systemImage: "mappin.and.ellipse")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var tagChips: some View {
        if !box.tags.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(box.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.15), in: .capsule)
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    private var contentsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(items.isEmpty ? "Contents" : "Contents · \(items.count)")
                .font(.headline)
                .padding(.bottom, 8)
            if items.isEmpty {
                Text("Nothing listed yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.tertiary)
                        Text(item)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 8)
                    if index < items.count - 1 { Divider() }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    @ViewBuilder private var updatedLine: some View {
        if let updated = Timestamp.date(from: box.updatedAt) {
            Text("Updated \(updated, format: .relative(presentation: .named))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Full-screen photo, pinch to zoom.
private struct PhotoViewer: View {
    let box: Box
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            BoxPhotoView(box: box, style: .full)
                .scaleEffect(scale)
                .gesture(MagnifyGesture()
                    .onChanged { scale = max(1, $0.magnification) }
                    .onEnded { _ in withAnimation(.spring) { scale = 1 } })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
