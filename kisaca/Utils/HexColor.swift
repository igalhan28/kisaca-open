//
//  HexColor.swift
//  kisaca
//
//  Created by İbrahim Göktuğ ALHAN on 1.11.2026.
//


import CoreGraphics
import Foundation
import UIKit

extension UIColor {
    /// Initializes a UIColor using an integer hex value (e.g., 0xFFFCFA).
    /// - Parameters:
    ///   - hex: The 24-bit integer representation of the color.
    ///   - alpha: The opacity level, ranging from 0.0 to 1.0. Defaults to 1.0.
    public convenience init(hex: Int, alpha: CGFloat = 1.0) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0
        
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
