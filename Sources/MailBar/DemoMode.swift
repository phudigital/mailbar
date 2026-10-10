import AppKit
import SwiftUI

/// Chế độ demo để xem trước giao diện với nhiều tài khoản/thư mà không cần mạng hay mật khẩu.
///   open build/MailBar.app --args --demo                     → chạy app với dữ liệu giả (không lưu gì)
///   build/MailBar.app/Contents/MacOS/MailBar --demo --snapshot /tmp/menu.png
///                                                            → chụp bảng menubar ra PNG rồi thoát
///   … --demo --snapshot-about /tmp/about.png                → chụp tab Giới thiệu
@MainActor
enum DemoMode {
    /// Trả về true nếu đang ở chế độ demo (khi đó không khởi động kiểm tra thư thật).
    static func handleLaunchArguments() -> Bool {
        let args = CommandLine.arguments
        guard args.contains("--demo") else { return false }

        let accountCount = value(after: "--accounts", in: args).flatMap(Int.init) ?? 4
        let perAccount = value(after: "--messages", in: args).flatMap(Int.init) ?? 12
        install(accounts: accountCount, messagesPerAccount: perAccount)

        if let path = value(after: "--snapshot", in: args) {
            snapshot(MenuContentView(), to: path)
        } else if let path = value(after: "--snapshot-about", in: args) {
            snapshot(AboutView().frame(width: 640, height: 900), to: path)
        }
        return true
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func install(accounts count: Int, messagesPerAccount: Int) {
        let providers: [MailProvider] = [.gmail, .lark, .yandex, .feishu, .custom]
        let senders = ["Nguyễn Văn An", "Support 360VR", "Google", "Trần Thị Bình", "Lark Team",
                       "Yandex", "Phòng Kế toán", "GitHub", "Lê Minh", "Khách hàng ABC"]
        let subjects = ["Báo cáo doanh thu tháng 10", "Xác nhận đơn hàng #20391", "Lịch họp tuần tới",
                        "Cảnh báo bảo mật: đăng nhập mới", "Hợp đồng dịch vụ – bản cuối",
                        "Re: Báo giá thiết kế website", "Thông báo nghỉ lễ", "Hoá đơn điện tử tháng 9",
                        "[GitHub] New pull request", "Cập nhật tiến độ dự án tour 360"]

        var accounts: [MailAccount] = []
        var statuses: [UUID: MailChecker.Status] = [:]
        for i in 0..<count {
            var account = MailAccount()
            account.apply(provider: providers[i % providers.count])
            account.email = "demo\(i + 1)@example.com"
            account.name = i == 0 ? "" : "Tài khoản \(i + 1)"
            accounts.append(account)

            var messages: [MailMessage] = []
            for j in 0..<messagesPerAccount {
                let subject: String = subjects[(i + j) % subjects.count]
                let sender: String = senders[(i * 3 + j) % senders.count]
                let date = Date().addingTimeInterval(TimeInterval(-j * 3600))
                messages.append(MailMessage(uid: UInt32(1000 - j), subject: subject, from: sender,
                                            fromAddress: "sender\(j)@example.com", date: date, messageID: nil))
            }
            var status = MailChecker.Status()
            // Tài khoản thứ 2 bật kiểm tra Spam, có 3 thư spam.
            if i == 1 {
                account.checkSpam = true
                accounts[accounts.count - 1] = account
                for j in 0..<3 {
                    messages.append(MailMessage(uid: UInt32(500 - j), subject: "Bạn đã trúng thưởng iPhone \(17 + j)!",
                                                from: "Khuyến mãi \(j + 1)", fromAddress: "promo@spam.example",
                                                date: Date().addingTimeInterval(TimeInterval(-j * 7200)),
                                                messageID: nil, mailbox: "[Gmail]/Spam", isSpam: true))
                }
                status.spamUnread = 3
            }
            status.unreadKeys = Set(messages.map(\.key))
            status.messages = messages
            status.lastChecked = Date()
            statuses[account.id] = status
        }
        AccountStore.shared.useTemporary(accounts)
        MailChecker.shared.showDemo(statuses)
    }

    private static func snapshot<V: View>(_ content: V, to path: String) {
        let view = content
            .environmentObject(AccountStore.shared)
            .environmentObject(MailChecker.shared)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()

        // Chờ vài vòng layout để PreferenceKey đo xong chiều cao nội dung.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            window.setContentSize(hosting.fittingSize)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                hosting.layoutSubtreeIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                let screen = NSScreen.main?.visibleFrame.height ?? 0
                print("snapshot \(Int(hosting.bounds.width))x\(Int(hosting.bounds.height)) (màn hình khả dụng cao \(Int(screen)))")
                NSApp.terminate(nil)
            }
        }
    }
}
