//
//  CameraPicker.swift
//  Stockroom
//
//  The system camera, plus the JPEG preparation every photo goes through
//  before it is stored or uploaded.
//

import SwiftUI
import UIKit

/// Wraps UIImagePickerController's camera. (PhotosPicker covers the
/// library; SwiftUI still has no first-party camera capture view.)
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

nonisolated enum PhotoPrep {
    /// Long edge in pixels. The web app uses 900 to fit localStorage; the
    /// native app has no such limit, so a sharper 1600 keeps labels and
    /// small print in the box legible (and helps identification).
    static let maxDimension: CGFloat = 1600
    static let quality: CGFloat = 0.7

    /// Downscales, bakes in orientation, and re-encodes as JPEG. Re-encoding
    /// from pixels also drops all EXIF metadata — including GPS location —
    /// so photos of what's in your house don't carry where your house is.
    static func jpeg(from image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let factor = min(1, maxDimension / longest)
        let size = CGSize(width: (image.size.width * factor).rounded(),
                          height: (image.size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}
