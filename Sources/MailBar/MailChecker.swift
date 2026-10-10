import AppKit
import Combine

@MainActor
final class MailChecker: ObservableObject {
    static let shared = MailChecker()

    struct Status {
        /// Thư chưa đọc (Hộp thư đến + Spam nếu bật), định danh bằng (thư mục, UID).
        var unreadKeys: Set<MessageKey> = []
        /// Thư chưa đọc mới nhất (đã tải header): Hộp thư đến trước, rồi Spam.
        var messages: [MailMessage] = []
        /// Số thư chưa đọc trong thư mục Spam.
        var spamUnread = 0
        var spamNote: String?
        var error: String?
        var lastChecked: Date?
        var isChecking = false

        var unread: Int { unreadKeys.count }
    }

    @Published private(set) var statuses: [UUID: Status] = [:]
    @Published private(set) var isChecking = false

    private let store = AccountStore.shared
    /// Thư chưa đọc đã biết theo tài khoản — dùng để phát hiện thư mới. `nil` = chưa kiểm tra lần nào.
    private var knownKeys: [UUID: Set<MessageKey>] = [:]
    /// Header đã tải — mỗi chu kỳ chỉ tải header của thư mới, không tải lại 50–70 header.
    private var headerCache: [UUID: [MessageKey: MailMessage]] = [:]
    /// Tài khoản đang tải sẵn nội dung thư (mỗi tài khoản một lượt tại một thời điểm).
    private var prefetching: Set<UUID> = []
    /// Thế hệ cấu hình của tài khoản: `reset`/xoá/tắt tăng lên, nên `check` đang chạy dở với cấu hình cũ tự bỏ kết quả.
    private var epoch: [UUID: Int] = [:]
    /// Lần thử lại liên tiếp sau lỗi mạng tạm thời (vd. Wi-Fi chưa lên lại sau khi máy thức dậy).
    private var retries: [UUID: Int] = [:]
    private static let retryDelays: [UInt64] = [15, 45]
    /// Message-ID của thư vừa "Không phải spam": về Hộp thư đến với UID mới nên không được báo như thư mới.
    private var movedBack: Set<String> = []
    /// Số thư tải sẵn tối đa mỗi lượt cho một tài khoản (mới nhất trước) — tránh tải cả loạt thư cũ ở lần mở app đầu.
    private static let prefetchLimit = 20
    private var timer: Timer?
    /// Màn hình đang tắt: bỏ qua kiểm tra định kỳ (thông báo lúc đó vô ích), kiểm tra ngay khi bật lại.
    private var screenAsleep = false
    private var cancellables = Set<AnyCancellable>()

    var totalUnread: Int {
        store.accounts.filter(\.enabled).reduce(0) { $0 + (statuses[$1.id]?.unread ?? 0) }
    }

