//
//  ToolRailView.swift
//  kisaca
//
//  The notebook's sidebar: a black strip down the notebook's leading edge, the full
//  height of the screen under the status bar. From the top: back, then the tools —
//  drawn pictures of each (`ToolIcons`) pointing into the page, the one in hand slid
//  out towards it — colours, widths, ruler, insert (PaperKit's shapes / text box menu),
//  undo, redo, scrolling when they don't fit; at the bottom the materials button (a
//  notebook), which slides the course material out of the sidebar beside the notes.
//  It replaces the floating system tool picker (2026-11-09). The same tool choices are
//  on the tool disk (`ToolDiskView`), which a two-finger sideways swipe opens.
//
//  Shows `NotebookToolbox`; every tap goes out as a `NotebookToolAction` to
//  `NotebookViewController`, which applies it.
//

import UIKit

/// Something the sidebar or the disk asks the notebook to do.
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

/// Builds the controls the sidebar and the disk share, and keeps them showing the
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

    /// Each tool picture's resting transform — the disk turns them to point outwards.
    /// The tool in hand slides out along it.
    private var toolTransforms: [NotebookToolKind: CGAffineTransform] = [:]

    static let toolButtonSize = CGSize(width: ToolIcons.size.width + 4, height: 34)
    let buttonSize: CGFloat

    init(size: CGFloat, send: @escaping (NotebookToolAction) -> Void) {
        buttonSize = size
        func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol)
            configuration.preferredSymbolConfigurationForImage = .init(pointSize: size * 0.42, weight: .medium)
            configuration.baseForegroundColor = .label
            configuration.background.cornerRadius = size / 2
            let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
            button.accessibilityLabel = label
            Self.pin(button, width: size, height: size)
            return button
        }

        rulerButton = button("ruler", "Ruler") { send(.ruler) }
        undoButton = button("arrow.uturn.backward", "Undo") { send(.undo) }
        redoButton = button("arrow.uturn.forward", "Redo") { send(.redo) }
        var insert: UIButton!
        insert = button("plus.circle", "Insert Shape or Text") { send(.insert(sourceView: insert)) }
        insertButton = insert

        for kind in NotebookToolKind.allCases {
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = .zero
            let tool = UIButton(configuration: configuration, primaryAction: UIAction { _ in send(.select(kind)) })
            tool.accessibilityLabel = kind.title
            // The picture moves; the tap target stays put.
            tool.imageView?.contentMode = .center
            Self.pin(tool, width: Self.toolButtonSize.width, height: Self.toolButtonSize.height)
            toolButtons[kind] = tool
        }
        for color in NotebookToolbox.palette {
            var configuration = UIButton.Configuration.plain()
            configuration.background.cornerRadius = size / 2
            let swatch = UIButton(configuration: configuration, primaryAction: UIAction { _ in send(.color(color)) })
            swatch.accessibilityLabel = color.accessibilityName
            swatch.configurationUpdateHandler = { button in
                var configuration = button.configuration
                configuration?.image = Self.swatchImage(color, diameter: size * 0.6, ringed: button.isSelected)
                button.configuration = configuration
            }
            Self.pin(swatch, width: size, height: size)
            swatches.append(swatch)
        }
        colorWell.supportsAlpha = false
        colorWell.title = "Ink Colour"
        colorWell.addAction(
            UIAction { [weak colorWell] _ in
                if let color = colorWell?.selectedColor { send(.color(color)) }
            }, for: .valueChanged)
        Self.pin(colorWell, width: size * 0.66, height: size * 0.66)

        for (level, scale) in NotebookToolbox.widthLevels.enumerated() {
            var configuration = UIButton.Configuration.plain()
            configuration.background.cornerRadius = size / 2
            configuration.baseForegroundColor = .label
            configuration.image = UIImage(systemName: "circle.fill")
            configuration.preferredSymbolConfigurationForImage = .init(pointSize: 4 + 5 * scale)
            let widthButton = UIButton(
                configuration: configuration, primaryAction: UIAction { _ in send(.width(level)) })
            widthButton.accessibilityLabel = ["Thin", "Regular", "Thick"][level]
            Self.pin(widthButton, width: size, height: size * 0.8)
            widthButtons.append(widthButton)
        }
    }

    /// The size a control wants — what the disk gives each one it places by hand.
    func size(of view: UIView) -> CGSize {
        if toolButtons.values.contains(where: { $0 === view }) { return Self.toolButtonSize }
        if view === colorWell { return CGSize(width: buttonSize * 0.66, height: buttonSize * 0.66) }
        if widthButtons.contains(where: { $0 === view }) {
            return CGSize(width: buttonSize, height: buttonSize * 0.8)
        }
        return CGSize(width: buttonSize, height: buttonSize)
    }

    func setRestingTransform(_ transform: CGAffineTransform, for kind: NotebookToolKind) {
        toolTransforms[kind] = transform
    }

    private static func pin(_ view: UIView, width: CGFloat, height: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            view.heightAnchor.constraint(equalToConstant: height),
        ])
    }

    private static func swatchImage(_ color: UIColor, diameter: CGFloat, ringed: Bool) -> UIImage {
        let side = diameter + 8
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            let rect = CGRect(x: 4, y: 4, width: diameter, height: diameter)
            if ringed {
                UIColor.label.setStroke()
                let ring = UIBezierPath(ovalIn: rect.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 2
                ring.stroke()
            }
            let dot = rect.insetBy(dx: ringed ? 1.5 : 0, dy: ringed ? 1.5 : 0)
            color.setFill()
            UIBezierPath(ovalIn: dot).fill()
            UIColor.white.withAlphaComponent(0.5).setStroke()
            let edge = UIBezierPath(ovalIn: dot)
            edge.lineWidth = 0.5
            edge.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    /// Shows the toolbox: the tool in hand slid out, each tool's tip in its ink, the
    /// colour ringed, the width marked; undo / redo enabled as the page allows.
    func show(_ toolbox: NotebookToolbox, canUndo: Bool, canRedo: Bool) {
        let highlight = UIColor.label.withAlphaComponent(0.16)
        for (kind, button) in toolButtons {
            let selected = kind == toolbox.selected
            let ink = kind.isInking ? toolbox.color(for: kind) : .black
            button.configuration?.image = ToolIcons.image(
                for: kind, ink: ink, erasesPixels: toolbox.erasesPixels)
            let rest = toolTransforms[kind] ?? .identity
            let transform = rest.translatedBy(x: selected ? 2 : -8, y: 0)
            if button.transform != transform {
                UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                    button.transform = transform
                    button.alpha = selected ? 1 : 0.82
                }
            }
            button.accessibilityTraits = selected ? [.button, .selected] : .button
            if kind == .eraser {
                button.accessibilityValue = toolbox.erasesPixels ? "Pixel" : "Object"
            }
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
            button.configuration?.background.backgroundColor =
                level == toolbox.currentWidthLevel ? highlight : .clear
        }
        rulerButton.configuration?.background.backgroundColor =
            toolbox.isRulerActive ? highlight : .clear
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }
}

