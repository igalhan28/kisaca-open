//
//  kisacaApp.swift
//  kisaca
//
//  Created by İbrahim Göktuğ ALHAN on 28.08.2026.
//

import SwiftUI

@main
struct kisacaApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: kisacaDocument()) { file in
            ContentView(document: file.$document)
        }
    }
}
