//
//  QRCode.swift
//  Stockroom
//
//  QR codes generated on the phone with Core Image — no network, no third
//  party. (The web app once sent every label's link, Tailscale hostname
//  included, to a public QR service; this never does.) Output is the
//  module grid, drawn as vector squares so labels print sharp at any DPI.
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

nonisolated enum QRMatrix {
    /// Dark/light modules for `text`, top row first, quiet zone trimmed.
    static func modules(for text: String) -> [[Bool]] {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return [] }

        let extent = output.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        var pixels = [UInt8](repeating: 255, count: width * height)
        CIContext().render(output, toBitmap: &pixels, rowBytes: width, bounds: extent,
                           format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())

        var grid: [[Bool]] = (0..<height).map { y in
            (0..<width).map { x in pixels[y * width + x] < 128 }
        }
        // Trim Core Image's margin to the symbol itself.
        let rows = grid.indices.filter { grid[$0].contains(true) }
        let cols = (0..<width).filter { x in grid.contains { $0[x] } }
        guard let top = rows.first, let bottom = rows.last,
              let left = cols.first, let right = cols.last else { return [] }
        grid = grid[top...bottom].map { Array($0[left...right]) }

        // Core Image's bitmap row order isn't something to trust blindly: a
        // vertically mirrored QR won't scan. Finder patterns sit top-left,
        // top-right and bottom-left — if one is bottom-right instead, flip.
        if !hasFinder(grid, atRow: 0, col: grid.count - 7), hasFinder(grid, atRow: grid.count - 7, col: grid.count - 7) {
            grid.reverse()
        }
        return grid
    }

    /// True if a 7×7 finder pattern starts at (row, col).
    static func hasFinder(_ g: [[Bool]], atRow r: Int, col c: Int) -> Bool {
        guard r >= 0, c >= 0, r + 7 <= g.count, c + 7 <= (g.first?.count ?? 0) else { return false }
        for i in 0..<7 {
            for j in 0..<7 {
                let ring = i == 0 || i == 6 || j == 0 || j == 6
                let core = (2...4).contains(i) && (2...4).contains(j)
                if g[r + i][c + j] != (ring || core) { return false }
            }
        }
        return true
    }
}

/// Draws a module grid as filled squares (vector in PDFs).
nonisolated struct QRShape: Shape {
    let modules: [[Bool]]

    func path(in rect: CGRect) -> Path {
        let n = CGFloat(modules.count)
        guard n > 0 else { return Path() }
        let size = min(rect.width, rect.height) / n
        var path = Path()
        for (y, row) in modules.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                path.addRect(CGRect(x: rect.minX + CGFloat(x) * size,
                                    y: rect.minY + CGFloat(y) * size,
                                    width: size, height: size))
            }
        }
        return path
    }
}
