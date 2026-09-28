//
//  UTType+Kisaca.swift
//  kisaca
//
//  The `.kisaca` lecture document type. Must match the `UTExportedTypeDeclarations`
//  entry in Info.plist exactly (identifier + filename extension) — if you change one,
//  change the other. See docs/document-format.md.
//

import UniformTypeIdentifiers

extension UTType {
    /// A lecture document package: `manifest.json` + `Pages/` + `Thumbnails/`.
    static var kisacaLecture: UTType {
        UTType(exportedAs: "com.igalhan.kisaca.lecture")
    }
}
