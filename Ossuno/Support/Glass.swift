import SwiftUI

enum Motion {
    static var settle: Animation { .spring(duration: 0.35, bounce: 0) }

    /// Critically damped settle used for chrome that should feel like Finder:
    /// no overshoot, interruptible, and short enough to stay out of the way.
    static var chrome: Animation { .spring(duration: 0.32, bounce: 0) }

    static func run(_ reduceMotion: Bool, _ body: () -> Void) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, body)
        } else {
            withAnimation(settle, body)
        }
    }
}

/// Shared metrics for the detail-column path bar and transfer status bar.
/// Finder keeps both strips in the content column so the sidebar material
/// runs uninterrupted to the window bottom.
enum FinderChrome {
    static let barHeight: CGFloat = 24
}

enum TransferTrayStatus {
    static func title(activeCount: Int, totalCount: Int) -> String {
        if activeCount > 0 { return "正在传输 \(activeCount) 项" }
        return totalCount > 0 ? "传输 · \(totalCount) 项" : "传输"
    }
}

extension View {
    @ViewBuilder
    func ossunoGlass(in shape: some Shape = RoundedRectangle(cornerRadius: 16, style: .continuous)) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}
