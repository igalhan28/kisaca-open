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
//  Also remembers the last few tool + colour + width combinations you actually wrote
//  with (`recentCombos`) — what the tool wheel (`ToolWheelView`, a two-finger sideways
//  swipe) turns through.
//

import PencilKit
import UIKit

/// One tool in the rail / on the disk.
enum NotebookToolKind: String, CaseIterable, Codable {
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

/// A tool as it was used: which tool, in which colour, how wide. What the tool wheel
/// shows and switches to. Colour only for inking tools; the eraser keeps its kind.
struct ToolCombo: Equatable {
    var kind: NotebookToolKind
    var color: UIColor?
    var widthLevel: Int
    var erasesPixels: Bool

    /// The same tool, in a colour that looks the same, at the same width. The lasso
    /// has neither colour nor width — there is only one.
    static func == (lhs: ToolCombo, rhs: ToolCombo) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        switch lhs.kind {
        case .lasso: return true
        case .eraser: return lhs.erasesPixels == rhs.erasesPixels && lhs.widthLevel == rhs.widthLevel
        default:
            guard lhs.widthLevel == rhs.widthLevel else { return false }
            switch (lhs.color, rhs.color) {
            case let (l?, r?): return l.isClose(to: r)
            case (nil, nil): return true
            default: return false
            }
        }
    }

    /// "Pen, Blue, Thin" — spoken, and shown at the wheel's hub.
    var title: String {
        switch kind {
        case .lasso: return kind.title
        case .eraser:
            return [erasesPixels ? "Pixel Eraser" : "Object Eraser", NotebookToolbox.widthNames[widthLevel]]
                .joined(separator: ", ")
        default:
            return [kind.title, color?.inkName, NotebookToolbox.widthNames[widthLevel]]
                .compactMap { $0 }.joined(separator: ", ")
        }
    }

    fileprivate struct Stored: Codable {
        var kind: NotebookToolKind
        var color: [Double]?
        var widthLevel: Int
        var erasesPixels: Bool
    }

    fileprivate var stored: Stored {
        Stored(kind: kind, color: color?.rgba, widthLevel: widthLevel, erasesPixels: erasesPixels)
    }

    fileprivate init?(_ stored: Stored) {
        guard NotebookToolbox.widthLevels.indices.contains(stored.widthLevel) else { return nil }
        self.init(
            kind: stored.kind,
            color: stored.color.flatMap { $0.count == 4 ? UIColor(red: $0[0], green: $0[1], blue: $0[2], alpha: $0[3]) : nil },
            widthLevel: stored.widthLevel, erasesPixels: stored.erasesPixels)
    }

    init(kind: NotebookToolKind, color: UIColor?, widthLevel: Int, erasesPixels: Bool = false) {
        self.kind = kind
        self.color = kind.isInking ? color : nil
        self.widthLevel = widthLevel
        self.erasesPixels = kind == .eraser && erasesPixels
    }
}

@MainActor
final class NotebookToolbox {

