//
//  ToolRailView.swift
//  kisaca
//
//  The notebook's tool rail: a slim glass strip down the notebook's leading edge,
//  scrolling when it doesn't fit — tools, colours, widths, then ruler, insert (PaperKit's
//  shapes / text box menu), undo and redo. It replaces the floating system tool picker
//  (2026-11-09). The same choices are on the tool disk (`ToolDiskView`), which a
//  two-finger sideways swipe opens anywhere on the page.
//
//  Shows `NotebookToolbox`; every tap goes out as a `NotebookToolAction` to
//  `NotebookViewController`, which applies it.
//

import UIKit

/// Something the rail or the disk asks the notebook to do.
enum NotebookToolAction {
    case select(NotebookToolKind)
    case color(UIColor)
    case width(Int)
    case ruler
    /// PaperKit's insert menu (shapes, text box…), shown from `sourceView`.
    case insert(sourceView: UIView)
    case undo
    case redo
}

/// Builds the controls the rail and the disk share, and keeps them showing the
/// toolbox's state.
@MainActor
final class ToolControls {
    private(set) var toolButtons: [NotebookToolKind: UIButton] = [:]
    private(set) var swatches: [UIButton] = []
    let colorWell = UIColorWell()
    private(set) var widthButtons: [UIButton] = []
    let rulerButton: UIButton
    let insertButton: UIButton
    let undoButton: UIButton
    let redoButton: UIButton

    private let send: (NotebookToolAction) -> Void

