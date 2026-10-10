import Foundation
import SwiftUI

enum MailProvider: String, Codable, CaseIterable, Identifiable {
    case gmail, lark, feishu, yandex, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gmail: return "Gmail / Google Workspace"
        case .lark: return "Lark Mail"
        case .feishu: return "Feishu Mail"
        case .yandex: return "Yandex Mail"
        case .custom: return "IMAP khác"
        }
    }

    var defaultHost: String {
        switch self {
        case .gmail: return "imap.gmail.com"
        case .lark: return "imap.larksuite.com"
        case .feishu: return "imap.feishu.cn"
        case .yandex: return "imap.yandex.com"
        case .custom: return ""
        }
    }

    var defaultPort: Int { 993 }

    /// `{email}` được thay bằng địa chỉ email khi mở.
    var defaultWebURL: String {
        switch self {
        case .gmail: return "https://mail.google.com/mail/u/?authuser={email}"
        case .lark: return "https://www.larksuite.com/mail"
        case .feishu: return "https://www.feishu.cn/mail"
        case .yandex: return "https://mail.yandex.com"
        case .custom: return ""
        }
    }

    var helpText: String {
        switch self {
        case .gmail:
            return "Bật Xác minh 2 bước cho tài khoản Google, sau đó tạo Mật khẩu ứng dụng (16 ký tự) tại myaccount.google.com/apppasswords. Với Google Workspace, quản trị viên cần cho phép IMAP."
        case .lark:
            return "Trên app Lark desktop (không làm được trên mobile/web): Ảnh đại diện → Settings → Email → Third-party email client login → Set Up Now → chọn thiết bị → Generate để lấy mật khẩu riêng. Quản trị viên phải cho phép dùng ứng dụng thư bên thứ ba thì mới có mục này."
        case .feishu:
            return "Trong Feishu Mail: Settings → Third-party client → bật IMAP và tạo mật khẩu ứng dụng."
        case .yandex:
            return "Bật IMAP tại Cài đặt → Ứng dụng thư (Email clients), sau đó tạo Mật khẩu ứng dụng loại \"Mail\" tại id.yandex.com/security/app-passwords."
        case .custom:
            return "Nhập máy chủ IMAP của nhà cung cấp (thường cổng 993, SSL/TLS)."
        }
    }

    var symbol: String {
        switch self {
        case .gmail: return "g.circle.fill"
        case .lark: return "l.circle.fill"
        case .feishu: return "f.circle.fill"
        case .yandex: return "y.circle.fill"
        case .custom: return "envelope.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .gmail: return .red
        case .lark: return .blue
        case .feishu: return .teal
        case .yandex: return .orange
        case .custom: return .gray
        }
    }
}

struct MailAccount: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = ""
    var provider: MailProvider = .gmail
    var email: String = ""
    var username: String = ""
    var host: String = MailProvider.gmail.defaultHost
    var port: Int = 993
    var useTLS: Bool = true
    var mailbox: String = "INBOX"
    var webURL: String = MailProvider.gmail.defaultWebURL
    var enabled: Bool = true
    /// Kiểm tra thêm thư mục Spam/Junk.
    var checkSpam: Bool = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, email, username, host, port, useTLS, mailbox, webURL, enabled, checkSpam
    }

    /// Mọi trường đều `decodeIfPresent`: dữ liệu lưu từ phiên bản cũ (thiếu trường mới) vẫn đọc được.
    /// KHI THÊM TRƯỜNG MỚI: thêm vào CodingKeys và thêm một dòng decodeIfPresent ở đây.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MailAccount()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        provider = (try? c.decodeIfPresent(MailProvider.self, forKey: .provider)) ?? .custom
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? d.email
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? d.username
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        useTLS = try c.decodeIfPresent(Bool.self, forKey: .useTLS) ?? d.useTLS
        mailbox = try c.decodeIfPresent(String.self, forKey: .mailbox) ?? d.mailbox
        webURL = try c.decodeIfPresent(String.self, forKey: .webURL) ?? d.webURL
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        checkSpam = try c.decodeIfPresent(Bool.self, forKey: .checkSpam) ?? d.checkSpam
    }

    var displayName: String { name.isEmpty ? (email.isEmpty ? "Tài khoản mới" : email) : name }
    var loginUser: String { username.isEmpty ? email : username }
    var mailboxName: String { mailbox.isEmpty ? "INBOX" : mailbox }

    mutating func apply(provider newProvider: MailProvider) {
        provider = newProvider
        host = newProvider.defaultHost
        port = newProvider.defaultPort
        useTLS = true
        webURL = newProvider.defaultWebURL
    }

    func webURL(for message: MailMessage? = nil) -> URL? {
        let emailEncoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
        var base = webURL.replacingOccurrences(of: "{email}", with: emailEncoded)
        if base.isEmpty { return nil }
        if !base.contains("://") { base = "https://" + base }

        // Gmail hỗ trợ mở thẳng một thư theo Message-ID (thư Spam cần thêm "in:anywhere").
        if let message, let mid = message.messageID, base.contains("mail.google.com") {
            var allowed = CharacterSet.urlFragmentAllowed
            allowed.remove(charactersIn: "#+&")
            let search = (message.isSpam ? "in:anywhere " : "") + "rfc822msgid:" + mid
            let query = search.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let root = base.components(separatedBy: "#").first ?? base
            return URL(string: root + "#search/" + query)
        }
        return URL(string: base)
    }
}

/// UID chỉ duy nhất trong một thư mục, nên thư được định danh bằng (thư mục, UID).
struct MessageKey: Hashable {
    let mailbox: String
    let uid: UInt32
}

struct MailMessage: Identifiable, Hashable {
    let uid: UInt32
    let subject: String
    let from: String
    let fromAddress: String?
    let date: Date?
    let messageID: String?
    /// Tên thư mục trên máy chủ (vd. "INBOX", "[Gmail]/Spam").
    var mailbox: String = "INBOX"
    var isSpam: Bool = false

    var key: MessageKey { MessageKey(mailbox: mailbox, uid: uid) }
    var id: MessageKey { key }
}