    func start() {
        scheduleTimer()
        checkAll()

        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.didWakeNotification)
            .delay(for: .seconds(8), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.checkAll() }
            .store(in: &cancellables)
        center.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in self?.screenAsleep = true }
            .store(in: &cancellables)
        center.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in
                self?.screenAsleep = false
                self?.checkAll()
            }
            .store(in: &cancellables)

        // Dọn trạng thái của tài khoản đã xoá / bị tắt.
        store.$accounts
            .sink { [weak self] accounts in
                guard let self else { return }
                let active = Set(accounts.filter(\.enabled).map(\.id))
                self.statuses = self.statuses.filter { active.contains($0.key) }
                self.knownKeys = self.knownKeys.filter { active.contains($0.key) }
                self.headerCache = self.headerCache.filter { active.contains($0.key) }
                for id in self.epoch.keys where !active.contains(id) { self.epoch[id, default: 0] += 1 }
                self.retries = self.retries.filter { active.contains($0.key) }
                Task.detached { MessageCache.removeAll(except: active) }
            }
            .store(in: &cancellables)
    }

    /// Chế độ demo: hiển thị trạng thái giả, không kết nối mạng, không hẹn giờ.
    func showDemo(_ demo: [UUID: Status]) {
        timer?.invalidate()
        statuses = demo
    }

    func scheduleTimer() {
        timer?.invalidate()
        let interval = max(60, UserDefaults.standard.double(forKey: Prefs.checkInterval))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAll() }
        }
        // Cho phép macOS gộp lần đánh thức với timer khác → tiết kiệm pin.
        timer?.tolerance = interval * 0.1
    }

    func checkAll() {
        guard !isChecking, !screenAsleep else { return }
        let accounts = store.accounts.filter(\.enabled)
        guard !accounts.isEmpty else { return }
        isChecking = true
        Task {
            await withTaskGroup(of: Void.self) { group in
                for account in accounts {
                    group.addTask { await self.check(account) }
                }
            }
            isChecking = false
        }
    }

    /// Gọi khi cấu hình tài khoản thay đổi: quên trạng thái cũ rồi kiểm tra lại.
    func reset(_ account: MailAccount) {
        statuses[account.id] = nil
        knownKeys[account.id] = nil
        headerCache[account.id] = nil
        epoch[account.id, default: 0] += 1
        retries[account.id] = nil
        let id = account.id
        Task.detached { MessageCache.removeAccount(id) }
        if account.enabled { Task { await check(account) } }
    }

    func check(_ account: MailAccount) async {
        if statuses[account.id]?.isChecking == true { return }
        statuses[account.id, default: Status()].isChecking = true
        let myEpoch = epoch[account.id, default: 0]

        let password = Keychain.password(for: account.id) ?? ""
        if password.isEmpty && Keychain.isDenied(account.id) {
            var status = statuses[account.id] ?? Status()
            status.error = "Không có quyền đọc mật khẩu trong Keychain. Mở Cài đặt và bấm Lưu lại tài khoản, hoặc mở lại app và chọn \"Always Allow\"."
            status.isChecking = false
            statuses[account.id] = status
            return
        }
        do {
            let cached = headerCache[account.id] ?? [:]
            let snapshot = try await IMAPService.fetchUnread(account: account, password: password,
                                                             knownHeaders: Set(cached.keys))
            // Tài khoản có thể đã bị xoá/sửa trong lúc đang kiểm tra.
            guard store.accounts.contains(where: { $0.id == account.id && $0.enabled }),
                  epoch[account.id, default: 0] == myEpoch else { return }
            retries[account.id] = nil

            // Gộp header vừa tải với cache; bỏ thư không còn chưa đọc.
            var cache = cached.filter { snapshot.unread.contains($0.key) }
            for message in snapshot.fetched { cache[message.key] = message }
            headerCache[account.id] = cache
            let messages = snapshot.display.compactMap { cache[$0] }

            if let known = knownKeys[account.id] {
                // Chỉ thông báo thư mới trong Hộp thư đến (không thông báo Spam).
                let newKeys = snapshot.unread.subtracting(known).filter { $0.mailbox == account.mailboxName }
                let fresh = messages.filter { newKeys.contains($0.key) }
                // Bỏ thư vừa chuyển về từ Spam (xem `movedBack`).
                let toAnnounce = fresh.filter { m in
                    guard let id = m.messageID else { return true }
                    return movedBack.remove(id) == nil
                }
                let count = newKeys.count - (fresh.count - toAnnounce.count)
                if count > 0 {
                    announce(account: account, newMessages: toAnnounce, count: count)
                }
                let merged = known.union(snapshot.unread)
                // Giữ tập này có giới hạn: quá lớn thì chỉ giữ các thư đang chưa đọc.
                knownKeys[account.id] = merged.count > 5000 ? snapshot.unread : merged
            } else {
                knownKeys[account.id] = snapshot.unread
            }

            statuses[account.id] = Status(unreadKeys: snapshot.unread,
                                          messages: messages,
                                          spamUnread: snapshot.unread.filter { $0.mailbox != account.mailboxName }.count,
                                          spamNote: snapshot.spamNote,
                                          error: nil,
                                          lastChecked: Date(),
                                          isChecking: false)

            // Dọn cache của thư đã đọc/xoá, rồi tải sẵn nội dung thư mới để mở xem là có ngay.
            let accountID = account.id
            let unread = snapshot.unread
            Task.detached { MessageCache.prune(accountID, keep: unread) }
            prefetch(account, password: password, messages: messages)
        } catch {
            guard store.accounts.contains(where: { $0.id == account.id }),
                  epoch[account.id, default: 0] == myEpoch else { return }
            var status = statuses[account.id] ?? Status()
            if scheduleRetry(account, after: error) {
                // Lỗi mạng tạm thời: chưa báo lỗi, thử lại sớm thay vì đợi hết chu kỳ.
                status.isChecking = false
                statuses[account.id] = status
                return
            }
            status.error = error.localizedDescription
            status.isChecking = false
            status.lastChecked = Date()
            statuses[account.id] = status
        }
    }

    /// Lỗi kết nối/hết giờ thường chỉ là tạm thời: thử lại sau 15 giây, 45 giây rồi mới báo lỗi.
    private func scheduleRetry(_ account: MailAccount, after error: Error) -> Bool {
        guard let imap = error as? IMAPError else { return false }
        switch imap {
        case .connectionFailed, .timeout, .closed: break
        default: return false
        }
        let attempt = retries[account.id, default: 0]
        guard attempt < Self.retryDelays.count else { return false }
        retries[account.id] = attempt + 1
        let delay = Self.retryDelays[attempt]
        let expected = epoch[account.id, default: 0]
        Task {
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !screenAsleep, epoch[account.id, default: 0] == expected,
                  let current = store.accounts.first(where: { $0.id == account.id && $0.enabled }) else { return }
            await check(current)
        }
        return true
    }

    // MARK: - Thao tác

    func markRead(_ account: MailAccount, messages: [MailMessage]) {
        markRead(account, keys: Set(messages.map(\.key)))
    }

    func markAllRead(_ account: MailAccount) {
        markRead(account, keys: statuses[account.id]?.unreadKeys ?? [])
    }

    private func markRead(_ account: MailAccount, keys: Set<MessageKey>) {
        guard !keys.isEmpty else { return }
        removeLocally(account, keys: keys)
        perform(account, "đánh dấu đã đọc", keys) { pw, mailbox, uids in
            try await IMAPService.setSeen(account: account, password: pw, mailbox: mailbox, uids: uids, seen: true)
        }
    }

    func markUnread(_ account: MailAccount, message: MailMessage) {
        var status = statuses[account.id] ?? Status()
        if !status.unreadKeys.contains(message.key) {
            status.unreadKeys.insert(message.key)
            if message.isSpam { status.spamUnread += 1 }
            status.messages.append(message)
            status.messages.sort { ($0.isSpam ? 1 : 0, -Int($0.uid)) < ($1.isSpam ? 1 : 0, -Int($1.uid)) }
            statuses[account.id] = status
        }
        knownKeys[account.id, default: []].insert(message.key)
        headerCache[account.id, default: [:]][message.key] = message
        perform(account, "đánh dấu chưa đọc", [message.key]) { pw, mailbox, uids in
            try await IMAPService.setSeen(account: account, password: pw, mailbox: mailbox, uids: uids, seen: false)
        }
    }

    func moveToTrash(_ account: MailAccount, messages: [MailMessage]) {
        let keys = Set(messages.map(\.key))
        guard !keys.isEmpty else { return }
        removeLocally(account, keys: keys)
        let id = account.id
        Task.detached { keys.forEach { MessageCache.remove(id, $0) } }
        perform(account, "xoá thư", keys) { pw, mailbox, uids in
            try await IMAPService.moveToTrash(account: account, password: pw, mailbox: mailbox, uids: uids)
        }
    }

    /// "Đánh dấu spam": chuyển thư vào thư mục Spam. Nếu tài khoản bật theo dõi Spam, thư sẽ hiện ở nhóm Spam sau lần kiểm tra kế tiếp.
    func markSpam(_ account: MailAccount, messages: [MailMessage]) {
        let messages = messages.filter { !$0.isSpam }
        let keys = Set(messages.map(\.key))
        guard !keys.isEmpty else { return }
        removeLocally(account, keys: keys)
        let id = account.id
        Task.detached { keys.forEach { MessageCache.remove(id, $0) } }
        perform(account, "đánh dấu spam", keys) { pw, mailbox, uids in
            try await IMAPService.moveToSpam(account: account, password: pw, mailbox: mailbox, uids: uids)
        } then: { [weak self] in
            if account.checkSpam { await self?.check(account) }
        }
    }

    /// "Không phải spam": chuyển về Hộp thư đến. Thư sẽ xuất hiện lại ở nhóm Hộp thư đến sau lần kiểm tra kế tiếp.
    func notSpam(_ account: MailAccount, message: MailMessage) {
        guard message.isSpam else { return }
        if let id = message.messageID { movedBack.insert(id) }
        removeLocally(account, keys: [message.key])
        perform(account, "chuyển khỏi Spam", [message.key]) { pw, mailbox, uids in
            try await IMAPService.moveToInbox(account: account, password: pw, from: mailbox, uids: uids)
        } then: { [weak self] in
            await self?.check(account)
        }
    }

    func loadMessage(_ account: MailAccount, message: MailMessage) async throws -> ParsedMessage {
        // Có sẵn trong cache (đã tải khi thư về) → mở ngay, không cần mạng.
        let accountID = account.id
        let key = message.key
        let cached = await Task.detached(priority: .userInitiated) { () -> ParsedMessage? in
            MessageCache.read(accountID, key).map(MessageParser.parse)
        }.value
        if let cached {
            // UID có thể bị máy chủ cấp lại cho thư khác (UIDVALIDITY đổi): Message-ID lệch thì bỏ cache.
            if let a = cached.messageID, let b = message.messageID, a != b {
                MessageCache.remove(accountID, key)
            } else {
                return cached
            }
        }

        let password = Keychain.password(for: account.id) ?? ""
        let data = try await IMAPService.fetchMessage(account: account, password: password,
                                                      mailbox: message.mailbox, uid: message.uid)
        return await Task.detached(priority: .userInitiated) { MessageParser.parse(data) }.value
    }

    /// Tải sẵn nội dung các thư chưa có trong cache (một phiên IMAP, chỉ đọc). Lỗi thì bỏ qua: lần mở thư sẽ tải trực tiếp.
    private func prefetch(_ account: MailAccount, password: String, messages: [MailMessage]) {
        guard UserDefaults.standard.bool(forKey: Prefs.prefetchMessages),
              !password.isEmpty, !prefetching.contains(account.id) else { return }
        let accountID = account.id
        let keys = messages.map(\.key).filter { !MessageCache.contains(accountID, $0) }.prefix(Self.prefetchLimit)
        guard !keys.isEmpty else { return }
        prefetching.insert(accountID)
        let wanted = Array(keys)
        Task {
            try? await IMAPService.prefetchMessages(account: account, password: password, keys: wanted) { key, data in
                MessageCache.write(data, account: accountID, key: key)
            }
            prefetching.remove(accountID)
        }
    }

    func isUnread(_ account: MailAccount, message: MailMessage) -> Bool {
        statuses[account.id]?.unreadKeys.contains(message.key) ?? false
    }

    private func removeLocally(_ account: MailAccount, keys: Set<MessageKey>) {
        guard var status = statuses[account.id] else { return }
        let removedSpam = keys.intersection(status.unreadKeys).filter { $0.mailbox != account.mailboxName }.count
        status.unreadKeys.subtract(keys)
        status.spamUnread = max(0, status.spamUnread - removedSpam)
        status.messages.removeAll { keys.contains($0.key) }
        statuses[account.id] = status
    }

    /// Chạy thao tác trên máy chủ, mỗi thư mục một lần (UID chỉ có nghĩa trong thư mục của nó).
    /// Nếu lỗi thì tải lại trạng thái thật và hiện lỗi.
    private func perform(_ account: MailAccount, _ label: String, _ keys: Set<MessageKey>,
                         _ operation: @escaping (_ password: String, _ mailbox: String, _ uids: [UInt32]) async throws -> Void,
                         then: (() async -> Void)? = nil) {
        let password = Keychain.password(for: account.id) ?? ""
        let groups = Dictionary(grouping: keys, by: \.mailbox).mapValues { $0.map(\.uid) }
        Task {
            do {
                for (mailbox, uids) in groups {
                    try await operation(password, mailbox, uids)
                }
                await then?()
            } catch {
                await check(account)
                statuses[account.id]?.error = "Không \(label) được: \(error.localizedDescription)"
            }
        }
    }

    func open(_ account: MailAccount, message: MailMessage? = nil) {
        guard let url = account.webURL(for: message) else { return }
        NSWorkspace.shared.open(url)
    }

    private func announce(account: MailAccount, newMessages: [MailMessage], count: Int) {
        if count <= 3 && newMessages.count == count {
            for message in newMessages.reversed() {
                Notifier.shared.notify(title: message.from,
                                       subtitle: account.displayName,
                                       body: message.subject,
                                       url: account.webURL(for: message))
            }
        } else {
            let preview = newMessages.prefix(3).map { "• \($0.from): \($0.subject)" }.joined(separator: "\n")
            Notifier.shared.notify(title: "\(count) thư mới",
                                   subtitle: account.displayName,
                                   body: preview.isEmpty ? "Bấm để mở hộp thư" : preview,
                                   url: account.webURL())
        }
    }
}
