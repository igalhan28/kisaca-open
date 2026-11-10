//
//  ToolRailView.swift
//  kisaca
//
//  The notebook's sidebar — a dock, in the manner of Ubuntu's: a black strip pinned to
//  the screen's left edge (the right edge in left-handed mode), the full height of the
//  screen. With the status strip across the top (`NotebookViewController`) it makes
//  one dark frame, so the clock and battery always read white on black.
//
//  From the top:
//  - back;
//  - the applets — panels that slide out of the sidebar beside the notes (course
//    material for now; `addApplet` takes more). An open applet's button is filled and
//    marked with a dot on the screen-edge side, like a running app in the dock;
//  - the tools — drawn pictures of each (`ToolIcons`) pointing into the page, the one
//    in hand slid out towards it — colours, widths, ruler, insert (PaperKit's shapes /
//    text box menu). Every option is here; when they don't fit, this part scrolls,
//    with its own always-visible scrollbar (`RailScrollbar`) on the page side;
//  - undo and redo, pinned at the bottom so they never scroll away.
//
//  Shows `NotebookToolbox`; every tap goes out as a `NotebookToolAction` to
//  `NotebookViewController`, which applies it. The tool wheel (`ToolWheelView`) is the
//  quick way between recently used tools; the sidebar has everything.
//

import UIKit

/// Something the sidebar asks the notebook to do.
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

/// Builds the sidebar's tool controls and keeps them showing the toolbox's state.
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

    /// Each tool picture's resting transform — mirrored when the sidebar is on the
    /// right, so the tips point into the page. The tool in hand slides out along it.
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
            swatch.accessibilityLabel = color.inkName
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
            widthButton.accessibilityLabel = NotebookToolbox.widthNames[level]
            Self.pin(widthButton, width: size, height: size * 0.8)
            widthButtons.append(widthButton)
        }
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
                // Not `.label`: drawn into an image it resolves outside the sidebar's dark
                // trait and came out black — invisible on the black sidebar.
                UIColor.white.setStroke()
                let ring = UIBezierPath(ovalIn: rect.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 2
                ring.stroke()
            }
            let dot = rect.insetBy(dx: ringed ? 1.5 : 0, dy: ringed ? 1.5 : 0)
            color.setFill()
            UIBezierPath(ovalIn: dot).fill()
            // An edge so the black swatch shows on the black sidebar.
            UIColor.white.withAlphaComponent(0.55).setStroke()
            let edge = UIBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
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

/// An applet in the sidebar: a panel the sidebar opens beside the notes.
struct RailApplet {
    let id: String
    let title: String
    let symbol: String
    /// Shown while the applet is open.
    let activeSymbol: String
    let action: () -> Void
}

/// The sidebar itself.
@MainActor
final class ToolRailView: UIView {
    /// The strip's width; the outermost `scrollbarGutter` of it, on the page side, is
    /// the scrollbar's.
    static let width: CGFloat = 72
    private static let scrollbarGutter: CGFloat = 8
    /// The sidebar's colour, shared with the status strip so they read as one.
    static let backgroundColor = UIColor.black

    enum Edge { case left, right }

    let controls: ToolControls
    private let backButton: UIButton
    private let appletStack = UIStackView()
    private var applets: [String: AppletButton] = [:]

    /// The scrolling part — the tools — clipped with a fade where more is hidden.
    private let toolsClip = UIView()
    private let fadeMask = CAGradientLayer()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let scrollbar = RailScrollbar()
    private let pinnedStack = UIStackView()
    private var stackLeft: NSLayoutConstraint!
    private var scrollbarLeft: NSLayoutConstraint!
    private var lastSelected: NotebookToolKind?

    /// Which edge of the screen the sidebar is pinned to. Tool tips point away from it,
    /// into the page; the scrollbar runs on the page side, open-applet dots on this one.
    var edge: Edge = .left {
        didSet {
            guard edge != oldValue else { return }
            applyEdge()
        }
    }