    /// The colours offered in the rail and on the disk, made for the always-white page.
    static let palette: [UIColor] = ([.black, .systemBlue, .systemGreen, .systemYellow, .systemRed] as [UIColor])
        .map { $0.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)) }

    /// Thin, regular, thick — multiples of each ink's default width.
    static let widthLevels: [CGFloat] = [0.55, 1, 1.9]
    static let widthNames = ["Thin", "Regular", "Thick"]

    /// How many combinations the wheel remembers, and how few it ever shows — a fresh
    /// install starts from `starterCombos` so the wheel isn't empty.
    static let recentLimit = 8
    static let wheelMinimum = 4
    static let starterCombos: [ToolCombo] = [
        ToolCombo(kind: .pen, color: palette[0], widthLevel: 1),
        ToolCombo(kind: .pen, color: palette[1], widthLevel: 1),
        ToolCombo(kind: .marker, color: palette[3], widthLevel: 1),
        ToolCombo(kind: .pen, color: palette[4], widthLevel: 1),
        ToolCombo(kind: .eraser, color: nil, widthLevel: 1),
    ]

    // MARK: - State

    private(set) var selected: NotebookToolKind = .pen
    /// What the Pencil's double-tap switches back to.
    private(set) var previous: NotebookToolKind = .eraser
    private var colors: [NotebookToolKind: UIColor] = [:]
    private var widthLevel: [NotebookToolKind: Int] = [:]
    /// Pixel eraser (rubs out parts of strokes) instead of the object eraser.
    private(set) var erasesPixels = false
    var isRulerActive = false { didSet { notify() } }
    /// Most recent first. Doesn't include a combination that was only picked and never
    /// written with.
    private(set) var recentCombos: [ToolCombo] = []

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

    /// The tool in hand, as a combination.
    var currentCombo: ToolCombo {
        let kind = selected
        return ToolCombo(
            kind: kind, color: kind.isInking ? color(for: kind) : nil,
            widthLevel: kind == .lasso ? 1 : widthLevel(for: kind), erasesPixels: erasesPixels)
    }

    /// What the wheel turns through: the tool in hand first, then the ones written
    /// with most recently — topped up with starters while there are only a few.
    var wheelCombos: [ToolCombo] {
        var combos = [currentCombo]
        for combo in recentCombos where !combos.contains(combo) { combos.append(combo) }
        for combo in Self.starterCombos where combos.count < Self.wheelMinimum && !combos.contains(combo) {
            combos.append(combo)
        }
        return Array(combos.prefix(Self.recentLimit))
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

    /// Takes up a combination from the wheel — tool, colour and width at once.
    func apply(_ combo: ToolCombo) {
        if combo.kind != selected {
            previous = selected
            selected = combo.kind
        }
        if let color = combo.color, combo.kind.isInking { colors[combo.kind] = color }
        if combo.kind != .lasso {
            widthLevel[combo.kind] = min(max(combo.widthLevel, 0), Self.widthLevels.count - 1)
        }
        if combo.kind == .eraser { erasesPixels = combo.erasesPixels }
        remember(currentCombo)
        notify()
    }

    /// The tool in hand just wrote (or erased, or selected): it goes to the front of
    /// the recent combinations. Saved, but observers aren't told — nothing they show
    /// changed, and re-handing the tool to the page mid-stroke would break the stroke.
    func noteCurrentToolUsed() {
        let combo = currentCombo
        guard recentCombos.first != combo else { return }
        remember(combo)
        save()
    }

    private func remember(_ combo: ToolCombo) {
        recentCombos.removeAll { $0 == combo }
        recentCombos.insert(combo, at: 0)
        if recentCombos.count > Self.recentLimit { recentCombos.removeLast(recentCombos.count - Self.recentLimit) }
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
        var recents: [ToolCombo.Stored]?
    }

    private func save() {
        let stored = Stored(
            selected: selected.rawValue, previous: previous.rawValue,
            colors: Dictionary(uniqueKeysWithValues: colors.map { ($0.key.rawValue, $0.value.rgba) }),
            widths: Dictionary(uniqueKeysWithValues: widthLevel.map { ($0.key.rawValue, $0.value) }),
            erasesPixels: erasesPixels,
            recents: recentCombos.map(\.stored))
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
        recentCombos = (stored.recents ?? []).compactMap(ToolCombo.init)
    }
}

extension UIColor {
    /// sRGB components, for storing a colour.
    var rgba: [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map(Double.init)
    }

    /// A spoken name for an ink colour: the palette's names, else "Custom Colour".
    var inkName: String {
        let names = ["Black", "Blue", "Green", "Yellow", "Red"]
        if let index = NotebookToolbox.palette.firstIndex(where: { $0.isClose(to: self) }) {
            return names[index]
        }
        return "Custom Colour"
    }

    /// Whether two colours look the same (stored colours come back as plain sRGB).
    func isClose(to other: UIColor) -> Bool {
        zip(rgba, other.rgba).allSatisfy { abs($0 - $1) < 0.01 }
    }
}
