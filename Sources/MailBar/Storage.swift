import Foundation
import Security

/// Mật khẩu ứng dụng trong Keychain.
/// Mỗi lần đọc Keychain, macOS có thể hiện hộp thoại xin quyền (nhất là khi app được build lại, vì chữ ký
/// ad-hoc thay đổi). Vì vậy mật khẩu chỉ đọc MỘT lần mỗi phiên rồi giữ trong bộ nhớ; nếu người dùng
/// bấm Deny thì không hỏi lại cho tới khi lưu lại mật khẩu hoặc mở lại app.
@MainActor
enum Keychain {
    private static let service = "com.phudigital.MailBar"
    private static var cache: [UUID: String] = [:]
    private static var denied: Set<UUID> = []
    /// Tài khoản đã đổi quyền mục Keychain sang "mọi app được đọc" (xem `openAccess`).
    private static let openedKey = "keychainOpenACL.v1"

    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    static func password(for id: UUID) -> String? {
        if let cached = cache[id] { return cached }
        if denied.contains(id) { return nil }

        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) {
            cache[id] = password
            openUpAccessIfNeeded(id)
            return password
        }
        // Chỉ coi là "Deny" khi người dùng từ chối/xác thực hỏng; lỗi khác (keychain đang khoá, lỗi tạm) thì lần sau thử lại.
        if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            denied.insert(id)
        }
        return nil
    }

    /// true nếu người dùng đã từ chối quyền đọc Keychain trong phiên này.
    static func isDenied(_ id: UUID) -> Bool { denied.contains(id) }

    /// `false` nếu Keychain từ chối ghi (khi đó mật khẩu KHÔNG được lưu, caller nên báo lỗi).
    @discardableResult
    static func setPassword(_ password: String, for id: UUID) -> Bool {
        // Xoá rồi thêm mới để bản app hiện tại trở thành "chủ" của mục Keychain (không bị hỏi quyền khi đọc).
        SecItemDelete(query(id) as CFDictionary)
        var q = query(id)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrLabel as String] = "MailBar"
        if let access = openAccess() { q[kSecAttrAccess as String] = access }
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { return false }
        cache[id] = password
        denied.remove(id)
        markOpened(id)
        return true
    }

    // MARK: - Quyền truy cập mục Keychain
    // ACL mặc định của Keychain chỉ cho đúng app đã tạo mục đọc, và nhận diện app bằng chữ ký. Mỗi bản build mới
    // (nhất là bản ký ad-hoc hoặc chứng chỉ khác) bị coi là app lạ → hỏi mật khẩu đăng nhập lại. Mật khẩu ở đây là
    // mật khẩu ứng dụng (phạm vi hẹp, thu hồi được) nên mục được tạo với ACL mở: không hỏi nữa, đổi lại mọi app
    // chạy dưới tài khoản người dùng đều đọc được mà không cần hỏi. Người dùng đã chọn đánh đổi này.

    private static func isOpened(_ id: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: openedKey) ?? []).contains(id.uuidString)
    }

    private static func markOpened(_ id: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: openedKey) ?? []
        if !ids.contains(id.uuidString) { ids.append(id.uuidString) }
        UserDefaults.standard.set(ids, forKey: openedKey)
    }

    /// Đổi ACL của mục cũ (tạo trước khi có ACL mở) tại chỗ, không xoá mục nên không có rủi ro mất mật khẩu.
    private static func openUpAccessIfNeeded(_ id: UUID) {
        guard !isOpened(id) else { return }
        var q = query(id)
        q[kSecReturnRef as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let item = result else { return }
        let ref = item as! SecKeychainItem
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(ref, &access) == errSecSuccess, let access else { return }
        allowAnyApp(access)
        if SecKeychainItemSetAccess(ref, access) == errSecSuccess { markOpened(id) }
    }

    /// ACL mới (cho mục mới tạo) với quyền đọc mở cho mọi app.
    private static func openAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("MailBar" as CFString, nil, &access) == errSecSuccess, let access else { return nil }
        allowAnyApp(access)
        return access
    }

    /// Với mọi ACL cho phép giải mã (đọc mật khẩu): danh sách app = NULL ("mọi app"), không hiện hộp thoại.
    /// Lưu ý: `SecAccessCreate(…, [])` KHÔNG làm được việc này (cho ra ACL không tin app nào).
    private static func allowAnyApp(_ access: SecAccess) {
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess else { return }
        for acl in (list as? [SecACL]) ?? [] {
            let auths = SecACLCopyAuthorizations(acl) as? [String] ?? []
            guard auths.contains(where: { $0.contains("Decrypt") }) else { continue }
            var apps: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &description, &selector) == errSecSuccess else { continue }
            SecACLSetContents(acl, nil, description ?? "MailBar" as CFString, SecKeychainPromptSelector(rawValue: 0))
        }
    }

    static func deletePassword(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
        cache[id] = nil
        denied.remove(id)
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: openedKey) ?? []).filter { $0 != id.uuidString },
                                  forKey: openedKey)
    }
}

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    private let key = "accounts.v1"
    @Published private(set) var accounts: [MailAccount] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([MailAccount].self, from: data) {
            accounts = decoded
        }
    }

    func upsert(_ account: MailAccount) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        save()
    }

    func remove(id: UUID) {
        accounts.removeAll { $0.id == id }
        Keychain.deletePassword(for: id)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Chế độ demo: dùng danh sách tài khoản tạm, không ghi vào UserDefaults.
    private var isTemporary = false

    func useTemporary(_ accounts: [MailAccount]) {
        isTemporary = true
        self.accounts = accounts
    }

    private func save() {
        guard !isTemporary else { return }
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum Prefs {
    static let checkInterval = "checkInterval"        // giây
    static let notificationsEnabled = "notificationsEnabled"
    static let notificationSound = "notificationSound"
    static let showCount = "showCount"
    static let markReadOnOpen = "markReadOnOpen"
    static let preferPlainText = "preferPlainText"
    static let prefetchMessages = "prefetchMessages"
    static let smartActions = "smartActions"          // nhận diện mã xác minh / link xác minh trong trình đọc
    static let autoCheckUpdates = "autoCheckUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"            // Date
    static let notifiedUpdateVersion = "notifiedUpdateVersion"  // phiên bản đã báo bằng thông báo

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            checkInterval: 120.0,
            notificationsEnabled: true,
            notificationSound: true,
            showCount: true,
            markReadOnOpen: true,
            preferPlainText: true,
            prefetchMessages: true,
            smartActions: true,
            autoCheckUpdates: true,
        ])
    }
}