    /// - Parameter showsTools: off on iPhone, which only reads notes — back and the
    ///   applets stay.
    init(showsTools: Bool, send: @escaping (NotebookToolAction) -> Void, onBack: @escaping () -> Void) {
        controls = ToolControls(size: 44, send: send)
        backButton = AppletButton.chrome("chevron.backward", label: "Back", action: onBack)
        super.init(frame: .zero)
        backgroundColor = Self.backgroundColor
        overrideUserInterfaceStyle = .dark

        appletStack.axis = .vertical
        appletStack.alignment = .center
        appletStack.spacing = 4

        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.clipsToBounds = false
        scrollView.delegate = self
        // Taps on the tools must not wait to find out whether they start a scroll.
        scrollView.delaysContentTouches = false
        toolsClip.clipsToBounds = true
        fadeMask.colors = [UIColor.clear, .black, .black, .clear].map(\.cgColor)
        toolsClip.layer.mask = fadeMask
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6

        pinnedStack.axis = .vertical
        pinnedStack.alignment = .center
        pinnedStack.spacing = 2

        scrollbar.onScrub = { [weak self] fraction in self?.scroll(toFraction: fraction) }

        let topSeparator = Self.separator()
        let bottomSeparator = Self.separator()
        for subview in [backButton, appletStack, topSeparator, toolsClip, scrollView, stack, scrollbar, bottomSeparator, pinnedStack] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(backButton)
        addSubview(appletStack)
        addSubview(topSeparator)
        addSubview(toolsClip)
        toolsClip.addSubview(scrollView)
        scrollView.addSubview(stack)
        addSubview(scrollbar)
        addSubview(bottomSeparator)
        addSubview(pinnedStack)

        let contentWidth = Self.width - Self.scrollbarGutter
        // Horizontally everything keeps to the safe area: on an iPhone in landscape the
        // sidebar is widened by the notch's inset (`NotebookViewController`), and the
        // controls stay clear of it.
        let safe = safeAreaLayoutGuide
        stackLeft = stack.leftAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leftAnchor)
        scrollbarLeft = scrollbar.leftAnchor.constraint(equalTo: safe.leftAnchor, constant: contentWidth + 2)
        NSLayoutConstraint.activate([
            backButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            backButton.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            appletStack.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 4),
            appletStack.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            appletStack.widthAnchor.constraint(equalTo: safe.widthAnchor),
            topSeparator.topAnchor.constraint(equalTo: appletStack.bottomAnchor, constant: 8),
            topSeparator.centerXAnchor.constraint(equalTo: safe.centerXAnchor),

            toolsClip.topAnchor.constraint(equalTo: topSeparator.bottomAnchor, constant: 2),
            toolsClip.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor, constant: -2),
            toolsClip.leftAnchor.constraint(equalTo: safe.leftAnchor),
            toolsClip.rightAnchor.constraint(equalTo: safe.rightAnchor),
            scrollView.topAnchor.constraint(equalTo: toolsClip.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: toolsClip.bottomAnchor),
            scrollView.leftAnchor.constraint(equalTo: toolsClip.leftAnchor),
            scrollView.rightAnchor.constraint(equalTo: toolsClip.rightAnchor),
            scrollView.contentLayoutGuide.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -10),
            stack.widthAnchor.constraint(equalToConstant: contentWidth),
            stackLeft,

            scrollbar.topAnchor.constraint(equalTo: toolsClip.topAnchor, constant: 6),
            scrollbar.bottomAnchor.constraint(equalTo: toolsClip.bottomAnchor, constant: -6),
            scrollbar.widthAnchor.constraint(equalToConstant: Self.scrollbarGutter - 4),
            scrollbarLeft,

            bottomSeparator.bottomAnchor.constraint(equalTo: pinnedStack.topAnchor, constant: -6),
            bottomSeparator.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            pinnedStack.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8),
            pinnedStack.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
        ])

        guard showsTools else {
            // Nothing to scroll or pin: the separators would only divide empty space.
            bottomSeparator.isHidden = true
            scrollbar.isHidden = true
            return
        }
        let groups: [[UIView]] = [
            NotebookToolKind.allCases.compactMap { controls.toolButtons[$0] },
            controls.swatches + [controls.colorWell],
            controls.widthButtons,
            [controls.rulerButton, controls.insertButton],
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 { stack.addArrangedSubview(Self.separator()) }
            group.forEach(stack.addArrangedSubview)
        }
        pinnedStack.addArrangedSubview(controls.undoButton)
        pinnedStack.addArrangedSubview(controls.redoButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Applets

    /// Adds an applet's button under the ones already there.
    func addApplet(_ applet: RailApplet) {
        let button = AppletButton(applet: applet)
        button.edge = edge
        applets[applet.id] = button
        appletStack.addArrangedSubview(button)
    }

    /// Fills the applet's button and marks it while its panel is open.
    func setApplet(_ id: String, active: Bool) {
        applets[id]?.isActive = active
    }

    // MARK: - Tools

    /// Shows the toolbox; a tool that became the one in hand is scrolled into view.
    func show(_ toolbox: NotebookToolbox, canUndo: Bool, canRedo: Bool) {
        controls.show(toolbox, canUndo: canUndo, canRedo: canRedo)
        guard toolbox.selected != lastSelected, window != nil,
            let button = controls.toolButtons[toolbox.selected]
        else { return }
        lastSelected = toolbox.selected
        layoutIfNeeded()
        let frame = button.convert(button.bounds, to: scrollView).insetBy(dx: 0, dy: -12)
        scrollView.scrollRectToVisible(frame, animated: true)
    }

    // MARK: - Layout

    private func applyEdge() {
        let contentWidth = Self.width - Self.scrollbarGutter
        // The tools sit against the screen edge, the scrollbar on the page side.
        stackLeft.constant = edge == .left ? 0 : Self.scrollbarGutter
        scrollbarLeft.constant = edge == .left ? contentWidth + 2 : 2
        let mirror: CGAffineTransform = edge == .left ? .identity : CGAffineTransform(scaleX: -1, y: 1)
        for kind in NotebookToolKind.allCases { controls.setRestingTransform(mirror, for: kind) }
        for button in applets.values { button.edge = edge }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateScrollIndicators()
    }

    private func updateScrollIndicators() {
        let visible = scrollView.bounds.height
        let content = scrollView.contentSize.height
        let maxOffset = max(content - visible, 0)
        let offset = min(max(scrollView.contentOffset.y, 0), maxOffset)
        scrollbar.update(visible: visible, content: content, offset: offset)

        // Fade the clipped edge only where there is more to scroll to.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = toolsClip.bounds
        let height = max(toolsClip.bounds.height, 1)
        let fade = min(18 / height, 0.25)
        let top = offset > 1 ? fade : 0
        let bottom = offset < maxOffset - 1 ? fade : 0
        fadeMask.locations = [0, NSNumber(value: Double(top)), NSNumber(value: Double(1 - bottom)), 1]
        CATransaction.commit()
    }

    private func scroll(toFraction fraction: CGFloat) {
        let maxOffset = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        scrollView.contentOffset.y = (maxOffset * min(max(fraction, 0), 1)).rounded()
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

extension ToolRailView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateScrollIndicators()
    }
}

