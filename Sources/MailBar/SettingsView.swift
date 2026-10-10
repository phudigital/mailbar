import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    enum Tab: Hashable { case accounts, general, about }

    /// Tab đang chọn — dùng chung với `SettingsView` để có thể mở thẳng một tab.
    final class Navigation: ObservableObject {
        @Published var tab: Tab = .accounts
    }
    let navigation = Navigation()

    func show(tab: Tab? = nil) {
        if let tab { navigation.tab = tab }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView()
                .environmentObject(navigation)
                .environmentObject(AccountStore.shared)
                .environmentObject(MailChecker.shared))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Cài đặt MailBar"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 760, height: 560))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        ensureEditMenu()
        // Hiện app trên Dock khi mở cài đặt để gõ/dán mật khẩu thuận tiện.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Giải phóng cửa sổ và toàn bộ cây SwiftUI bên trong (giữ lại tốn ~30 MB RAM). Mở lại sẽ tạo mới.
        DispatchQueue.main.async { [weak self] in self?.window = nil }
    }

    /// Đảm bảo có menu Edit để ⌘C/⌘V/⌘A hoạt động trong ô nhập liệu.
    private func ensureEditMenu() {
        let mainMenu = NSApp.mainMenu ?? NSMenu()
        if NSApp.mainMenu == nil {
            let appItem = NSMenuItem()
            appItem.submenu = NSMenu()
            appItem.submenu?.addItem(withTitle: "Thoát MailBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            mainMenu.addItem(appItem)
            NSApp.mainMenu = mainMenu
        }
        let hasPaste = mainMenu.items.contains { item in
            item.submenu?.items.contains { $0.action == #selector(NSText.paste(_:)) } ?? false
        }
        guard !hasPaste else { return }
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        mainMenu.addItem(item)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var navigation: SettingsWindowController.Navigation

    var body: some View {
        TabView(selection: $navigation.tab) {
            AccountsSettingsView()
                .tabItem { Label("Tài khoản", systemImage: "person.crop.circle") }
                .tag(SettingsWindowController.Tab.accounts)
            GeneralSettingsView()
                .tabItem { Label("Chung", systemImage: "gearshape") }
                .tag(SettingsWindowController.Tab.general)
            AboutView()
                .tabItem { Label("Giới thiệu", systemImage: "info.circle") }
                .tag(SettingsWindowController.Tab.about)
        }
        .padding(12)
        .frame(minWidth: 700, minHeight: 500)
    }
}

// MARK: - Accounts

private struct AccountsSettingsView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var selection: UUID?
    @State private var newAccount: MailAccount?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.accounts) { account in
                        HStack {
                            Image(systemName: account.provider.symbol)
                                .foregroundStyle(account.provider.tint)
                            VStack(alignment: .leading) {
                                Text(account.displayName).lineLimit(1)
                                Text(account.provider.displayName).font(.caption).foregroundStyle(.secondary)
                            }
                            if !account.enabled {
                                Spacer()
                                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                            }
                        }
                        .tag(account.id)
                    }
                    .onMove { store.move(from: $0, to: $1) }
                    if let newAccount {
                        Label(newAccount.displayName, systemImage: "plus.circle")
                            .foregroundStyle(.secondary)
                            .tag(newAccount.id)
                    }
                }
                Divider()
                HStack(spacing: 2) {
                    Menu {
                        ForEach(MailProvider.allCases) { provider in
                            Button(provider.displayName) { addAccount(provider) }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28)
                    .help("Thêm tài khoản")

                    Button {
                        if let id = selection { remove(id) }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28)
                    .disabled(selection == nil)
                    .help("Xoá tài khoản")
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 220)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            Group {
                if let draft = newAccount, selection == draft.id {
                    AccountEditor(account: draft, isNew: true) { saved in
                        newAccount = nil
                        selection = saved.id
                    }
                    .id(draft.id)
                } else if let id = selection, let account = store.accounts.first(where: { $0.id == id }) {
                    AccountEditor(account: account, isNew: false) { _ in }
                        .id(account.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "envelope.open")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("Chọn một tài khoản hoặc bấm + để thêm mới")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selection == nil { selection = store.accounts.first?.id }
            if store.accounts.isEmpty { addAccount(.gmail) }
        }
        .onChange(of: selection) { value in
            // Bỏ tài khoản nháp nếu người dùng chọn sang tài khoản khác.
            if let draft = newAccount, value != draft.id { newAccount = nil }
        }
    }

    private func addAccount(_ provider: MailProvider) {
        var account = MailAccount()
        account.apply(provider: provider)
        newAccount = account
        selection = account.id
    }

    private func remove(_ id: UUID) {
        if newAccount?.id == id {
            newAccount = nil
        } else if let account = store.accounts.first(where: { $0.id == id }) {
            let alert = NSAlert()
            alert.messageText = "Xoá tài khoản \(account.displayName)?"
            alert.informativeText = "Mật khẩu đã lưu trong Keychain cũng sẽ bị xoá."
            alert.addButton(withTitle: "Xoá")
            alert.addButton(withTitle: "Huỷ")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store.remove(id: id)
        }
        selection = store.accounts.first?.id
    }
}

