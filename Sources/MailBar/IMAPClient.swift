import Foundation
import Network

enum IMAPError: LocalizedError {
    case connectionFailed(String)
    case timeout
    case closed
    case authFailed(String)
    case commandFailed(String)
    case badGreeting(String)
    case missingPassword
    case noTrash
    case noSpam
    case notFound

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let m): return "Không kết nối được máy chủ: \(m)"
        case .timeout: return "Hết thời gian chờ máy chủ phản hồi"
        case .closed: return "Máy chủ đã đóng kết nối"
        case .authFailed(let m): return "Đăng nhập thất bại: \(m)"
        case .commandFailed(let m): return "Lỗi IMAP: \(m)"
        case .badGreeting(let m): return "Máy chủ từ chối kết nối: \(m)"
        case .missingPassword: return "Chưa nhập mật khẩu ứng dụng"
        case .noTrash: return "Không tìm thấy thư mục Thùng rác trên máy chủ"
        case .noSpam: return "Không tìm thấy thư mục Spam trên máy chủ"
        case .notFound: return "Không tìm thấy thư (có thể đã bị xoá hoặc chuyển đi)"
        }
    }
}

/// Một dòng phản hồi IMAP. Các literal `{n}` được tách riêng vào `literals`.
struct IMAPResponse {
    var text: String
    var literals: [Data]
}

