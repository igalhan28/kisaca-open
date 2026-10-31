//
//  MaterialPreview.swift
//  kisaca
//
//  Opens a course material full screen, read-only: PDFs in PDFKit (so they resume where
//  they were left — `MaterialPDFReaderViewController`), everything else in Quick Look.
//
//  Materials are reference copies — the script as the lecturer published it — so they are
//  never edited in the app; notes belong in the notebook. Quick Look offers a Markup
//  button by default, and with SwiftUI's `quickLookPreview` modifier it drew on a
//  temporary copy that was silently thrown away on close. Presenting
//  `QLPreviewController` directly lets its delegate turn editing off (`.disabled`), so
//  the button isn't offered at all.
//

import PDFKit
import QuickLook
import UIKit

/// Quick Look (and sharing) need a file URL with the file's real name, but a material's
/// bytes live inside the lecture package under an ID. This writes them out to a temp
/// folder per material, under the original name.
enum MaterialFiles {
    static func temporaryCopy(of material: CourseMaterial, data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Materials", isDirectory: true)
            .appendingPathComponent(material.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(material.originalFileName)
        try data.write(to: url, options: .atomic)
        return url
    }
}

@MainActor
final class MaterialPreviewer: NSObject {
    nonisolated private let fileURL: URL
    private let onDismiss: () -> Void

    /// - Parameters:
    ///   - fileURL: The temporary copy to preview, named like the original file.
    ///   - onDismiss: Called when the preview closes; the caller releases this object.
    init(fileURL: URL, onDismiss: @escaping () -> Void) {
        self.fileURL = fileURL
        self.onDismiss = onDismiss
    }

    /// Presents full screen from `presenter` (the Materials list).
    func present(from presenter: UIViewController) {
        let controller = QLPreviewController()
        controller.dataSource = self
        controller.delegate = self
        presenter.present(controller, animated: true)
    }
}

extension MaterialPreviewer: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
        -> any QLPreviewItem
    {
        fileURL as NSURL
    }
}

// `nonisolated`, with an explicit hop: Quick Look does not promise to call its delegate
// on the main thread.
extension MaterialPreviewer: QLPreviewControllerDelegate {
    /// Read-only: no Markup button.
    nonisolated func previewController(
        _ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem
    ) -> QLPreviewItemEditingMode {
        .disabled
    }

    nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
        Task { @MainActor in self.onDismiss() }
    }
}

/// A PDF material full screen: PDFKit rather than Quick Look, because Quick Look can't be
/// told which page to open on, and a script should open where it was left
/// (`ResumingPDFView`). Read-only like Quick Look, with its own share button.
final class MaterialPDFReaderViewController: UIViewController {
    private let pdfView: ResumingPDFView
    /// The temporary copy under the original file name — what gets shared.
    private let fileURL: URL

    init(material: CourseMaterial, document: PDFDocument, fileURL: URL) {
        pdfView = ResumingPDFView(document: document, materialID: material.id)
        self.fileURL = fileURL
        super.init(nibName: nil, bundle: nil)
        title = material.title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Presents full screen from `presenter` (the Materials list).
    func present(from presenter: UIViewController) {
        let navigation = UINavigationController(rootViewController: self)
        navigation.modalPresentationStyle = .fullScreen
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.frame = view.bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pdfView)

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Share", image: UIImage(systemName: "square.and.arrow.up"),
            primaryAction: UIAction { [weak self] action in self?.share(from: action.sender) })
    }

    private func share(from sender: Any?) {
        let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        controller.popoverPresentationController?.sourceItem =
            (sender as? UIPopoverPresentationControllerSourceItem) ?? navigationItem.rightBarButtonItem
        present(controller, animated: true)
    }
}
