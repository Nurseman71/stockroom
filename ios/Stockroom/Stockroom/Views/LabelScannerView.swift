//
//  LabelScannerView.swift
//  Stockroom
//
//  Scans a printed Stockroom label and opens that box. Labels encode
//  "<server>?boxid=<id>" (index.html, labelUrl). Only the box id is used,
//  and only to look the box up locally — scanning never makes the app
//  contact whatever host a QR code names, so a stray or malicious code
//  can't redirect it anywhere.
//

import SwiftUI
import Vision
import VisionKit

nonisolated enum LabelCode {
    /// The box id inside a scanned label, or nil if it isn't a Stockroom label.
    static func boxID(from payload: String) -> String? {
        guard let components = URLComponents(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)),
              let id = components.queryItems?.first(where: { $0.name == "boxid" })?.value,
              !id.isEmpty, !id.contains("/") else { return nil }
        return id
    }
}

struct LabelScannerSheet: View {
    @Environment(BoxStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Called with the id of a box that exists on this phone.
    let onOpen: (String) -> Void

    @State private var message: String?
    @State private var lookingUp = false

    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            QRScanner { payload in handle(payload) }
                .ignoresSafeArea()
                .overlay(alignment: .bottom) {
                    Group {
                        if lookingUp {
                            HStack(spacing: 8) { ProgressView(); Text("Looking for that box…") }
                        } else {
                            Text(message ?? "Point at a Stockroom box label")
                        }
                    }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.bottom, 40)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .navigationTitle("Scan Label")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func handle(_ payload: String) {
        guard !lookingUp else { return }
        guard let id = LabelCode.boxID(from: payload) else {
            message = "That QR code isn't a Stockroom label."
            return
        }
        if store.box(id: id) != nil {
            open(id)
            return
        }
        // Possibly created on another device since the last sync.
        lookingUp = true
        Task {
            await store.sync()
            lookingUp = false
            if store.box(id: id) != nil { open(id) }
            else { message = "No box with that label — it may have been deleted." }
        }
    }

    private func open(_ id: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onOpen(id)
        dismiss()
    }
}

/// VisionKit's live scanner, restricted to QR codes.
private struct QRScanner: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        // Starting in make…() is too early (not on screen yet); this runs once it is.
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            report(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didTapOn item: RecognizedItem) {
            report([item])
        }

        private func report(_ items: [RecognizedItem]) {
            for item in items {
                if case .barcode(let code) = item, let payload = code.payloadStringValue {
                    onFound(payload)
                    return
                }
            }
        }
    }
}
