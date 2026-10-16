//
//  ContentView.swift
//  Stockroom
//
//  The app's real entry point is RootView (see StockroomApp). This file
//  holds Xcode Previews with sample boxes, so the Duo layout can be
//  checked in the canvas — try the device selector at the bottom of the
//  canvas to switch between the unfolded and folded screens.
//

import SwiftUI

#if DEBUG
enum PreviewData {
    static let boxes: [Box] = [
        Box(id: "b_preview_000001", box: "1", contents: "Hand saw\nHitch ball mount\nBungee cords",
            location: "Basement", tags: ["Tools", "Car"], photoFilename: nil,
            updatedAt: "2026-10-16T14:00:00.000Z", deleted: false),
        Box(id: "b_preview_000002", box: "2", contents: "Christmas lights\nExtension cords\nTimer plugs",
            location: "Garage", tags: ["Holiday"], photoFilename: nil,
            updatedAt: "2026-10-15T14:00:00.000Z", deleted: false),
        Box(id: "b_preview_000003", box: "10", contents: "Blu-ray box sets\nDVD cases",
            location: "Basement", tags: ["Media"], photoFilename: nil,
            updatedAt: "2026-10-14T14:00:00.000Z", deleted: false),
        Box(id: "b_preview_000004", box: "3", contents: "Camping stove\nLantern\nTent stakes",
            location: "Attic", tags: ["Camping", "Outdoor"], photoFilename: nil,
            updatedAt: "2026-10-13T14:00:00.000Z", deleted: false),
    ]
}

#Preview("Stockroom") {
    RootView()
        .environment(BoxStore(previewBoxes: PreviewData.boxes))
}

#Preview("Box detail") {
    NavigationStack {
        BoxDetailView(box: PreviewData.boxes[0])
    }
    .environment(BoxStore(previewBoxes: PreviewData.boxes))
}
#endif
