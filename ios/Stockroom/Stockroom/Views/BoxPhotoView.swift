//
//  BoxPhotoView.swift
//  Stockroom
//
//  Shows one of a box's photos (the cover unless `name` says otherwise) from disk, fetching it from the Mac when the local
//  copy is missing or stale. Thumbnails are decoded at display size so a
//  long list doesn't hold full-resolution photos in memory.
//

import SwiftUI
import UIKit

struct BoxPhotoView: View {
    enum Style { case thumbnail, hero, full }

    @Environment(BoxStore.self) private var store
    let box: Box
    let style: Style
    /// Which photo; nil means the cover.
    var name: String? = nil

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: style == .full ? .fit : .fill)
            } else {
                Rectangle().fill(Color(.tertiarySystemFill))
                Image(systemName: box.photoFilename == nil ? "shippingbox" : "photo")
                    .font(style == .thumbnail ? .title3 : .largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: "\(box.id)|\(name ?? "cover")|\(box.updatedAt)|\(store.photoRevision(for: box.id))") {
            await load()
            await store.refreshPhotoIfNeeded(for: box, name: name)
            await load()
        }
    }

    private func load() async {
        guard let url = store.localPhotoURL(for: box, name: name),
              let full = UIImage(contentsOfFile: url.path(percentEncoded: false)) else {
            image = nil
            return
        }
        switch style {
        case .thumbnail: image = await Self.downscale(full, longEdge: 168)
        case .hero: image = await Self.downscale(full, longEdge: 1400)
        case .full: image = full
        }
    }

    /// Aspect-preserving downscale; never upscales.
    private static func downscale(_ image: UIImage, longEdge: CGFloat) async -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > longEdge else { return image }
        let factor = longEdge / longest
        let size = CGSize(width: (image.size.width * factor).rounded(), height: (image.size.height * factor).rounded())
        return await image.byPreparingThumbnail(ofSize: size) ?? image
    }
}