// MARK: - Applet button

/// A dock button: filled while its applet is open, with a dot on the screen-edge side.
@MainActor
private final class AppletButton: UIButton {
    private let applet: RailApplet
    private let dot = UIView()

    var edge: ToolRailView.Edge = .left { didSet { setNeedsLayout() } }
    var isActive = false { didSet { refresh() } }

    init(applet: RailApplet) {
        self.applet = applet
        super.init(frame: .zero)
        configuration = Self.baseConfiguration(applet.symbol)
        addAction(UIAction { _ in applet.action() }, for: .primaryActionTriggered)
        dot.backgroundColor = .white
        dot.layer.cornerRadius = 2.5
        dot.isHidden = true
        dot.isUserInteractionEnabled = false
        addSubview(dot)
        Self.pinSize(self)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A plain sidebar button (back).
    static func chrome(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(configuration: baseConfiguration(symbol), primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        pinSize(button)
        return button
    }

    private static func baseConfiguration(_ symbol: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 20, weight: .medium)
        configuration.baseForegroundColor = .white
        configuration.background.cornerRadius = 12
        return configuration
    }

    private static func pinSize(_ button: UIButton) {
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 48),
            button.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func refresh() {
        configuration?.image = UIImage(systemName: isActive ? applet.activeSymbol : applet.symbol)
        configuration?.background.backgroundColor = isActive ? UIColor.white.withAlphaComponent(0.18) : .clear
        accessibilityLabel = applet.title
        accessibilityTraits = isActive ? [.button, .selected] : .button
        dot.isHidden = !isActive
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // In the gap between the button and the screen edge: (72 − 48) / 2 = 12 pt.
        let x = edge == .left ? -9 : bounds.maxX + 4
        dot.frame = CGRect(x: x, y: bounds.midY - 2.5, width: 5, height: 5)
    }
}

// MARK: - Scrollbar

/// The tools' scrollbar: a thin track with a thumb sized to what's visible, shown
/// whenever the tools don't all fit — always, not only while scrolling, so it's
/// plain that there is more. Dragging or tapping along it scrolls.
@MainActor
private final class RailScrollbar: UIView {
    var onScrub: (CGFloat) -> Void = { _ in }

    private let track = UIView()
    private let thumb = UIView()
    private var thumbFraction: CGFloat = 1
    private var offsetFraction: CGFloat = 0
    private var grabOffset: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        thumb.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        track.isUserInteractionEnabled = false
        thumb.isUserInteractionEnabled = false
        addSubview(track)
        addSubview(thumb)
        isHidden = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(scrubbed(_:)))
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(scrubbed(_:)))
        addGestureRecognizer(tap)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A finger-sized target around the 4 pt bar.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -3, dy: 0).contains(point)
    }

    func update(visible: CGFloat, content: CGFloat, offset: CGFloat) {
        let overflows = content > visible + 1 && visible > 0
        isHidden = !overflows
        guard overflows else { return }
        thumbFraction = max(visible / content, 0.12)
        offsetFraction = offset / (content - visible)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width: CGFloat = 4
        let x = (bounds.width - width) / 2
        track.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
        track.layer.cornerRadius = width / 2
        let height = (bounds.height * thumbFraction).rounded()
        let y = ((bounds.height - height) * offsetFraction).rounded()
        thumb.frame = CGRect(x: x, y: y, width: width, height: height)
        thumb.layer.cornerRadius = width / 2
    }

    @objc private func scrubbed(_ recognizer: UIGestureRecognizer) {
        let y = recognizer.location(in: self).y
        let travel = bounds.height - thumb.frame.height
        guard travel > 0 else { return }
        if recognizer is UIPanGestureRecognizer, recognizer.state == .began {
            // Grabbing the thumb drags it from where it was held; anywhere else on the
            // track jumps it there first.
            grabOffset = thumb.frame.contains(CGPoint(x: thumb.frame.midX, y: y))
                ? y - thumb.frame.minY : thumb.frame.height / 2
        } else if recognizer is UITapGestureRecognizer {
            grabOffset = thumb.frame.height / 2
        }
        onScrub((y - grabOffset) / travel)
    }
}

