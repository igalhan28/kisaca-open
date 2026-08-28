//
//  ContentView.swift
//  kisaca
//
//  Created by İbrahim Göktuğ ALHAN on 28.08.2026.
//

import SwiftUI

struct ContentView: View {
    @Binding var document: kisacaDocument

    var body: some View {
        TextEditor(text: $document.text)
    }
}

#Preview {
    ContentView(document: .constant(kisacaDocument()))
}
