import AppKit
import SwiftUI

/// 外观：浅色、深色、跟随系统
enum Appearance: String, CaseIterable {
    case light, dark, system

    var title: String {
        switch self {
        case .light: "浅色"
        case .dark: "深色"
        case .system: "跟随系统"
        }
    }

    static var current: Appearance {
        get { Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .light }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "appearance")
            newValue.apply()
        }
    }

    func apply() {
        NSApp.appearance = switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}

enum Theme {
    static let accent = dynamic(0x4058D6, 0x8AA4FF)
    static let heart = dynamic(0xE0426B, 0xFF7A93)
    static let sheet = dynamic(0xFFFFFF, 0x15181E)
    static let coverFill = dynamic(0xDFE5F0, 0x2A3042)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light) })
    }

    private nonisolated static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    return "\(s / 60):\(s % 60 < 10 ? "0" : "")\(s % 60)"
}