    init(size: CGFloat, send: @escaping (NotebookToolAction) -> Void) {
        self.send = send
        func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol)
            configuration.preferredSymbolConfigurationForImage = .init(pointSize: size * 0.42, weight: .medium)
            configuration.baseForegroundColor = .label
            configuration.background.cornerRadius = size / 2
            let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
            button.accessibilityLabel = label
            button.pointerStyleProvider = { button, _, _ in
                UIPointerStyle(effect: .highlight(UITargetedPreview(view: button)))
            }
            Self.pin(button, size: size)
            return button
        }

        rulerButton = button("ruler", "Ruler") { send(.ruler) }
        undoButton = button("arrow.uturn.backward", "Undo") { send(.undo) }
        redoButton = button("arrow.uturn.forward", "Redo") { send(.redo) }
        var insert: UIButton!
        insert = button("plus.circle", "Insert Shape or Text") { send(.insert(sourceView: insert)) }
        insertButton = insert

        for kind in NotebookToolKind.allCases {
            toolButtons[kind] = button(kind.symbolName, kind.title) { send(.select(kind)) }
        }
        for color in NotebookToolbox.palette {
            var configuration = UIButton.Configuration.plain()
            configuration.background.cornerRadius = size / 2
            let swatch = UIButton(configuration: configuration, primaryAction: UIAction { _ in send(.color(color)) })
            swatch.accessibilityLabel = color.accessibilityName
            swatch.configurationUpdateHandler = { button in
                let selected = button.isSelected
                var configuration = button.configuration
                configuration?.image = Self.swatchImage(color, diameter: size * 0.62, ringed: selected)
                button.configuration = configuration
            }
            Self.pin(swatch, size: size)
            swatches.append(swatch)
        }
        colorWell.supportsAlpha = false
        colorWell.title = "Ink Colour"
        colorWell.addAction(
            UIAction { [weak colorWell] _ in
                if let color = colorWell?.selectedColor { send(.color(color)) }
            }, for: .valueChanged)
        Self.pin(colorWell, size: size * 0.7)

        for (level, scale) in NotebookToolbox.widthLevels.enumerated() {
            var configuration = UIButton.Configuration.plain()
            configuration.background.cornerRadius = size / 2
            configuration.baseForegroundColor = .label
            configuration.image = UIImage(systemName: "circle.fill")
            configuration.preferredSymbolConfigurationForImage = .init(pointSize: 5 + 5 * scale)
            let widthButton = UIButton(
                configuration: configuration, primaryAction: UIAction { _ in send(.width(level)) })
            widthButton.accessibilityLabel = ["Thin", "Regular", "Thick"][level]
            Self.pin(widthButton, size: size)
            widthButtons.append(widthButton)
        }
    }

    private static func pin(_ view: UIView, size: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size),
            view.heightAnchor.constraint(equalToConstant: size),
        ])
    }

    private static func swatchImage(_ color: UIColor, diameter: CGFloat, ringed: Bool) -> UIImage {
        let side = diameter + 8
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let rect = CGRect(x: 4, y: 4, width: diameter, height: diameter)
            if ringed {
                UIColor.label.setStroke()
                let ring = UIBezierPath(ovalIn: rect.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 2
                ring.stroke()
            }
            color.setFill()
            UIBezierPath(ovalIn: rect.insetBy(dx: ringed ? 1.5 : 0, dy: ringed ? 1.5 : 0)).fill()
            UIColor.black.withAlphaComponent(0.15).setStroke()
            let edge = UIBezierPath(ovalIn: rect.insetBy(dx: ringed ? 1.5 : 0, dy: ringed ? 1.5 : 0))
            edge.lineWidth = 0.5
            edge.stroke()
            _ = context
        }.withRenderingMode(.alwaysOriginal)
    }

    /// Shows the toolbox: the tool in hand highlighted, its colour ringed, its width
    /// marked; undo / redo enabled as the page allows.
    func show(_ toolbox: NotebookToolbox, canUndo: Bool, canRedo: Bool) {
        for (kind, button) in toolButtons {
            let selected = kind == toolbox.selected
            var configuration = button.configuration
            configuration?.background.backgroundColor =
                selected ? UIColor.label.withAlphaComponent(0.12) : .clear
            configuration?.baseForegroundColor = kind.isInking ? ink(toolbox.color(for: kind)) : .label
            if kind == .eraser {
                configuration?.image = UIImage(
                    systemName: toolbox.erasesPixels ? "eraser.line.dashed" : "eraser")
            }
            button.configuration = configuration
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
        let current = toolbox.currentColor
        var matched = false
        for (index, swatch) in swatches.enumerated() {
            let isCurrent = NotebookToolbox.palette[index].isClose(to: current)
            matched = matched || isCurrent
            swatch.isSelected = isCurrent
        }
        colorWell.selectedColor = matched ? nil : current
        for (level, button) in widthButtons.enumerated() {
            var configuration = button.configuration
            configuration?.background.backgroundColor =
                level == toolbox.currentWidthLevel ? UIColor.label.withAlphaComponent(0.12) : .clear
            button.configuration = configuration
        }
        var ruler = rulerButton.configuration
        ruler?.background.backgroundColor =
            toolbox.isRulerActive ? UIColor.label.withAlphaComponent(0.12) : .clear
        rulerButton.configuration = ruler
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    /// Ink colours are chosen for white paper; near-white ink would vanish on the
    /// glass in light mode, so the glyph darkens it a little.
    private func ink(_ color: UIColor) -> UIColor {
        let c = color.rgba
        let luminance = 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]
        return luminance > 0.85 ? .secondaryLabel : color
    }
}

/// The vertical strip itself.
@MainActor
final class ToolRailView: UIView {
    static let width: CGFloat = 56

    let controls: ToolControls
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    init(send: @escaping (NotebookToolAction) -> Void) {
        controls = ToolControls(size: 44, send: send)
        super.init(frame: .zero)

        glass.cornerConfiguration = .uniformCorners(radius: .fixed(Self.width / 2))
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)

        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.contentView.addSubview(scrollView)

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        let groups: [[UIView]] = [
            NotebookToolKind.allCases.compactMap { controls.toolButtons[$0] },
            controls.swatches + [controls.colorWell],
            controls.widthButtons,
            [controls.rulerButton, controls.insertButton, controls.undoButton, controls.redoButton],
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 { stack.addArrangedSubview(Self.separator()) }
            group.forEach(stack.addArrangedSubview)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The height that shows every control without scrolling.
    var contentHeight: CGFloat {
        stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height + 16
    }

    private static func separator() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 24),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return line
    }
}

extension UIColor {
    /// A spoken name for a palette swatch.
    fileprivate var accessibilityName: String {
        let names = ["Black", "Blue", "Green", "Yellow", "Red"]
        if let index = NotebookToolbox.palette.firstIndex(where: { $0.isClose(to: self) }) {
            return names[index]
        }
        return "Colour"
    }
}
