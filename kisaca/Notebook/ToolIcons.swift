//
//  ToolIcons.swift
//  kisaca
//
//  Drawn pictures of the notebook's tools — a pen, a fountain pen, a pencil, a
//  fineliner, a highlighter, an eraser, a lasso — lying on their side with the tip to
//  the right, the part that writes in the tool's ink colour. Used by the sidebar
//  (`ToolRailView`), where they point into the page (mirrored when it is on the right),
//  and the tool wheel (`ToolWheelView`).
//

import UIKit

@MainActor
enum ToolIcons {
    /// Every tool picture is this size; the tip touches the right edge.
    static let size = CGSize(width: 58, height: 24)

    private static let bodyColor = UIColor(white: 0.97, alpha: 1)
    // Light: the pictures sit on black (the sidebar, the dark wheel), and a black pencil
    // or the dark fountain pen would vanish without it.
    private static let outline = UIColor(white: 0.62, alpha: 1)
    private static let metal = UIColor(white: 0.78, alpha: 1)

    /// - Parameter magnification: how much larger than `size` it will be shown — drawn
    ///   with that many more pixels so it stays sharp (the wheel's hub).
    static func image(
        for kind: NotebookToolKind, ink: UIColor, erasesPixels: Bool = false, magnification: CGFloat = 1
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale *= max(magnification, 1)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let midY = size.height / 2
            switch kind {
            case .pen:
                body(cg, from: 2, to: 32, height: 12, color: bodyColor)
                band(cg, x: 26, width: 4, height: 12, color: ink)
                cone(cg, from: 32, to: 48, base: 12, tip: 3, color: bodyColor)
                cone(cg, from: 47, to: 56, base: 3, tip: 0.8, color: ink)
            case .fountainPen:
                body(cg, from: 2, to: 30, height: 12, color: UIColor(white: 0.32, alpha: 1))
                band(cg, x: 24, width: 3, height: 12, color: UIColor(red: 0.85, green: 0.7, blue: 0.4, alpha: 1))
                // The nib: a long metal leaf with a slit, its point in the ink colour.
                let nib = UIBezierPath()
                nib.move(to: CGPoint(x: 30, y: midY - 6))
                nib.addCurve(
                    to: CGPoint(x: 56, y: midY), controlPoint1: CGPoint(x: 44, y: midY - 6),
                    controlPoint2: CGPoint(x: 50, y: midY - 1))
                nib.addCurve(
                    to: CGPoint(x: 30, y: midY + 6), controlPoint1: CGPoint(x: 50, y: midY + 1),
                    controlPoint2: CGPoint(x: 44, y: midY + 6))
                nib.close()
                fill(cg, nib, metal)
                cg.setStrokeColor(UIColor(white: 0.45, alpha: 1).cgColor)
                cg.setLineWidth(0.8)
                cg.move(to: CGPoint(x: 38, y: midY))
                cg.addLine(to: CGPoint(x: 52, y: midY))
                cg.strokePath()
                cone(cg, from: 50, to: 56, base: 3, tip: 0.6, color: ink)
            case .pencil:
                body(cg, from: 2, to: 32, height: 12, color: ink.withAlphaComponent(1))
                // Facets of the hexagonal barrel.
                cg.setFillColor(UIColor.white.withAlphaComponent(0.28).cgColor)
                cg.fill(CGRect(x: 4, y: midY - 4, width: 28, height: 2.5))
                band(cg, x: 2, width: 5, height: 12, color: metal)
                cone(cg, from: 32, to: 50, base: 12, tip: 3.5, color: UIColor(red: 0.93, green: 0.8, blue: 0.62, alpha: 1))
                cone(cg, from: 49, to: 56, base: 3.5, tip: 0.8, color: darker(ink))
            case .monoline:
                body(cg, from: 2, to: 30, height: 11, color: bodyColor)
                band(cg, x: 4, width: 4, height: 11, color: ink)
                cone(cg, from: 30, to: 40, base: 11, tip: 3, color: bodyColor)
                let tube = CGRect(x: 40, y: midY - 1, width: 13, height: 2)
                fill(cg, UIBezierPath(rect: tube), metal)
                fill(cg, UIBezierPath(rect: CGRect(x: 52, y: midY - 1, width: 4, height: 2)), ink)
            case .marker:
                body(cg, from: 2, to: 32, height: 14, color: bodyColor)
                band(cg, x: 26, width: 6, height: 14, color: ink)
                // A chisel tip.
                let tip = UIBezierPath()
                tip.move(to: CGPoint(x: 32, y: midY - 5))
                tip.addLine(to: CGPoint(x: 46, y: midY - 5))
                tip.addLine(to: CGPoint(x: 56, y: midY - 1))
                tip.addLine(to: CGPoint(x: 56, y: midY + 5))
                tip.addLine(to: CGPoint(x: 32, y: midY + 5))
                tip.close()
                fill(cg, tip, ink)
            case .eraser:
                body(cg, from: 2, to: 30, height: 13, color: bodyColor)
                let block = UIBezierPath(
                    roundedRect: CGRect(x: 30, y: midY - 6.5, width: 26, height: 13), cornerRadius: 4)
                fill(cg, block, UIColor(red: 0.96, green: 0.6, blue: 0.62, alpha: 1))
                if erasesPixels {
                    // Pixel eraser: a fine-point rubber.
                    cg.setFillColor(UIColor(red: 0.85, green: 0.45, blue: 0.48, alpha: 1).cgColor)
                    cg.fill(CGRect(x: 50, y: midY - 2, width: 6, height: 4))
                }
            case .lasso:
                body(cg, from: 2, to: 28, height: 12, color: bodyColor)
                cone(cg, from: 28, to: 40, base: 12, tip: 3, color: bodyColor)
                cg.setStrokeColor(UIColor(white: 0.35, alpha: 1).cgColor)
                cg.setLineWidth(1.4)
                cg.setLineDash(phase: 0, lengths: [2.4, 2])
                cg.strokeEllipse(in: CGRect(x: 41, y: midY - 7, width: 14, height: 14))
                cg.setLineDash(phase: 0, lengths: [])
            }
        }.withRenderingMode(.alwaysOriginal)
    }

    // MARK: - Shapes

    private static func body(_ cg: CGContext, from x0: CGFloat, to x1: CGFloat, height: CGFloat, color: UIColor) {
        let rect = CGRect(x: x0, y: size.height / 2 - height / 2, width: x1 - x0, height: height)
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: [.topLeft, .bottomLeft], cornerRadii: CGSize(width: 3, height: 3))
        fill(cg, path, color)
        // A soft highlight along the top, so it reads as a cylinder.
        cg.setFillColor(UIColor.white.withAlphaComponent(0.35).cgColor)
        cg.fill(CGRect(x: x0 + 2, y: rect.minY + 1.5, width: x1 - x0 - 3, height: 1.5))
    }

    private static func band(_ cg: CGContext, x: CGFloat, width: CGFloat, height: CGFloat, color: UIColor) {
        let rect = CGRect(x: x, y: size.height / 2 - height / 2, width: width, height: height)
        fill(cg, UIBezierPath(rect: rect), color)
    }

    /// A taper from `base` high at `x0` to `tip` high at `x1`.
    private static func cone(_ cg: CGContext, from x0: CGFloat, to x1: CGFloat, base: CGFloat, tip: CGFloat, color: UIColor) {
        let midY = size.height / 2
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x0, y: midY - base / 2))
        path.addLine(to: CGPoint(x: x1, y: midY - tip / 2))
        path.addLine(to: CGPoint(x: x1, y: midY + tip / 2))
        path.addLine(to: CGPoint(x: x0, y: midY + base / 2))
        path.close()
        fill(cg, path, color)
    }

    private static func fill(_ cg: CGContext, _ path: UIBezierPath, _ color: UIColor) {
        color.setFill()
        path.fill()
        outline.setStroke()
        path.lineWidth = 0.6
        path.stroke()
        _ = cg
    }

    private static func darker(_ color: UIColor) -> UIColor {
        let c = color.rgba
        return UIColor(red: c[0] * 0.8, green: c[1] * 0.8, blue: c[2] * 0.8, alpha: 1)
    }
}
