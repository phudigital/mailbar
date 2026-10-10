import SwiftUI

struct ReadingTarget: Identifiable, Equatable {
    let account: MailAccount
    let message: MailMessage
    var id: String { "\(account.id)-\(message.uid)" }
}

struct MenuContentView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var checker: MailChecker
    @EnvironmentObject private var updater: Updater
    @State private var contentHeight: CGFloat = 0
    @State private var reading: ReadingTarget?

    static let panelWidth: CGFloat = 400

    private var enabledAccounts: [MailAccount] { store.accounts.filter(\.enabled) }

    /// Chiều cao tối đa của hộp: gần hết chiều cao màn hình.
    private var maxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(360, screen - 110)
    }

    var body: some View {
        Group {
            if let reading {
                // Giữ nguyên kích thước bảng menubar, không phóng to khi đọc thư.
                ReaderView(target: reading) { self.reading = nil }
                    .frame(width: Self.panelWidth, height: min(maxHeight, 520))
            } else {
                list.frame(width: Self.panelWidth)
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if enabledAccounts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    // LazyVStack: chỉ dựng các dòng đang hiện (mỗi dòng SwiftUI tốn ~170 KB RAM).
                    // AccountSection trả về Group + ForEach nên các dòng được "trải phẳng" vào stack này.
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(enabledAccounts) { account in
                            AccountSection(account: account, status: checker.statuses[account.id]) { message in
                                reading = ReadingTarget(account: account, message: message)
                            }
                            if account.id != enabledAccounts.last?.id {
                                Divider().padding(.horizontal, 12).padding(.vertical, 4)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    // Đo chiều cao nội dung trực tiếp (PreferenceKey không truyền ra ngoài ScrollView trên macOS).
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { contentHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { contentHeight = $0 }
                    })
                }
                .frame(height: min(max(contentHeight, 60), maxHeight))
            }

            if let release = updater.available {
                Divider()
                updateBanner(release)
            } else if case .installing(let message) = updater.state {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            } else if case .failed(let message) = updater.state, message.hasPrefix("Cập nhật thất bại") {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.caption).lineLimit(2)
                    Spacer()
                    Button("Thử lại") { Task { await updater.check() } }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Divider()
            footer
        }
    }

    /// Có bản mới: bấm Cập nhật để tải, kiểm tra, thay app và mở lại.
    private func updateBanner(_ release: ReleaseInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            Text("Có bản mới \(release.version)").font(.callout)
            Spacer()
            Button("Chi tiết") { NSWorkspace.shared.open(release.pageURL) }
                .buttonStyle(.borderless)
            Button("Cập nhật") { Task { await updater.install() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    private var header: some View {
        HStack {
            Text("MailBar").font(.headline)
            if checker.totalUnread > 0 {
                Text("\(checker.totalUnread) chưa đọc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if checker.isChecking {
                ProgressView().controlSize(.small)
            }
            Button {
                checker.checkAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Kiểm tra ngay")
            .disabled(checker.isChecking)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Chưa có tài khoản nào được bật")
                .foregroundStyle(.secondary)
            Button("Thêm tài khoản…") { SettingsWindowController.shared.show() }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            Button {
                SettingsWindowController.shared.show()
            } label: {
                Label("Cài đặt…", systemImage: "gearshape")
            }
            Spacer()
            Button {
                SettingsWindowController.shared.show(tab: .about)
            } label: {
                Text("v\(AppInfo.version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .help("Giới thiệu & hướng dẫn")
            Spacer()
            Button {
                SettingsWindowController.shared.show(tab: .about)
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .help("Hướng dẫn sử dụng")
            Button("Thoát") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Danh sách

private struct AccountSection: View {
    @EnvironmentObject private var checker: MailChecker
    let account: MailAccount
    let status: MailChecker.Status?
    let onRead: (MailMessage) -> Void

    var body: some View {
        Group {
            HStack(spacing: 8) {
                Image(systemName: account.provider.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(account.provider.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if account.displayName != account.email {
                        Text(account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if status?.isChecking == true {
                    ProgressView().controlSize(.mini)
                }
                if let unread = status?.unread, unread > 0 {
                    Text("\(unread)")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(account.provider.tint))
                        .foregroundStyle(.white)
                }
                Menu {
                    Button("Mở hộp thư trên web") { checker.open(account) }
                    Button("Đánh dấu tất cả đã đọc") { checker.markAllRead(account) }
                        .disabled((status?.unread ?? 0) == 0)
                    Divider()
                    Button("Kiểm tra lại") { Task { await checker.check(account) } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Thao tác với tài khoản")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if let error = status?.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
            } else if let status, status.lastChecked != nil, status.unread == 0 {
                Text("Không có thư chưa đọc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            } else if status == nil || status?.lastChecked == nil {
                Text("Đang kiểm tra…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }

            if let status {
                let inbox = status.messages.filter { !$0.isSpam }
                let spam = status.messages.filter(\.isSpam)

                ForEach(inbox) { row($0) }
                let remaining = (status.unread - status.spamUnread) - inbox.count
                if remaining > 0 {
                    Button("… và \(remaining) thư chưa đọc khác — mở trên web") { checker.open(account) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }

                if account.checkSpam && (status.spamUnread > 0 || status.spamNote != nil) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.bin")
                        Text(status.spamUnread > 0 ? "Spam · \(status.spamUnread) chưa đọc" : "Spam")
                        if let note = status.spamNote {
                            Text("— \(note)").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                    ForEach(spam) { row($0) }
                    let spamRemaining = status.spamUnread - spam.count
                    if spamRemaining > 0 {
                        Text("… và \(spamRemaining) thư spam khác")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    private func row(_ message: MailMessage) -> some View {
        MessageRow(message: message,
                   onOpen: { onRead(message) },
                   onMarkRead: { checker.markRead(account, messages: [message]) },
                   onDelete: { checker.moveToTrash(account, messages: [message]) },
                   onNotSpam: message.isSpam ? { checker.notSpam(account, message: message) } : nil,
                   onMarkSpam: message.isSpam ? nil : { checker.markSpam(account, messages: [message]) },
                   onWeb: { checker.open(account, message: message) })
    }
}

private struct MessageRow: View {
    let message: MailMessage
    let onOpen: () -> Void
    let onMarkRead: () -> Void
    let onDelete: () -> Void
    let onNotSpam: (() -> Void)?
    let onMarkSpam: (() -> Void)?
    let onWeb: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(message.isSpam ? Color.orange : Color.accentColor)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.from)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !hovering, let date = message.date {
                        Text(Self.format(date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(message.subject)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)

            if hovering {
                HStack(spacing: 2) {
                    RowAction(symbol: "envelope.open", help: "Đánh dấu đã đọc", action: onMarkRead)
                    if let onNotSpam {
                        RowAction(symbol: "tray.and.arrow.down", help: "Không phải spam — chuyển về Hộp thư đến", action: onNotSpam)
                    }
                    RowAction(symbol: "trash", help: "Chuyển vào Thùng rác", action: onDelete)
                    if let onMarkSpam {
                        RowAction(symbol: "exclamationmark.octagon", help: "Đánh dấu là spam — chuyển vào thư mục Spam", action: onMarkSpam)
                    }
                    RowAction(symbol: "safari", help: "Mở trên web", action: onWeb)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.08) : .clear)
        )
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
    }

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "dd/MM"
        return f.string(from: date)
    }
}

private struct RowAction: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Đọc thư

private struct ReaderView: View {
    @EnvironmentObject private var checker: MailChecker
    @AppStorage(Prefs.markReadOnOpen) private var markReadOnOpen = true

    let target: ReadingTarget
    let onClose: () -> Void

    @AppStorage(Prefs.preferPlainText) private var preferPlainText = true
    @AppStorage(Prefs.smartActions) private var smartActions = true
    @State private var smart = SmartContent()
    @State private var parsed: ParsedMessage?
    @State private var loadError: String?
    @State private var allowRemote = false
    @State private var showHTML = false

    /// Dùng WKWebView (nặng: thêm 3 tiến trình WebKit) chỉ khi người dùng muốn HTML hoặc không có bản văn bản.
    private var rendersHTML: Bool {
        guard let parsed else { return false }
        return showHTML || !preferPlainText || parsed.plainText == nil
    }

    private var account: MailAccount { target.account }
    private var message: MailMessage { target.message }
    private var isUnread: Bool { checker.isUnread(account, message: message) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            headerInfo
            Divider()
            if !smart.isEmpty {
                SmartActionsBox(content: smart, isSpam: message.isSpam)
                Divider()
            }

            if let parsed {
                if rendersHTML {
                    if parsed.hasRemoteContent && !allowRemote {
                        HStack {
                            Image(systemName: "photo.badge.exclamationmark")
                            Text("Đã chặn hình ảnh từ xa để bảo vệ quyền riêng tư.")
                            Spacer()
                            Button("Tải hình ảnh") { allowRemote = true }
                                .controlSize(.small)
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.yellow.opacity(0.15))
                    }
                    MailWebView(html: parsed.displayHTML, allowRemote: allowRemote)
                        .background(parsed.html != nil ? Color.white : Color.clear)
                } else {
                    ScrollView {
                        Text(Self.capped(parsed.plainText ?? ""))
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            } else if let loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(loadError).multilineTextAlignment(.center).textSelection(.enabled)
                    Button("Thử lại") { Task { await load() } }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Đang tải thư…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button(action: onClose) {
                Label("Quay lại", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                if isUnread {
                    checker.markRead(account, messages: [message])
                } else {
                    checker.markUnread(account, message: message)
                }
            } label: {
                Label(isUnread ? "Đã đọc" : "Chưa đọc", systemImage: isUnread ? "envelope.open" : "envelope.badge")
            }
            .help(isUnread ? "Đánh dấu đã đọc" : "Đánh dấu chưa đọc")
            if message.isSpam {
                Button {
                    checker.notSpam(account, message: message)
                    onClose()
                } label: {
                    Label("Không phải spam", systemImage: "tray.and.arrow.down")
                }
                .help("Không phải spam — chuyển về Hộp thư đến")
            }
            Button {
                checker.moveToTrash(account, messages: [message])
                onClose()
            } label: {
                Label("Xoá", systemImage: "trash")
            }
            .help("Chuyển vào Thùng rác")
            if !message.isSpam {
                Button {
                    checker.markSpam(account, messages: [message])
                    onClose()
                } label: {
                    Label("Spam", systemImage: "exclamationmark.octagon")
                }
                .help("Đánh dấu là spam — chuyển vào thư mục Spam")
            }
            if parsed?.html != nil, parsed?.plainText != nil {
                Button {
                    showHTML.toggle()
                } label: {
                    Label(rendersHTML ? "Văn bản" : "HTML", systemImage: rendersHTML ? "text.alignleft" : "doc.richtext")
                }
                .help(rendersHTML ? "Xem dạng văn bản (nhẹ hơn)" : "Xem dạng HTML đầy đủ")
            }
            Button {
                checker.open(account, message: message)
            } label: {
                Label("Mở web", systemImage: "safari")
            }
            .help("Mở thư trên trình duyệt")
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var headerInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(parsed?.subject ?? message.subject)
                .font(.system(size: 13, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text(parsed?.from ?? message.from).font(.system(size: 12, weight: .semibold))
                if let address = parsed?.fromAddress ?? message.fromAddress, address != (parsed?.from ?? message.from) {
                    Text("<\(address)>").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let date = parsed?.date ?? message.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            if let to = parsed?.to, !to.isEmpty {
                Text("Đến: \(to)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let cc = parsed?.cc, !cc.isEmpty {
                Text("Cc: \(cc)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let attachments = parsed?.attachments, !attachments.isEmpty {
                Label(attachments.joined(separator: ", "), systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help("Mở thư trên web để tải tệp đính kèm")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Thư văn bản quá lớn làm Text() đứng giao diện: chỉ hiện phần đầu.
    private static func capped(_ text: String) -> String {
        guard text.count > 200_000 else { return text }
        return String(text.prefix(200_000)) + "\n\n…(đã rút gọn — bấm HTML hoặc Mở web để xem đủ)"
    }

    private func load() async {
        loadError = nil
        do {
            let result = try await checker.loadMessage(account, message: message)
            // Người dùng đã thoát trình đọc trong lúc tải: không tự đánh dấu đã đọc.
            guard !Task.isCancelled else { return }
            parsed = result
            if markReadOnOpen && isUnread {
                checker.markRead(account, messages: [message])
            }
            if smartActions {
                // Nhận diện chạy ngoài main thread; không bao giờ tự tải/mở link.
                let content = await Task.detached(priority: .utility) { SmartActions.detect(in: result) }.value
                if !Task.isCancelled { smart = content }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Mã xác minh / link xác minh

/// Khung đầu thư: nút sao chép mã (OTP) và mở/sao chép link xác minh. Chỉ hành động khi người dùng bấm.
private struct SmartActionsBox: View {
    let content: SmartContent
    let isSpam: Bool
    @State private var copiedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(content.codes) { code in
                HStack {
                    Image(systemName: "number.square").foregroundStyle(Color.accentColor)
                    Text(code.display)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(copiedID == code.id ? "Đã chép" : "Sao chép") { copy(code.value, id: code.id) }
                        .controlSize(.small)
                }
            }
            if isSpam && !content.links.isEmpty {
                Label("Thư nằm trong Spam — cẩn thận trước khi mở link.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(content.links) { link in
                HStack {
                    Image(systemName: "link").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(link.kind.title).font(.system(size: 12, weight: .semibold))
                        Text(link.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Mở") {
                        if let scheme = link.url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                            NSWorkspace.shared.open(link.url)
                        }
                    }
                    .controlSize(.small)
                    Button(copiedID == link.id ? "Đã chép" : "Sao chép link") { copy(link.url.absoluteString, id: link.id) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
    }

    private func copy(_ text: String, id: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Cho trình quản lý lịch sử clipboard biết đây là dữ liệu nhạy cảm, đừng lưu.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedID == id { copiedID = nil }
        }
    }
}
