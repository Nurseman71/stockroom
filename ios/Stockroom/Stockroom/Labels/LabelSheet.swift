//
//  LabelSheet.swift
//  Stockroom
//
//  The printed label — same content and order as the web app's
//  buildLabelHtml (index.html): box number, EVERY contents line (never
//  clamped — a label reading "+4 more" is useless in front of the box),
//  location, tags, then the QR code with its caption.
//
//  Sheets mirror the web app's layout too: US Letter, 3.5" columns packed
//  top-to-bottom (a short label never leaves a band of blank paper beside a
//  tall one), never split across a page, dashed cut guides only on sheets.
//

import SwiftUI
import UIKit

struct PrintedLabel: View {
    let box: Box
    let link: String
    let cutGuide: Bool

    private var lines: [String] {
        box.contents.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static let gray = Color(white: 0.27)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("#\(box.box.isEmpty ? "?" : box.box)")
                .font(.system(size: 26, weight: .black))
                .monospacedDigit()
                .padding(.bottom, 4)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 10))
            }
            .padding(.bottom, 1)
            if !box.location.isEmpty {
                Text(box.location)
                    .font(.system(size: 8.5, design: .monospaced))
                    .padding(.top, 4)
            }
            if !box.tags.isEmpty {
                Text(box.tags.joined(separator: " · "))
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundStyle(Self.gray)
                    .padding(.top, 3)
            }
            HStack(spacing: 6) {
                QRShape(modules: QRMatrix.modules(for: link))
                    .fill(Color.black)
                    .frame(width: 79, height: 79)       // 1.1 in, as on the web label
                    .padding(9)                         // quiet zone (~4 modules)
                Text("Scan to open\nthis box in Stockroom")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(Self.gray)
            }
            .padding(.leading, -9)
            .padding(.top, 4)
        }
        .foregroundStyle(.black)
        .padding(14)
        .frame(width: LabelSheet.columnWidth, alignment: .leading)
        .background(Color.white)
        .overlay {
            if cutGuide {
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(Color(white: 0.6))
            }
        }
        .environment(\.colorScheme, .light)
    }
}

enum LabelSheet {
    static let page = CGSize(width: 612, height: 792)   // US Letter, points
    static let margin: CGFloat = 36                     // 0.5 in
    static let columnWidth: CGFloat = 252               // 3.5 in

    /// Shelf order: location, then box number — a printed stack matches the
    /// room you're about to walk into.
    static func shelfOrder(_ boxes: [Box]) -> [Box] {
        boxes.sorted { a, b in
            let la = BoxStore.normalizedKey(a.location), lb = BoxStore.normalizedKey(b.location)
            if la != lb {
                if la.isEmpty != lb.isEmpty { return !la.isEmpty }
                return la.localizedStandardCompare(lb) == .orderedAscending
            }
            return BoxListView.boxOrder(a, b)
        }
    }

    /// Renders labels into a vector PDF. Uses a plain Core Graphics PDF
    /// context (y-up), which is what SwiftUI's ImageRenderer draws into
    /// correctly; positions are converted from top-down layout.
    static func pdf(for boxes: [Box], linkBase: String) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }

        let columns = max(1, Int((page.width - 2 * margin) / columnWidth))
        let gutter = columns > 1 ? (page.width - 2 * margin - CGFloat(columns) * columnWidth) / CGFloat(columns - 1) : 0
        let isSheet = boxes.count > 1
        var column = 0
        var y = margin            // top-down position on the current page
        pdf.beginPDFPage(nil)

        for box in boxes {
            let label = PrintedLabel(box: box, link: LabelCode.link(base: linkBase, id: box.id), cutGuide: isSheet)
            let renderer = ImageRenderer(content: label)
            renderer.proposedSize = ProposedViewSize(width: columnWidth, height: nil)
            renderer.render { size, draw in
                if y + size.height > page.height - margin, y > margin {
                    column += 1
                    y = margin
                    if column >= columns {
                        pdf.endPDFPage()
                        pdf.beginPDFPage(nil)
                        column = 0
                    }
                }
                let x = margin + CGFloat(column) * (columnWidth + gutter)
                pdf.saveGState()
                pdf.translateBy(x: x, y: page.height - y - size.height)
                draw(pdf)
                pdf.restoreGState()
                y += size.height
            }
        }
        pdf.endPDFPage()
        pdf.closePDF()
        return data as Data
    }
}
