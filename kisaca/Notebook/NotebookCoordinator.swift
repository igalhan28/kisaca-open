//
//  NotebookCoordinator.swift
//  kisaca
//
//  Observable bridge between the SwiftUI toolbar (`NotebookScreen`) and the UIKit
//  canvas (`NotebookScrollViewController`). SwiftUI observes `currentPageIndex` /
//  `totalPages` for the page counter; toolbar actions call the methods here, which
//  just forward to the scroll view controller.
//
//  Also owns the autosave timer: periodically flushes whichever page currently has
//  the tool picker, so a page the user sits and writes on for a long time without
//  ever scrolling still gets saved regularly. Every *other* page is already flushed
//  the moment it scrolls off screen (see `NotebookScrollViewController`'s
//  `didEndDisplaying`) — this timer only needs to cover the one page that's both
//  on-screen and possibly being actively edited right now.
//

import CoreGraphics
import Foundation
import Observation
import PaperKit

@Observable
@MainActor
final class NotebookCoordinator {

    // MARK: - State (observed by SwiftUI)

    var currentPageIndex: Int = 0
    var totalPages: Int = 1
    /// False when the current page is the only one of its session — that one stays.
    var canDeleteCurrentPage: Bool = false
    /// Title of the session the current page belongs to ("W3 · Mon") — changes while
    /// scrolling a whole-section notebook, fixed for a single session.
    var currentSessionTitle: String?
    /// The session the current page belongs to — where a material added from the
    /// notebook is filed (its week).
    var currentSessionID: UUID?

    /// URL of the most recently generated PDF (consumed by the share sheet).
    var pdfURL: URL?

    /// Controls whether the share sheet is presented.
    var isShareSheetPresented: Bool = false

    /// True while the PDF is being generated (drives the loading overlay).
    var isExporting: Bool = false

    /// Body of the "Selected Text" alert, and what drives its presentation.
    var selectedTextMessage: String?
    var isSelectedTextAlertPresented: Bool = false

    // MARK: - Internal link to UIKit

    /// Set by `NotebookHostView.makeUIViewController(context:)`.
    weak var scrollVC: NotebookScrollViewController?

    /// Set by `NotebookHostView.makeUIViewController(context:)`.
    var pageRepository: PageRepository?

    // MARK: - Autosave timer

    private var autosaveTimer: Timer?

    /// Starts the periodic flush. Call from `NotebookScreen.onAppear`.
    func startAutosaveTimer(interval: TimeInterval = 8) {
        stopAutosaveTimer()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.flushActivePage() }
        }
    }

    /// Stops the periodic flush. Call from `NotebookScreen.onDisappear` and on
    /// scene-phase → background/inactive (paired with an explicit `flushActivePage()`
    /// there too).
    func stopAutosaveTimer() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
    }

    func flushActivePage() {
        scrollVC?.flushActivePage()
    }

    // MARK: - Actions (called by SwiftUI toolbar)

    func addPage() {
        scrollVC?.addPage()
    }

    func deleteCurrentPage() {
        scrollVC?.deleteCurrentPage()
    }

    /// See `NotebookScrollViewController.reclaimToolPicker()`.
    func reclaimToolPicker() {
        scrollVC?.reclaimToolPicker()
    }

    func clear() {
        scrollVC?.clearActivePage()
    }

    func undo() {
        scrollVC?.undoActivePage()
    }

    // MARK: - Selected text

    /// Reads the text out of whatever the user has selected on the active page and
    /// shows it in an alert.
    ///
    /// Stands in for the eventual "Search the Web for Selection" action. PaperKit's own
    /// long-press menu (the one with "Copy as Text") is closed — the framework exposes
    /// no hook for adding an item to it — so any action on the selection has to live on
    /// our own toolbar and read `PaperMarkupViewController.selectedMarkup` itself.
    ///
    /// Whether `indexableContent` covers *handwriting* (as opposed to only text boxes)
    /// is not documented and can't be checked in the simulator without a Pencil, so the
    /// alert reports which case it hit rather than silently showing nothing.
    func showSelectedText() {
        guard let selection = scrollVC?.activeSelection else {
            present("Nothing is selected on this page.")
            return
        }

        let frame = selection.contentsRenderFrame

        Task { @MainActor in
            switch await selection.indexableContent {
            case .none:
                present(Self.noTextMessage(reason: "indexableContent was nil", frame: frame))
            case .some(let text) where text.isEmpty:
                present(Self.noTextMessage(reason: "indexableContent was empty", frame: frame))
            case .some(let text):
                present(text)
            }
        }
    }

    private func present(_ message: String) {
        selectedTextMessage = message
        isSelectedTextAlertPresented = true
    }

    private static func noTextMessage(reason: String, frame: CGRect) -> String {
        "The selection has no extractable text.\n(\(reason) — selection frame \(describe(frame)))"
    }

    private static func describe(_ rect: CGRect) -> String {
        guard !rect.isNull else { return "null" }
        return String(
            format: "%.0f×%.0f at (%.0f, %.0f)",
            rect.width, rect.height, rect.minX, rect.minY)
    }

    // MARK: - PDF Export

    /// Triggers async PDF generation; sets `pdfURL` and presents the share sheet when done.
    /// - Parameters:
    ///   - pageIndices: pages to include, in order. `nil` exports every page (used by
    ///     "Export All"); a subset is used by the "Select Pages" flow (`PDFExportSheet`).
    ///   - fileName: desired PDF name (without extension), e.g. "Calculus II - Exercise
    ///     Sessions - 29.10.2026". `nil` falls back to a timestamped default.
    func generatePDF(pageIndices: [Int]? = nil, fileName: String? = nil) {
        guard let scrollVC, let pageRepository else { return }
        guard !isExporting else { return }  // Prevent double-tap.

        // Capture live markup before going async (on the main actor).
        scrollVC.flushActivePage()
        let activeMarkup = scrollVC.activeMarkup
        let activeIndex = currentPageIndex

        isExporting = true

        Task { @MainActor in
            let url = await PDFExporter.generatePDF(
                from: pageRepository,
                activeMarkup: activeMarkup,
                activeIndex: activeIndex,
                pageIndices: pageIndices,
                fileName: fileName
            )
            pdfURL = url
            isExporting = false
            isShareSheetPresented = true
        }
    }
}
