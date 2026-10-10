import Foundation

/// Cache tạm nội dung thư (bản RFC 822 thô) để mở xem là có ngay, không phải chờ tải.
/// Lưu ở `~/Library/Caches/com.phudigital.MailBar/Messages/<id tài khoản>/<thư mục>_<uid>.eml`.
/// Chỉ giữ thư đang chưa đọc: mỗi lần kiểm tra, file của thư đã đọc/xoá được dọn đi.
/// Không phụ thuộc UI/AppKit để còn biên dịch được trong harness kiểm thử.
enum MessageCache {
    private static let fm = FileManager.default

    private static var root: URL {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundle = Bundle.main.bundleIdentifier ?? "com.phudigital.MailBar"
        return base.appendingPathComponent(bundle).appendingPathComponent("Messages")
    }

    private static func directory(_ account: UUID) -> URL {
        root.appendingPathComponent(account.uuidString)
    }

    /// Tên file: băm tên thư mục (có thể chứa ký tự lạ như `[Gmail]/Spam`) + UID.
    private static func fileName(_ key: MessageKey) -> String {
        var hash: UInt64 = 0xcbf29ce484222325   // FNV-1a
        for byte in key.mailbox.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "%016llx_%u.eml", hash, key.uid)
    }

    static func contains(_ account: UUID, _ key: MessageKey) -> Bool {
        fm.fileExists(atPath: directory(account).appendingPathComponent(fileName(key)).path)
    }

    static func read(_ account: UUID, _ key: MessageKey) -> Data? {
        try? Data(contentsOf: directory(account).appendingPathComponent(fileName(key)))
    }

    static func write(_ data: Data, account: UUID, key: MessageKey) {
        let dir = directory(account)
        do {
            // Thư mục chỉ chủ tài khoản đọc được (nội dung thư là riêng tư).
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let url = dir.appendingPathComponent(fileName(key))
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Cache chỉ là tối ưu: ghi lỗi thì bỏ qua, lần mở sau sẽ tải trực tiếp.
        }
    }

    static func remove(_ account: UUID, _ key: MessageKey) {
        try? fm.removeItem(at: directory(account).appendingPathComponent(fileName(key)))
    }

    /// Xoá file của những thư không còn trong `keep` (đã đọc, đã xoá…).
    static func prune(_ account: UUID, keep: Set<MessageKey>) {
        let dir = directory(account)
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let wanted = Set(keep.map(fileName))
        for file in files where !wanted.contains(file) {
            try? fm.removeItem(at: dir.appendingPathComponent(file))
        }
    }

    /// Xoá cache của một tài khoản.
    static func removeAccount(_ account: UUID) {
        try? fm.removeItem(at: directory(account))
    }

    /// Xoá cache của mọi tài khoản không nằm trong `active` (đã xoá/tắt, hoặc còn sót từ phiên cũ).
    static func removeAll(except active: Set<UUID> = []) {
        guard let dirs = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in dirs where UUID(uuidString: name).map({ !active.contains($0) }) ?? true {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
    }
}
