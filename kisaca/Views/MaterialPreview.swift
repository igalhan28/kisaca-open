//
//  MaterialPreview.swift
//  kisaca
//
//  Opens a course material in Quick Look, read-only.
//
//  Materials are reference copies — the script as the lecturer published it — so they are
//  never edited in the app; notes belong in the notebook. Quick Look offers a Markup
//  button by default, and with SwiftUI's `quickLookPreview` modifier it drew on a
//  temporary copy that was silently thrown away on close. Presenting
//  `QLPreviewController` directly lets its delegate turn editing off (`.disabled`), so
//  the button isn't offered at all.
//

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

    /// Presents full screen from the top-most view controller of the key window.
    func present() {
        let controller = QLPreviewController()
        controller.dataSource = self
        controller.delegate = self
        guard
            let root = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?.rootViewController
        else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
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
