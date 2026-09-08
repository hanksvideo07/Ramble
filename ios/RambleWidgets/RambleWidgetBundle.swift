import SwiftUI
import WidgetKit

@main
struct RambleWidgetBundle: WidgetBundle {
    var body: some Widget {
        TalkWidget()
        CaptureWidget()
        RecordingLiveActivity()
    }
}

/// The palette, restated here because a widget extension is a separate target
/// and cannot see the app's Theme. Kept deliberately short: a widget needs the
/// paper, the ink, and the one green.
enum WidgetPalette {
    static let paper = Color(light: 0xFCFDF8, dark: 0x1D2C22)
    static let ink = Color(light: 0x2D4436, dark: 0xE5EFDC)
    static let secondary = Color(light: 0x6F806E, dark: 0xACBDA3)
    static let action = Color(light: 0x477B53, dark: 0xB8DCA4)
    static let onAction = Color(light: 0xF8FFF2, dark: 0x233E24)
    static let halo = Color(light: 0xE9F1E2, dark: 0x2B422E)
    static let divider = Color(light: 0xDDE6D5, dark: 0x3B503B)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

#if canImport(UIKit)
import UIKit
#endif
