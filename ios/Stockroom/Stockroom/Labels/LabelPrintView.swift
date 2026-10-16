//
//  LabelPrintView.swift
//  Stockroom
//
//  Preview of the label PDF, then the system print dialog (any AirPrint
//  printer, or Save to PDF) or Share (Files, AirDrop, etc.).
//

import SwiftUI
import PDFKit
import UIKit

struct LabelPrintView: View {
    @Environment(BoxStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let boxes: [Box]

    @State private var pdf: Data?
    @State private var fileURL: URL?

    private var title: String {
        boxes.isEmpty ? "Labels" : boxes.count == 1 ? "Label for Box \(boxes[0].box)" : "\(boxes.count) Labels"
    }

    /// Labels encode the app's server address. Universal Links ignore any
    /// link carrying a port, so warn when the address has one.
    private var portWarning: Bool {
        ServerConfig.validatedURL(store.serverURLString)?.port != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if boxes.isEmpty {
                    ContentUnavailableView("No Boxes to Print", systemImage: "printer",
                        description: Text("Choose at least one box."))
                } else if !store.isConfigured {
                    ContentUnavailableView("Server Not Set Up", systemImage: "desktopcomputer",
                        description: Text("Labels link to your Stockroom server. Set its address in Settings first."))
                } else {
                    if portWarning {
                        Label {
                            Text("This server address includes a port, so iPhones will open these labels in Safari instead of the app. In Settings, use your Tailscale address with **/stockroom** and no port.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1))
                    }
                    if let pdf {
                        PDFPreview(data: pdf)
                    } else {
                        ProgressView("Preparing labels…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let fileURL {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: fileURL) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Print", systemImage: "printer", action: printPDF)
                        .disabled(pdf == nil)
                }
            }
            .task { build() }
        }
    }

    private func build() {
        guard !boxes.isEmpty, store.isConfigured, pdf == nil else { return }
        let data = LabelSheet.pdf(for: LabelSheet.shelfOrder(boxes), linkBase: store.serverURLString)
        pdf = data
        let name = boxes.count == 1 ? "Stockroom Box \(boxes[0].box) Label.pdf" : "Stockroom Labels.pdf"
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        if (try? data.write(to: url, options: .atomic)) != nil { fileURL = url }
    }

    private func printPDF() {
        guard let pdf else { return }
        let info = UIPrintInfo.printInfo()
        info.outputType = .grayscale
        info.jobName = title
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = pdf
        controller.present(animated: true)
    }
}

private struct PDFPreview: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .systemGroupedBackground
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