/// The black sidebar itself.
@MainActor
final class ToolRailView: UIView {
    static let width: CGFloat = 68

    let controls: ToolControls
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let backButton: UIButton
    private let materialsButton: UIButton

    /// - Parameter showsTools: off on iPhone, which only reads notes — back and
    ///   materials stay.
    init(
        showsTools: Bool, send: @escaping (NotebookToolAction) -> Void,
        onBack: @escaping () -> Void, onMaterials: @escaping () -> Void
    ) {
        controls = ToolControls(size: 44, send: send)
        backButton = Self.chromeButton("chevron.backward", label: "Back", action: onBack)
        materialsButton = Self.chromeButton("notebook", label: "Materials", action: onMaterials)
        super.init(frame: .zero)
        backgroundColor = .black
        overrideUserInterfaceStyle = .dark

        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.clipsToBounds = true
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        for subview in [backButton, scrollView, materialsButton, stack] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(backButton)
        addSubview(scrollView)
        addSubview(materialsButton)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            backButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            backButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            materialsButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),
            materialsButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            scrollView.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: materialsButton.topAnchor, constant: -10),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -4),
            stack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        guard showsTools else { return }
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

    /// The materials button is filled while the material is out.
    func setMaterialsOpen(_ open: Bool) {
        materialsButton.configuration?.image = UIImage(systemName: open ? "notebook.fill" : "notebook")
            ?? UIImage(systemName: open ? "book.closed.fill" : "book.closed")
        materialsButton.configuration?.background.backgroundColor =
            open ? UIColor.white.withAlphaComponent(0.18) : .clear
        materialsButton.accessibilityLabel = open ? "Hide Materials" : "Show Materials"
    }

    private static func chromeButton(_ symbol: String, label: String, action: @escaping () -> Void)
        -> UIButton
    {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
            ?? UIImage(systemName: "book.closed")
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 20, weight: .medium)
        configuration.baseForegroundColor = .white
        configuration.background.cornerRadius = 12
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 48),
            button.heightAnchor.constraint(equalToConstant: 48),
        ])
        return button
    }

    private static func separator() -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 28),
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
