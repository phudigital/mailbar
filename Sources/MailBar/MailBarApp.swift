import AppKit
import SwiftUI

@main
struct MailBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var checker = MailChecker.shared
    @AppStorage(Prefs.showCount) private var showCount = true

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(AccountStore.shared)
                .environmentObject(MailChecker.shared)
                .environmentObject(Updater.shared)
        } label: {
            Image(nsImage: MenuBarIcon.image(count: showCount ? checker.totalUnread : 0,
                                             hasUnread: checker.totalUnread > 0))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        Notifier.shared.setup()
        MainActor.assumeIsolated {
            if DemoMode.handleLaunchArguments() { return }
            if CommandLine.arguments.contains("--update-selftest") {
                // Chỉ để kiểm thử cập nhật: không đụng tới tài khoản/Keychain, tự kiểm tra và cài bản mới rồi thoát.
                Task {
                    await Updater.shared.check()
                    print("update-selftest:", Updater.shared.state)
                    if Updater.shared.available != nil { await Updater.shared.install() }
                    print("update-selftest (không cài được):", Updater.shared.state)
                    NSApp.terminate(nil)
                }
                return
            }
            MailChecker.shared.start()
            Updater.shared.start()
            if AccountStore.shared.accounts.isEmpty {
                SettingsWindowController.shared.show()
            }
        }
    }
}

/// Vẽ icon menubar: phong bì + badge số nhỏ ở góc dưới bên phải.
/// Là ảnh template nên tự đổi màu theo menubar sáng/tối; chữ số được "khoét" trong badge.
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    /// Được gọi mỗi khi `MailChecker` phát thay đổi; ảnh được cache để không vẽ lại.
    static func image(count: Int, hasUnread: Bool) -> NSImage {
        let key = "\(count)|\(hasUnread)"
        if let cached = cache[key] { return cached }
        if cache.count > 64 { cache.removeAll() }
        let image = render(count: count, hasUnread: hasUnread)
        cache[key] = image
        return image
    }

    private static func render(count: Int, hasUnread: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let symbolName = (hasUnread && count == 0) ? "envelope.badge" : "envelope"
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MailBar")?
            .withSymbolConfiguration(config) ?? NSImage()
        let symbolSize = symbol.size

        let text = count > 99 ? "99+" : "\(count)"
        let font = NSFont.systemFont(ofSize: 8.5, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let badgeHeight: CGFloat = 10
        let badgeWidth = max(badgeHeight, ceil(textSize.width) + 4)

        let height: CGFloat = 18
        // Badge đè lên góc dưới-phải phong bì, chỉ nhô ra 1pt để icon gọn nhất có thể.
        let width = count > 0 ? max(symbolSize.width + 1, badgeWidth + 6) : symbolSize.width

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            // Phong bì sát mép trên-trái.
            symbol.draw(in: NSRect(x: 0, y: height - symbolSize.height - 1,
                                   width: symbolSize.width, height: symbolSize.height))
            guard count > 0, let ctx = NSGraphicsContext.current?.cgContext else { return true }

            let badge = NSRect(x: ceil(width) - badgeWidth, y: 0, width: badgeWidth, height: badgeHeight)
            // Khoét viền quanh badge để tách khỏi nét phong bì.
            ctx.setBlendMode(.clear)
            NSBezierPath(roundedRect: badge.insetBy(dx: -1.5, dy: -1.5),
                         xRadius: (badgeHeight + 3) / 2, yRadius: (badgeHeight + 3) / 2).fill()
            ctx.setBlendMode(.normal)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: badge, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()
            // Chữ số trong suốt.
            ctx.setBlendMode(.destinationOut)
            (text as NSString).draw(at: NSPoint(x: badge.midX - textSize.width / 2,
                                                y: badge.midY - textSize.height / 2 + 0.5),
                                    withAttributes: attrs)
            ctx.setBlendMode(.normal)
            return true
        }
        image.isTemplate = true
        return image
    }
}
