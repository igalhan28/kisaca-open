//
//  NotebookToolbox.swift
//  kisaca
//
//  The notebook's own tool state, replacing the system tool picker's bar (2026-11-09):
//  which tool the Pencil holds, each inking tool's colour and width, the eraser kind,
//  the ruler. The tool rail (`ToolRailView`) and the tool disk (`ToolDiskView`) both
//  show and change it; `NotebookPagerViewController` hands `tool` to the page on screen
//  whenever it changes or a page turns.
//
//  Kept per device in `UserDefaults`, so the notebook opens with the pen you put down.
//

import PencilKit
import UIKit

/// One tool in the rail / on the disk.
enum NotebookToolKind: String, CaseIterable {
    case pen, fountainPen, pencil, monoline, marker, eraser, lasso

    var title: String {
        switch self {
        case .pen: "Pen"
        case .fountainPen: "Fountain Pen"
        case .pencil: "Pencil"
        case .monoline: "Monoline"
        case .marker: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        }
    }

    var symbolName: String {
        switch self {
        case .pen: "pencil.tip"
        case .fountainPen: "signature"
        case .pencil: "pencil"
        case .monoline: "pencil.line"
        case .marker: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        }
    }

    var inkType: PKInkingTool.InkType? {
        switch self {
        case .pen: .pen
        case .fountainPen: .fountainPen
        case .pencil: .pencil
        case .monoline: .monoline
        case .marker: .marker
        case .eraser, .lasso: nil
        }
    }

    var isInking: Bool { inkType != nil }
}

@MainActor
final class NotebookToolbox {

    /// The colours offered in the rail and on the disk, made for the always-white page.
    static let palette: [UIColor] = ([.black, .systemBlue, .systemGreen, .systemYellow, .systemRed] as [UIColor])
        .map { $0.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)) }

    /// Thin, regular, thick — multiples of each ink's default width.
    static let widthLevels: [CGFloat] = [0.55, 1, 1.9]

    // MARK: - State

    private(set) var selected: NotebookToolKind = .pen
    /// What the Pencil's double-tap switches back to.
    private(set) var previous: NotebookToolKind = .eraser
    private var colors: [NotebookToolKind: UIColor] = [:]
    private var widthLevel: [NotebookToolKind: Int] = [:]
    /// Pixel eraser (rubs out parts of strokes) instead of the object eraser.
    private(set) var erasesPixels = false
    var isRulerActive = false { didSet { notify() } }

    /// Called after every change. Several observers — the rail, the disk, the pager.
    private var observers: [(NotebookToolbox) -> Void] = []

    init() { restore() }

    func observe(_ observer: @escaping (NotebookToolbox) -> Void) {
        observers.append(observer)
        observer(self)
    }

    private func notify() {
        save()
        for observer in observers { observer(self) }
    }

    // MARK: - Reading

    func color(for kind: NotebookToolKind) -> UIColor {
        colors[kind] ?? (kind == .marker ? Self.palette[3] : Self.palette[0])
    }

    /// The colour of the tool the Pencil holds — or, holding the eraser or lasso, of
    /// the last inking tool, which is what picking a colour then changes.
    var currentColor: UIColor { color(for: colorTarget) }

    func widthLevel(for kind: NotebookToolKind) -> Int { widthLevel[kind] ?? 1 }

    var currentWidthLevel: Int { widthLevel(for: selected == .lasso ? colorTarget : selected) }

    /// The inking tool a colour or width choice applies to.
    private var colorTarget: NotebookToolKind {
        selected.isInking ? selected : (previous.isInking ? previous : .pen)
    }

    /// The PencilKit tool for the current selection.
    var tool: any PKTool {
        switch selected {
        case .eraser:
            let type: PKEraserTool.EraserType = erasesPixels ? .bitmap : .vector
            return PKEraserTool(type, width: type.defaultWidth * Self.widthLevels[widthLevel(for: .eraser)])
        case .lasso:
            return PKLassoTool()
        default:
            let ink = selected.inkType ?? .pen
            let width = ink.defaultWidth * Self.widthLevels[widthLevel(for: selected)]
            let range = ink.validWidthRange
            return PKInkingTool(
                ink, color: color(for: selected),
                width: min(max(width, range.lowerBound), range.upperBound))
        }
    }

    // MARK: - Changing

    /// Selecting the eraser while it is already selected switches object ↔ pixel.
    func select(_ kind: NotebookToolKind) {
        if kind == selected {
            guard kind == .eraser else { return }
            erasesPixels.toggle()
        } else {
            previous = selected
            selected = kind
        }
        notify()
    }

    /// Back to the tool before this one — the Pencil's double-tap away from the eraser.
    func selectPrevious() { select(previous == selected ? .pen : previous) }

    /// Sets the colour of the inking tool in hand — holding the eraser or lasso, it
    /// takes up the last inking tool again, since a colour is only meaningful for ink.
    func setColor(_ color: UIColor) {
        let target = colorTarget
        colors[target] = color
        if target != selected {
            previous = selected
            selected = target
        }
        notify()
    }

    func setWidthLevel(_ level: Int) {
        let target = selected == .lasso ? colorTarget : selected
        widthLevel[target] = min(max(level, 0), Self.widthLevels.count - 1)
        notify()
    }

    // MARK: - Persistence (device-local)

    private static let defaultsKey = "notebookToolbox"

    private struct Stored: Codable {
        var selected: String
        var previous: String
        var colors: [String: [Double]]
        var widths: [String: Int]
        var erasesPixels: Bool
    }

    private func save() {
        let stored = Stored(
            selected: selected.rawValue, previous: previous.rawValue,
            colors: Dictionary(uniqueKeysWithValues: colors.map { ($0.key.rawValue, $0.value.rgba) }),
            widths: Dictionary(uniqueKeysWithValues: widthLevel.map { ($0.key.rawValue, $0.value) }),
            erasesPixels: erasesPixels)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        selected = NotebookToolKind(rawValue: stored.selected) ?? .pen
        previous = NotebookToolKind(rawValue: stored.previous) ?? .eraser
        for (key, rgba) in stored.colors where rgba.count == 4 {
            guard let kind = NotebookToolKind(rawValue: key) else { continue }
            colors[kind] = UIColor(
                red: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        }
        for (key, level) in stored.widths {
            if let kind = NotebookToolKind(rawValue: key) { widthLevel[kind] = level }
        }
        erasesPixels = stored.erasesPixels
    }
}

extension UIColor {
    /// sRGB components, for storing a colour.
    var rgba: [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map(Double.init)
    }

    /// Whether two colours look the same (stored colours come back as plain sRGB).
    func isClose(to other: UIColor) -> Bool {
        zip(rgba, other.rgba).allSatisfy { abs($0 - $1) < 0.01 }
    }
}