/// Client IMAP tối giản trên Network.framework — chỉ đủ để đăng nhập, đọc INBOX (read-only) và lấy header.
final class IMAPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "MailBar.IMAP")
    private var buffer = Data()
    private var tagCounter = 0
    private var didTimeout = false

    /// Giới hạn phòng máy chủ lỗi/độc hại làm phình RAM: một literal (thư ~2 MB/lần tải) và một dòng chữ.
    private static let maxLiteral = 32 * 1024 * 1024
    private static let maxLine = 1024 * 1024

    init(host: String, port: Int, useTLS: Bool) {
        let params: NWParameters = useTLS ? .tls : .tcp
        let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 993
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
    }

    deinit { connection.cancel() }

    func open(timeout: TimeInterval) async throws {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.didTimeout = true
            self.connection.cancel()
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = Flag()
            connection.stateUpdateHandler = { [weak self] state in
                guard !resumed.value else { return }
                switch state {
                case .ready:
                    resumed.value = true
                    cont.resume()
                case .failed(let err):
                    resumed.value = true
                    cont.resume(throwing: IMAPError.connectionFailed(err.localizedDescription))
                case .waiting(let err):
                    resumed.value = true
                    self?.connection.cancel()
                    cont.resume(throwing: IMAPError.connectionFailed(err.localizedDescription))
                case .cancelled:
                    resumed.value = true
                    cont.resume(throwing: (self?.didTimeout ?? false) ? IMAPError.timeout : IMAPError.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        let greeting = try await readResponse()
        guard greeting.text.hasPrefix("* OK") || greeting.text.hasPrefix("* PREAUTH") else {
            throw IMAPError.badGreeting(greeting.text)
        }
    }

    func close() {
        connection.cancel()
    }

    /// Gửi lệnh có tag, trả về các phản hồi untagged. Ném lỗi nếu nhận NO/BAD.
    @discardableResult
    func command(_ cmd: String) async throws -> [IMAPResponse] {
        tagCounter += 1
        let tag = String(format: "A%03d", tagCounter)
        try await send("\(tag) \(cmd)\r\n")

        var untagged: [IMAPResponse] = []
        while true {
            let resp = try await readResponse()
            if resp.text.hasPrefix(tag + " ") {
                let status = resp.text.dropFirst(tag.count + 1)
                if status.uppercased().hasPrefix("OK") { return untagged }
                throw IMAPError.commandFailed(String(status))
            }
            untagged.append(resp)
        }
    }

    // MARK: - I/O

    private func send(_ string: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(string.utf8), completion: .contentProcessed { [weak self] err in
                if let err {
                    cont.resume(throwing: (self?.didTimeout ?? false) ? IMAPError.timeout : IMAPError.connectionFailed(err.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func receiveMore() async throws {
        let chunk: Data = try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: (self?.didTimeout ?? false) ? IMAPError.timeout : IMAPError.connectionFailed(error.localizedDescription))
                } else if isComplete {
                    cont.resume(throwing: (self?.didTimeout ?? false) ? IMAPError.timeout : IMAPError.closed)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
        buffer.append(chunk)
    }

    private func readLine() async throws -> Data {
        let crlf = Data([13, 10])
        while true {
            if let r = buffer.range(of: crlf) {
                let line = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return line
            }
            if buffer.count > Self.maxLine { throw IMAPError.commandFailed("Dòng phản hồi quá dài") }
            try await receiveMore()
        }
    }

    private func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count { try await receiveMore() }
        let data = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return data
    }

    private func readResponse() async throws -> IMAPResponse {
        var text = ""
        var literals: [Data] = []
        while true {
            let line = String(decoding: try await readLine(), as: UTF8.self)
            text += line
            guard let n = Self.literalLength(line) else {
                return IMAPResponse(text: text, literals: literals)
            }
            guard n >= 0, n <= Self.maxLiteral else { throw IMAPError.commandFailed("Literal không hợp lệ") }
            literals.append(try await readBytes(n))
        }
    }

    private static func literalLength(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        let digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        // Chỉ nhận chữ số; số quá lớn (tràn Int) trả Int.max để nơi gọi từ chối.
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits) ?? Int.max
    }
}

/// Cờ dùng trong callback của NWConnection (luôn chạy trên cùng một serial queue).
private final class Flag: @unchecked Sendable {
    var value = false
}

struct InboxSnapshot {
    /// Toàn bộ thư chưa đọc (Hộp thư đến + Spam nếu bật).
    let unread: Set<MessageKey>
    /// Thứ tự hiển thị: Hộp thư đến (mới nhất trước) rồi Spam, giới hạn theo `limit`/`spamLimit`.
    let display: [MessageKey]
    /// Header vừa tải — chỉ gồm thư KHÔNG có trong `knownHeaders` (caller giữ cache cho phần còn lại).
    let fetched: [MailMessage]
    /// Ghi chú về Spam (vd. không tìm thấy thư mục), `nil` nếu ổn hoặc không bật.
    let spamNote: String?
}

enum IMAPService {
    // MARK: - Đọc

    /// `knownHeaders`: thư đã có header trong cache của caller → không tải lại (tiết kiệm mạng mỗi chu kỳ).
    static func fetchUnread(account: MailAccount, password: String, knownHeaders: Set<MessageKey> = [],
                            limit: Int = 50, spamLimit: Int = 20) async throws -> InboxSnapshot {
        try await withSession(account, password) { conn, _ in
            func known(_ mailbox: String) -> Set<UInt32> {
                Set(knownHeaders.lazy.filter { $0.mailbox == mailbox }.map(\.uid))
            }
            let inboxName = account.mailboxName
            let inbox = try await fetchUnreadHeaders(conn, mailbox: inboxName, isSpam: false,
                                                     limit: limit, skip: known(inboxName))
            var unread = Set(inbox.uids.map { MessageKey(mailbox: inboxName, uid: $0) })
            var display = inbox.display.map { MessageKey(mailbox: inboxName, uid: $0) }
            var fetched = inbox.fetched
            var spamNote: String?

            if account.checkSpam {
                // Lỗi lệnh ở Spam (NO/BAD) chỉ hạ thành ghi chú; kết quả INBOX vẫn trả về.
                // Lỗi kết nối/timeout vẫn ném ra như cũ.
                do {
                    if let junk = try await findFolder(conn, attribute: "\\junk", names: spamNames) {
                        let spam = try await fetchUnreadHeaders(conn, mailbox: junk, isSpam: true,
                                                                limit: spamLimit, skip: known(junk))
                        unread.formUnion(spam.uids.map { MessageKey(mailbox: junk, uid: $0) })
                        display += spam.display.map { MessageKey(mailbox: junk, uid: $0) }
                        fetched += spam.fetched
                    } else {
                        spamNote = "Không tìm thấy thư mục Spam trên máy chủ"
                    }
                } catch IMAPError.commandFailed(let m) {
                    spamNote = "Không đọc được thư mục Spam: \(m)"
                }
            }
            return InboxSnapshot(unread: unread, display: display, fetched: fetched, spamNote: spamNote)
        }
    }

    /// EXAMINE (chỉ đọc) một thư mục: trả về mọi UID chưa đọc, `limit` UID mới nhất (mới nhất trước) để hiển thị,
    /// và header của những UID trong số đó chưa nằm trong `skip`.
    private static func fetchUnreadHeaders(_ conn: IMAPConnection, mailbox: String, isSpam: Bool, limit: Int,
                                           skip: Set<UInt32>) async throws
        -> (uids: [UInt32], display: [UInt32], fetched: [MailMessage]) {
        try await conn.command("EXAMINE \(quote(mailbox))")

        var uids: [UInt32] = []
        for resp in try await conn.command("UID SEARCH UNSEEN") where resp.text.uppercased().hasPrefix("* SEARCH") {
            uids += resp.text.dropFirst(8).split(separator: " ").compactMap { UInt32($0) }
        }
        uids.sort()

        var messages: [MailMessage] = []
        let latest = Array(uids.suffix(limit))
        let toFetch = latest.filter { !skip.contains($0) }
        if !toFetch.isEmpty {
            let resps = try await conn.command("UID FETCH \(uidSet(toFetch)) (UID BODY.PEEK[HEADER.FIELDS (SUBJECT FROM DATE MESSAGE-ID)])")
            for resp in resps where resp.text.hasPrefix("* ") && resp.text.uppercased().contains(" FETCH ") {
                guard let uid = extractUID(resp.text) else { continue }
                let headers = MIMEDecoder.parseHeaders(resp.literals.first ?? Data())
                let subject = MIMEDecoder.decodeHeader(headers["subject"] ?? "").trimmingCharacters(in: .whitespaces)
                messages.append(MailMessage(
                    uid: uid,
                    subject: subject.isEmpty ? "(Không có tiêu đề)" : subject,
                    from: MIMEDecoder.displayName(fromHeader: headers["from"] ?? ""),
                    fromAddress: MIMEDecoder.address(fromHeader: headers["from"] ?? ""),
                    date: MIMEDecoder.parseDate(headers["date"] ?? ""),
                    messageID: headers["message-id"].map {
                        $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
                    },
                    mailbox: mailbox,
                    isSpam: isSpam
                ))
            }
        }
        messages.sort { $0.uid > $1.uid }
        return (uids, latest.reversed(), messages)
    }

    /// Tải nội dung thư (tối đa ~2 MB đầu, đủ cho phần chữ) mà không đổi trạng thái đã đọc.
    static func fetchMessage(account: MailAccount, password: String, mailbox: String, uid: UInt32) async throws -> Data {
        try await withSession(account, password, timeout: 60) { conn, _ in
            try await conn.command("EXAMINE \(quote(mailbox))")
            let resps = try await conn.command("UID FETCH \(uid) (UID BODY.PEEK[]<0.2000000>)")
            guard let data = resps.first(where: { extractUID($0.text) == uid })?.literals.first else {
                throw IMAPError.notFound
            }
            return data
        }
    }

    /// Tải sẵn nhiều thư trong MỘT phiên (chỉ đọc, `BODY.PEEK`), từng đợt nhỏ. Mỗi thư tải xong gọi `onMessage`
    /// ngay (để ghi cache), nên thư nào xong trước dùng được trước. Giới hạn dung lượng giống `fetchMessage`.
    static func prefetchMessages(account: MailAccount, password: String, keys: [MessageKey],
                                 onMessage: @Sendable (MessageKey, Data) -> Void) async throws {
        guard !keys.isEmpty else { return }
        try await withSession(account, password, timeout: 120) { conn, _ in
            for (mailbox, group) in Dictionary(grouping: keys, by: \.mailbox) {
                try await conn.command("EXAMINE \(quote(mailbox))")
                let uids = group.map(\.uid)
                for start in stride(from: 0, to: uids.count, by: 4) {
                    let chunk = Array(uids[start..<min(start + 4, uids.count)])
                    let resps = try await conn.command("UID FETCH \(uidSet(chunk)) (UID BODY.PEEK[]<0.2000000>)")
                    for resp in resps {
                        guard let uid = extractUID(resp.text), chunk.contains(uid),
                              let data = resp.literals.first else { continue }
                        onMessage(MessageKey(mailbox: mailbox, uid: uid), data)
                    }
                }
            }
        }
    }

    // MARK: - Ghi

    static func setSeen(account: MailAccount, password: String, mailbox: String,
                        uids: [UInt32], seen: Bool) async throws {
        guard !uids.isEmpty else { return }
        try await withSession(account, password) { conn, _ in
            try await conn.command("SELECT \(quote(mailbox))")
            for chunk in uidChunks(uids) {
                try await conn.command("UID STORE \(uidSet(chunk)) \(seen ? "+" : "-")FLAGS.SILENT (\\Seen)")
            }
        }
    }

    /// Chuyển thư vào Thùng rác (không xoá vĩnh viễn).
    static func moveToTrash(account: MailAccount, password: String, mailbox: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await withSession(account, password) { conn, caps in
            guard let trash = try await findFolder(conn, attribute: "\\trash", names: trashNames) else {
                throw IMAPError.noTrash
            }
            try await move(conn, caps: caps, from: mailbox, to: trash, uids: uids)
        }
    }

    /// "Đánh dấu spam": chuyển thư vào thư mục Spam (tìm theo cờ `\Junk` hoặc tên quen thuộc). Không xoá vĩnh viễn.
    static func moveToSpam(account: MailAccount, password: String, mailbox: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await withSession(account, password) { conn, caps in
            guard let junk = try await findFolder(conn, attribute: "\\junk", names: spamNames) else {
                throw IMAPError.noSpam
            }
            try await move(conn, caps: caps, from: mailbox, to: junk, uids: uids)
        }
    }

    /// "Không phải spam": chuyển thư từ thư mục Spam về Hộp thư đến.
    static func moveToInbox(account: MailAccount, password: String, from mailbox: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await withSession(account, password) { conn, caps in
            try await move(conn, caps: caps, from: mailbox, to: account.mailboxName, uids: uids)
        }
    }

    /// MOVE nếu máy chủ hỗ trợ; nếu không thì COPY + đánh dấu \Deleted + UID EXPUNGE (chỉ khi có UIDPLUS).
    private static func move(_ conn: IMAPConnection, caps: Set<String>, from: String, to: String,
                             uids: [UInt32]) async throws {
        try await conn.command("SELECT \(quote(from))")
        for chunk in uidChunks(uids) {
            let set = uidSet(chunk)
            if caps.contains("MOVE") {
                try await conn.command("UID MOVE \(set) \(quote(to))")
            } else {
                try await conn.command("UID COPY \(set) \(quote(to))")
                try await conn.command("UID STORE \(set) +FLAGS.SILENT (\\Deleted \\Seen)")
                if caps.contains("UIDPLUS") {
                    try await conn.command("UID EXPUNGE \(set)")
                }
            }
        }
    }

    // MARK: - Helpers

    private static func withSession<T>(_ account: MailAccount,
                                       _ password: String,
                                       timeout: TimeInterval = 30,
                                       _ body: (IMAPConnection, Set<String>) async throws -> T) async throws -> T {
        guard !password.isEmpty else { throw IMAPError.missingPassword }

        let host = account.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let conn = IMAPConnection(host: host, port: account.port, useTLS: account.useTLS)
        defer { conn.close() }

        try await conn.open(timeout: timeout)

        do {
            try await conn.command("LOGIN \(quote(account.loginUser)) \(quote(password))")
        } catch IMAPError.commandFailed(let message) {
            throw IMAPError.authFailed(message)
        }

        // Một số máy chủ (Lark/Feishu, NetEase...) yêu cầu lệnh ID; máy chủ khác có thể từ chối — bỏ qua lỗi.
        _ = try? await conn.command("ID (\"name\" \"MailBar\" \"version\" \(quote(clientVersion)))")

        var caps = Set<String>()
        for resp in (try? await conn.command("CAPABILITY")) ?? [] where resp.text.uppercased().hasPrefix("* CAPABILITY") {
            caps.formUnion(resp.text.dropFirst(13).split(separator: " ").map { $0.uppercased() })
        }

        let result = try await body(conn, caps)
        _ = try? await conn.command("LOGOUT")
        return result
    }

    /// Phiên bản app gửi trong lệnh ID (đọc từ Info.plist; chạy ngoài .app thì "dev").
    private static let clientVersion =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"

    private static let spamNames = [
        "[Gmail]/Spam", "[Google Mail]/Spam", "Spam", "Junk", "Junk E-mail", "Junk Email",
        "INBOX.Spam", "INBOX.Junk", "Bulk Mail",
        "&V4NXPpCuTvY-",  // 垃圾邮件 (Lark/Feishu)
    ]

    private static let trashNames = [
        "[Gmail]/Trash", "[Google Mail]/Trash", "[Gmail]/Bin", "[Google Mail]/Bin",
        "Trash", "INBOX.Trash", "Deleted Messages", "Deleted Items", "Deleted", "Bin",
        "&XfJSIJZk-",  // 已删除 (Lark/Feishu)
    ]

    /// Tìm thư mục đặc biệt: ưu tiên cờ SPECIAL-USE (vd. `\trash`, `\junk`, viết thường), sau đó theo tên quen thuộc.
    private static func findFolder(_ conn: IMAPConnection, attribute: String, names: [String]) async throws -> String? {
        var folders: [(name: String, attrs: String)] = []
        for resp in try await conn.command("LIST \"\" \"*\"") {
            guard resp.text.uppercased().hasPrefix("* LIST "),
                  let open = resp.text.firstIndex(of: "("),
                  let close = resp.text.firstIndex(of: ")") else { continue }
            let attrs = String(resp.text[resp.text.index(after: open)..<close]).lowercased()
            let rest = resp.text[resp.text.index(after: close)...].trimmingCharacters(in: .whitespaces)

            // rest = <delimiter> <tên>; delimiter là "x" hoặc NIL.
            var nameField: Substring
            if rest.hasPrefix("\"") {
                guard let end = rest.dropFirst().firstIndex(of: "\"") else { continue }
                nameField = rest[rest.index(after: end)...]
            } else {
                nameField = rest.drop { $0 != " " }
            }
            nameField = nameField.drop { $0 == " " }

            let name: String
            if nameField.hasSuffix("}"), let literal = resp.literals.first {
                name = String(decoding: literal, as: UTF8.self)
            } else if nameField.hasPrefix("\"") && nameField.hasSuffix("\"") && nameField.count >= 2 {
                name = String(nameField.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            } else {
                name = String(nameField)
            }
            folders.append((name, attrs))
        }

        if let special = folders.first(where: { $0.attrs.contains(attribute) }) { return special.name }
        for candidate in names {
            if let match = folders.first(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return match.name
            }
        }
        return nil
    }

    /// Gộp UID liên tiếp thành dải: [1,2,3,7] → "1:3,7".
    static func uidSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(i == j ? "\(sorted[i])" : "\(sorted[i]):\(sorted[j])")
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    /// Chia UID (đã sắp xếp, bỏ trùng) thành các đợt để mỗi lệnh không quá dài (máy chủ hay giới hạn vài KB/dòng).
    static func uidChunks(_ uids: [UInt32], size: Int = 400) -> [[UInt32]] {
        let sorted = Array(Set(uids)).sorted()
        return stride(from: 0, to: sorted.count, by: size).map { Array(sorted[$0..<min($0 + size, sorted.count)]) }
    }

    private static func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func extractUID(_ text: String) -> UInt32? {
        guard let range = text.range(of: #"UID (\d+)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return UInt32(text[range].dropFirst(4))
    }
}