private struct AccountEditor: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var checker: MailChecker

    let original: MailAccount
    let isNew: Bool
    let onSaved: (MailAccount) -> Void

    @State private var draft: MailAccount
    @State private var password = ""
    @State private var loadedPassword = ""
    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle, running
        case success(String)
        case failure(String)
    }

    init(account: MailAccount, isNew: Bool, onSaved: @escaping (MailAccount) -> Void) {
        original = account
        self.isNew = isNew
        self.onSaved = onSaved
        _draft = State(initialValue: account)
    }

    private var isDirty: Bool { isNew || draft != original || password != loadedPassword }
    private var canSave: Bool {
        !draft.email.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    var body: some View {
        Form {
            Section {
                Picker("Nhà cung cấp", selection: Binding(
                    get: { draft.provider },
                    set: { draft.apply(provider: $0) }
                )) {
                    ForEach(MailProvider.allCases) { Text($0.displayName).tag($0) }
                }
                TextField("Tên hiển thị", text: $draft.name, prompt: Text("vd. Mail công ty"))
                TextField("Email", text: $draft.email, prompt: Text("ban@example.com"))
                TextField("Tên đăng nhập", text: $draft.username, prompt: Text("Để trống = dùng email"))
                SecureField("Mật khẩu ứng dụng", text: $password, prompt: Text("App password"))
                Toggle("Bật kiểm tra tài khoản này", isOn: $draft.enabled)
                Toggle(isOn: $draft.checkSpam) {
                    Text("Kiểm tra cả thư mục Spam")
                    Text("Thư spam chưa đọc hiện thành nhóm riêng và được tính vào số trên icon, nhưng không gửi thông báo.")
                }
            } footer: {
                Text(draft.provider.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Máy chủ IMAP") {
                TextField("Máy chủ", text: $draft.host, prompt: Text("imap.example.com"))
                TextField("Cổng", value: $draft.port, format: .number.grouping(.never))
                Toggle("SSL/TLS", isOn: $draft.useTLS)
                if !draft.useTLS {
                    Label("Kết nối không mã hoá: mật khẩu và thư đi dạng rõ trên mạng.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                TextField("Hộp thư", text: $draft.mailbox, prompt: Text("INBOX"))
            }

            Section {
                TextField("Địa chỉ web mail", text: $draft.webURL, prompt: Text("https://mail.example.com"))
            } header: {
                Text("Mở thư")
            } footer: {
                Text("Trang sẽ mở khi bấm vào tài khoản/thư. {email} được thay bằng địa chỉ email.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Kiểm tra kết nối") { runTest() }
                        .disabled(testState == .running || !canSave)
                    testResult
                    Spacer()
                    if !isNew {
                        Button("Hoàn tác") {
                            draft = original
                            password = loadedPassword
                            testState = .idle
                        }
                        .disabled(!isDirty)
                    }
                    Button(isNew ? "Thêm tài khoản" : "Lưu") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave || !isDirty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if !isNew {
                loadedPassword = Keychain.password(for: original.id) ?? ""
                password = loadedPassword
            }
        }
    }

    @ViewBuilder private var testResult: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(2)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private func normalized() -> MailAccount {
        var account = draft
        account.email = account.email.trimmingCharacters(in: .whitespaces)
        account.username = account.username.trimmingCharacters(in: .whitespaces)
        account.host = account.host.trimmingCharacters(in: .whitespaces)
        account.mailbox = account.mailbox.trimmingCharacters(in: .whitespaces)
        account.webURL = account.webURL.trimmingCharacters(in: .whitespaces)
        if account.mailbox.isEmpty { account.mailbox = "INBOX" }
        return account
    }

    private func runTest() {
        testState = .running
        let account = normalized()
        let pw = password
        Task {
            do {
                let snapshot = try await IMAPService.fetchUnread(account: account, password: pw, limit: 1)
                let inbox = snapshot.unread.filter { $0.mailbox == account.mailboxName }.count
                var text = "Kết nối OK – \(inbox) thư chưa đọc"
                if account.checkSpam {
                    text += snapshot.spamNote.map { " · \($0)" } ?? " · Spam: \(snapshot.unread.count - inbox)"
                }
                testState = .success(text)
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }

    private func save() {
        let account = normalized()
        guard Keychain.setPassword(password, for: account.id) else {
            testState = .failure("Keychain không cho lưu mật khẩu (có thể đang bị khoá). Mở Keychain Access, mở khoá \"login\" rồi bấm Lưu lại.")
            return
        }
        loadedPassword = password
        store.upsert(account)
        draft = account
        checker.reset(account)
        onSaved(account)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @EnvironmentObject private var checker: MailChecker
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Prefs.autoCheckUpdates) private var autoCheckUpdates = true
    @AppStorage(Prefs.checkInterval) private var interval = 120.0
    @AppStorage(Prefs.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(Prefs.notificationSound) private var notificationSound = true
    @AppStorage(Prefs.showCount) private var showCount = true
    @AppStorage(Prefs.markReadOnOpen) private var markReadOnOpen = true
    @AppStorage(Prefs.preferPlainText) private var preferPlainText = true
    @AppStorage(Prefs.prefetchMessages) private var prefetchMessages = true
    @AppStorage(Prefs.smartActions) private var smartActions = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    @ViewBuilder private var updateStatus: some View {
        switch updater.state {
        case .idle: Text("Đang dùng bản \(AppInfo.version)").foregroundStyle(.secondary)
        case .checking: Text("Đang kiểm tra…").foregroundStyle(.secondary)
        case .upToDate: Text("Đang dùng bản mới nhất (\(AppInfo.version))").foregroundStyle(.secondary)
        case .available(let release): Text("Có bản mới \(release.version)")
        case .installing(let message): Text(message).foregroundStyle(.secondary)
        case .failed(let message): Text(message).foregroundStyle(.red).font(.caption)
        }
    }

    private let intervals: [(String, Double)] = [
        ("1 phút", 60), ("2 phút", 120), ("5 phút", 300),
        ("10 phút", 600), ("15 phút", 900), ("30 phút", 1800),
    ]

    var body: some View {
        Form {
            Section("Kiểm tra thư") {
                Picker("Tần suất kiểm tra", selection: $interval) {
                    ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                }
                .onChange(of: interval) { _ in checker.scheduleTimer() }
                Toggle("Hiện số thư chưa đọc trên menubar", isOn: $showCount)
                Toggle("Tự đánh dấu đã đọc khi mở xem thư", isOn: $markReadOnOpen)
                Toggle(isOn: $preferPlainText) {
                    Text("Đọc thư dạng văn bản (nhẹ hơn)")
                    Text("Không dùng WebKit khi mở thư. Bấm nút HTML trong thư để xem bản đầy đủ.")
                }
                Toggle(isOn: $smartActions) {
                    Text("Nhận diện mã xác minh và link xác minh")
                    Text("Trong trình đọc thư, hiện nút sao chép mã (OTP) và mở link xác minh. App không bao giờ tự mở link.")
                }
                Toggle(isOn: $prefetchMessages) {
                    Text("Tải sẵn nội dung thư mới")
                    Text("Lưu tạm vào thư mục cache của app để mở thư là xem được ngay. Chỉ giữ thư chưa đọc, tự xoá khi thư đã đọc hoặc bị xoá.")
                }
                .onChange(of: prefetchMessages) { on in
                    if !on { Task.detached { MessageCache.removeAll() } }
                }
            }

            Section("Thông báo") {
                Toggle("Thông báo khi có thư mới", isOn: $notificationsEnabled)
                Toggle("Phát âm thanh", isOn: $notificationSound)
                    .disabled(!notificationsEnabled)
                Button("Gửi thông báo thử") {
                    Notifier.shared.notify(title: "MailBar",
                                           subtitle: "Thông báo thử",
                                           body: "Thông báo đang hoạt động 🎉",
                                           url: nil)
                }
                .disabled(!notificationsEnabled)
            }

            Section {
                Toggle("Tự kiểm tra bản mới", isOn: $autoCheckUpdates)
                HStack {
                    updateStatus
                    Spacer()
                    if let release = updater.available {
                        Button("Cập nhật lên \(release.version)") { Task { await updater.install() } }
                            .disabled(updater.isBusy)
                    } else {
                        Button("Kiểm tra ngay") { Task { await updater.check() } }
                            .disabled(updater.isBusy)
                    }
                }
            } header: {
                Text("Cập nhật")
            } footer: {
                Text("Bản mới lấy từ github.com/\(Updater.repo). App chỉ cài khi file khớp mã SHA-256 và cùng chữ ký với bản đang chạy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Tự khởi động cùng macOS", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Hệ thống")
            } footer: {
                Text("Nên đặt MailBar.app trong thư mục Applications trước khi bật.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
