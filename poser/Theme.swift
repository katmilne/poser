import SwiftUI

enum Theme {
    enum Colors {
        static let bg = Color(hex: 0xF6FAFE)
        static let bgDeep = Color(hex: 0xE3EDF9)
        static let cream = Color(hex: 0xFFFDF9)
        static let linen = Color(hex: 0xF3EFE6)
        static let cloud = Color.white
        static let mist = Color(hex: 0xEAF2FB)
        static let ink = Color(hex: 0x111318)
        static let black = Color(hex: 0x090A0D)
        static let hotPink = Color(hex: 0xD9B8CF)
        static let tangerine = Color(hex: 0xD8BD91)
        static let lime = Color(hex: 0xE5EAD8)
        static let sky = Color(hex: 0xD7E8F6)
        static let cyan = Color(hex: 0xDCEEEE)
        static let lemon = Color(hex: 0xF4EACF)
        static let grape = Color(hex: 0xDFDDF0)
        static let electricBlue = Color(hex: 0x7C9CB9)
        static let denim = Color(hex: 0x65798D)
        static let recRed = Color(hex: 0xDF6B68)
        static let textDim = Color(hex: 0x111318).opacity(0.50)
        static let disabled = Color(hex: 0x111318).opacity(0.24)
        static let outline = Color(hex: 0x111318).opacity(0.12)
        static let glassSelected = Color(hex: 0xDBE9F8).opacity(0.34)
        static let glassSelectedStrong = Color(hex: 0x7C9CB9).opacity(0.32)
        static let glassSelectedEdge = Color.white.opacity(0.95)
        static let glassEdge = Color.white.opacity(0.72)
        static let glassFallback = Color.white.opacity(0.76)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let sm: CGFloat = 14
        static let md: CGFloat = 20
        static let lg: CGFloat = 30
        static let pill: CGFloat = 999
    }

    static let viewportAspect: CGFloat = 3 / 4
    static let stickerShadow = Color(red: 44 / 255, green: 61 / 255, blue: 78 / 255).opacity(0.08)
    static let charmShadow = Color(red: 44 / 255, green: 61 / 255, blue: 78 / 255).opacity(0.07)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

extension Animation {
    static let poserGlide = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)
    static let poserSettle = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 0.28)
}
