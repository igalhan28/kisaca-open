//
//  CourseMaterial+Files.swift
//  kisaca
//
//  What the Materials list and the notebook's material pane share: a material's file
//  type and symbol, and importing files into a lecture (from the Files picker or a drop).
//  Storage and why the bytes are not kept in memory: docs/document-format.md → Materials.
//

import Foundation
import UniformTypeIdentifiers

extension CourseMaterial {
    var contentType: UTType? { contentTypeIdentifier.flatMap(UTType.init) }

    /// SF Symbol for the file's kind.
    var symbolName: String {
        guard let type = contentType else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle.angled" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .audiovisualContent) { return "play.rectangle" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.plaintext" }
        return "doc"
    }
}

extension LectureDocument {
    /// Reads each file off the main actor, then adds it to the lecture's materials under
    /// `week` (`nil` = the whole lecture). Files from the picker are security-scoped;
    /// dropped files were already copied somewhere we own.
    func importMaterials(at urls: [URL], securityScoped: Bool, week: Int?) async
        -> (added: [CourseMaterial], errorMessage: String?)
    {
        var added: [CourseMaterial] = []
        var failed: [String] = []
        for url in urls {
            let loaded = await Task.detached { () -> (Data, UTType?)? in
                let accessing = securityScoped && url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return nil }
                let type =
                    (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                    ?? UTType(filenameExtension: url.pathExtension)
                return (data, type)
            }.value
            guard let (data, type) = loaded else {
                failed.append(url.lastPathComponent)
                continue
            }
            added.append(
                addMaterial(
                    data: data, fileName: url.lastPathComponent, contentType: type, week: week))
        }
        let message = failed.isEmpty ? nil : "Couldn't read " + failed.joined(separator: ", ") + "."
        return (added, message)
    }
}

/// Copies a dropped file out of the drop's temporary location — which is deleted as soon
/// as the drop completes — into one of our own. `nil` if the item has no file.
nonisolated func copyDroppedFile(from provider: NSItemProvider) async -> URL? {
    guard
        let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .item) == true
        }),
        let type = UTType(identifier)
    else { return nil }
    return await withCheckedContinuation { continuation in
        _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
            guard let url else {
                continuation.resume(returning: nil)
                return
            }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("DroppedMaterials", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: destination)
                continuation.resume(returning: destination)
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
