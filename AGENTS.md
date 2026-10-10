# AGENTS.md — Hướng dẫn cho AI coding agent

Tài liệu này mô tả **kiến trúc, quy ước và các điểm dễ sai** của dự án MailBar. Hãy đọc hết trước khi sửa code.
Tài liệu cho người dùng cuối nằm ở `README.md`.

---

## 1. Tổng quan

**MailBar** là app macOS chạy trên menubar. App kiểm tra thư chưa đọc qua **IMAP** cho nhiều tài khoản (Gmail, Lark, Feishu, Yandex, IMAP tuỳ chỉnh). Các chức năng:

- Hiển thị số thư chưa đọc bằng badge trên icon.
- Liệt kê tiêu đề thư, đọc nội dung cơ bản.
- Đánh dấu đã đọc/chưa đọc, chuyển thư vào Thùng rác, mở webmail.
- Gửi thông báo macOS khi có thư mới.

| Thuộc tính | Giá trị |
|---|---|
| Ngôn ngữ | Swift, **Swift 5 language mode** (`swift-tools-version:5.9`) |
| UI | SwiftUI (`MenuBarExtra` kiểu `.window`) + AppKit cho cửa sổ cài đặt, icon, menu |
| Nền tảng tối thiểu | macOS 13 |
| Phụ thuộc ngoài | **Không có.** IMAP và MIME đều tự viết trên `Network.framework` và `Foundation` |
| Build | Swift Package Manager + `build.sh` (đóng gói `.app`, ký ad-hoc). Không cần Xcode, chỉ cần Command Line Tools |
| Bundle ID | `com.phudigital.MailBar` |
| Ngôn ngữ UI | Tiếng Việt, viết thẳng trong code (chưa có localization) |
| Comment trong code | Tiếng Việt |

---

## 2. Cấu trúc thư mục

```
mail-menubar/
├── AGENTS.md                 ← tài liệu này (cho AI/dev)
├── CLAUDE.md                 ← trỏ tới AGENTS.md
├── README.md                 ← hướng dẫn cho người dùng cuối
├── CHANGELOG.md              ← lịch sử phiên bản (cập nhật mỗi lần phát hành)
├── VERSION                   ← số phiên bản duy nhất (vd. 1.0.0) — build.sh đọc file này
├── packaging/
│   └── Doc-truoc-khi-cai.txt ← hướng dẫn cài đặt, được copy vào DMG thành "Đọc trước khi cài.txt"
├── Package.swift             ← SwiftPM: 1 executable target "MailBar", macOS 13
├── build.sh                  ← `./build.sh [app|install|dist]` (xem mục 7)
├── scripts/
│   ├── make-icon.swift       ← vẽ AppIcon.iconset (gọi từ build.sh khi chưa có build/AppIcon.icns)
│   └── release.sh            ← tạo GitHub Release từ dist/ (xem mục 7)
├── Sources/MailBar/
│   ├── MailBarApp.swift      ← @main, AppDelegate, MenuBarIcon (vẽ icon + badge)
│   ├── DemoMode.swift        ← chế độ demo (`--demo`) + chụp bảng menubar / tab Giới thiệu ra PNG
│   ├── AboutView.swift       ← AppInfo (phiên bản từ Info.plist) + tab "Giới thiệu" (hướng dẫn nhanh)
│   ├── Models.swift          ← MailProvider (preset), MailAccount, MailMessage
│   ├── Storage.swift         ← Keychain, AccountStore (danh sách tài khoản), Prefs (khoá UserDefaults)
│   ├── IMAPClient.swift      ← IMAPConnection (giao thức tầng thấp) + IMAPService (các thao tác cấp cao)
│   ├── MIMEDecoder.swift     ← giải mã header: RFC 2047, From, Date, charset
│   ├── MessageParser.swift   ← phân tích toàn bộ thư MIME → ParsedMessage (html/text/attachments)
│   ├── MessageCache.swift    ← cache tạm nội dung thư (.eml) trong ~/Library/Caches để mở thư là có ngay
│   ├── Updater.swift         ← tự cập nhật qua GitHub Releases (SemVer, kiểm tra SHA-256 + chữ ký, script thay app)
│   ├── MailChecker.swift     ← "bộ não": trạng thái, hẹn giờ, phát hiện thư mới, thao tác
│   ├── Notifier.swift        ← UNUserNotificationCenter (thông báo, bấm để mở web)
│   ├── MenuContentView.swift ← UI hộp xổ xuống: danh sách thư + trình đọc thư (ReaderView)
│   ├── MailWebView.swift     ← WKWebView hiển thị HTML thư (tắt JS, chặn ảnh từ xa)
│   └── SettingsView.swift    ← cửa sổ Cài đặt (NSWindow tự quản lý), tab Tài khoản + tab Chung
├── .build/                   ← (sinh ra) thư mục build của SwiftPM — không sửa
├── build/                    ← (sinh ra) MailBar.app, AppIcon.icns — không sửa
└── dist/                     ← (sinh ra) DMG/ZIP phát hành — không commit
```

---

## 3. Kiến trúc & luồng dữ liệu

### 3.1 Các lớp

```
┌──────────────────────── UI (SwiftUI/AppKit, @MainActor) ────────────────────────┐
│ MailBarApp ─ MenuBarExtra ─ MenuContentView ─ AccountSection / MessageRow       │
│                                            └─ ReaderView ─ MailWebView          │
│ SettingsWindowController ─ SettingsView ─ AccountsSettingsView / AccountEditor  │
│                                         └─ GeneralSettingsView                  │
└───────────────┬───────────────────────────────────────────┬─────────────────────┘
                │ @EnvironmentObject                        │
        ┌───────▼────────┐                         ┌────────▼────────┐
        │  MailChecker   │──── đọc danh sách ─────►│  AccountStore   │
        │  (singleton)   │                         │  (singleton)    │
        └──┬─────────┬───┘                         └───┬─────────┬───┘
           │         │                                 │         │
  ┌────────▼───┐ ┌───▼──────┐                 UserDefaults   Keychain
  │IMAPService │ │ Notifier │                 "accounts.v1"  (mật khẩu)
  └────┬───────┘ └──────────┘
       │ dùng
  ┌────▼──────────┐   ┌──────────────┐   ┌───────────────┐
  │IMAPConnection │   │ MIMEDecoder  │◄──│ MessageParser │
  │(NWConnection) │   └──────────────┘   └───────────────┘
  └───────────────┘
```

- **Singleton**: `AccountStore.shared`, `MailChecker.shared`, `Notifier.shared`, `SettingsWindowController.shared`. UI nhận hai singleton đầu qua `.environmentObject(...)`.
- **`@MainActor`**: `AccountStore`, `MailChecker`, `SettingsWindowController` và toàn bộ View đều chạy trên main actor. Mạng (`IMAPService`) là `nonisolated async`, nên tự chạy ngoài main thread.

### 3.2 Luồng khởi động

1. `AppDelegate.applicationDidFinishLaunching` thực hiện lần lượt:
   - `Prefs.registerDefaults()`
   - đặt activation policy `.accessory` (không hiện trên Dock)
   - `Notifier.setup()`
   - `MailChecker.shared.start()`
2. `start()` thực hiện:
   - tạo `Timer` theo `Prefs.checkInterval`
   - gọi `checkAll()` ngay
   - đăng ký kiểm tra lại 8 giây sau khi máy thức dậy
   - theo dõi `store.$accounts` để dọn trạng thái của tài khoản đã xoá hoặc bị tắt.
3. Nếu chưa có tài khoản nào, app tự mở cửa sổ Cài đặt.

### 3.3 Luồng kiểm tra thư (`MailChecker.check`)

```
Keychain.password ─► IMAPService.fetchUnread(account, password, limit: 50)
   └─ withSession: connect TLS ─► LOGIN ─► ID (bỏ qua lỗi) ─► CAPABILITY
        ─► fetchUnreadHeaders(INBOX):  EXAMINE ─► UID SEARCH UNSEEN ─► UID FETCH <50 mới nhất> (BODY.PEEK[HEADER.FIELDS …])
        ─► nếu account.checkSpam:  findFolder(\junk | spamNames) ─► fetchUnreadHeaders(<Spam>, limit 20)
        ─► LOGOUT
   ◄─ InboxSnapshot { unread: Set<MessageKey>, messages (INBOX trước, Spam sau), spamNote }
So sánh với knownKeys[account] → khoá mới **thuộc INBOX** → Notifier (≤3 thư: mỗi thư 1 thông báo; nhiều hơn: 1 thông báo gộp).
Thư Spam được tính vào badge nhưng **không** gửi thông báo.
Cập nhật statuses[account.id] → SwiftUI tự vẽ lại (badge, danh sách)
```

**Quy tắc phát hiện thư mới:**

- **Định danh thư là `MessageKey(mailbox, uid)`**, không phải UID trần, vì UID chỉ duy nhất trong một thư mục (UID của INBOX và Spam có thể trùng nhau).
- Lần kiểm tra đầu tiên của một tài khoản (`knownKeys[id] == nil`) **không** gửi thông báo, chỉ ghi nhận UID.
- Các lần sau: `knownKeys = known ∪ current`. Tập này chỉ tăng thêm, nên một thư bị đánh dấu chưa đọc lại sẽ không bị báo lại.

### 3.4 Luồng thao tác (đánh dấu đọc / xoá)

Mọi thao tác ghi đều đi qua `MailChecker` theo mẫu **optimistic update**:

1. Sửa `statuses` ngay (`removeLocally` / chèn lại thư) để UI phản hồi tức thì.
2. `perform(account, label) { IMAPService.xxx }` chạy trong `Task`.
3. Nếu lỗi: `await check(account)` để lấy trạng thái thật, rồi gán `statuses[id].error = "Không <label> được: …"`.

Mọi thao tác nhận `MailMessage` hoặc `MessageKey`. `perform` **gom theo thư mục** (`Dictionary(grouping:by: \.mailbox)`) rồi gọi IMAP cho từng thư mục.

| Thao tác UI | MailChecker | IMAP (`IMAPService`) |
|---|---|---|
| Đánh dấu đã đọc | `markRead(account, messages:)` | `setSeen(mailbox:)`: `SELECT` → `UID STORE … +FLAGS.SILENT (\Seen)` |
| Đánh dấu tất cả đã đọc | `markAllRead(account)` | như trên với toàn bộ `unreadKeys` (cả Spam), gộp dải `1:5,7` |
| Đánh dấu chưa đọc | `markUnread(account, message:)` | `setSeen(seen: false)`: `-FLAGS.SILENT (\Seen)` |
| Xoá | `moveToTrash(account, messages:)` | `findFolder(\trash)` → `move(from: mailbox, to: Thùng rác)` |
| Đánh dấu spam | `markSpam(account, messages:)` | `moveToSpam`: `findFolder(\junk \| spamNames)` → `move(from: mailbox, to: Spam)`; thiếu thư mục thì ném `IMAPError.noSpam`; xong thì `check` lại nếu `checkSpam` bật |
| Không phải spam | `notSpam(account, message:)` | `moveToInbox`: `move(from: Spam, to: INBOX)`, xong thì `check` lại |
| Đọc thư | `loadMessage(account, message:)` | `fetchMessage(mailbox:uid:)`: `EXAMINE` → `UID FETCH uid (BODY.PEEK[]<0.2000000>)` → `MessageParser.parse` (`Task.detached`) |
| Mở web | `open(account, message:)` | — (`NSWorkspace.open(account.webURL(for:))`; Gmail + Spam thêm `in:anywhere`) |

`move(...)`: dùng `UID MOVE` nếu máy chủ có `MOVE`. Nếu không thì `UID COPY` + `STORE (\Deleted \Seen)` + `UID EXPUNGE` (chỉ khi có `UIDPLUS`).

### 3.5 Lưu trữ

| Dữ liệu | Nơi lưu | Khoá |
|---|---|---|
| Danh sách tài khoản (`[MailAccount]`, JSON) | `UserDefaults` | `accounts.v1` |
| Mật khẩu ứng dụng | Keychain, generic password | service `com.phudigital.MailBar`, account = `MailAccount.id.uuidString` |
| Tuỳ chọn | `UserDefaults` | xem `Prefs` trong `Storage.swift`: `checkInterval` (giây, mặc định 120), `notificationsEnabled`, `notificationSound`, `showCount`, `markReadOnOpen`, `preferPlainText`, `prefetchMessages`, `autoCheckUpdates`, `lastUpdateCheck`, `notifiedUpdateVersion` |
| Trạng thái hộp thư, `knownKeys` | Chỉ trong bộ nhớ | mất khi thoát app (cố ý) |
| Nội dung thư tải sẵn (RFC 822 thô) | `~/Library/Caches/<bundle id>/Messages/<UUID tài khoản>/<fnv(mailbox)>_<uid>.eml` | xem `MessageCache` (mục 3.6); bật/tắt bằng `Prefs.prefetchMessages` |

### 3.6 Tải sẵn nội dung thư (`MessageCache`)

- Sau mỗi `check` thành công, `MailChecker.prefetch` lấy tối đa `prefetchLimit` (20) thư trong danh sách hiển thị chưa có trong cache (INBOX trước, mới nhất trước) và gọi `IMAPService.prefetchMessages`: **một phiên** `withSession`, `EXAMINE` + `UID FETCH … BODY.PEEK[]<0.2000000>` từng đợt 4 UID, cùng giới hạn 2 MB như `fetchMessage`. Mỗi thư xong là ghi file ngay qua callback. Chạy **sau** khi đã cập nhật `statuses` và `announce`, nên không làm chậm badge/thông báo. Mỗi tài khoản một lượt (`prefetching`); lỗi thì bỏ qua.
- `loadMessage` đọc cache trước (parse trong `Task.detached`); không có thì tải mạng như cũ. Nếu `Message-ID` trong file khác `message.messageID` (UID bị cấp lại do UIDVALIDITY đổi) thì xoá file và tải mạng. Khi tải mạng do cache miss **không** ghi ngược vào cache.
- Dọn cache: `prune(keep: snapshot.unread)` sau mỗi check; `moveToTrash` xoá file ngay; `reset(account)` xoá cả thư mục tài khoản; thay đổi danh sách tài khoản gọi `removeAll(except: active)`; tắt `prefetchMessages` trong Cài đặt gọi `removeAll()`.
- Riêng tư: thư mục 0700, file 0600, chỉ chứa thư chưa đọc. Đừng đưa cache ra ngoài `~/Library/Caches` và đừng giữ thư đã đọc.
- Cache lưu **bản thô**, không lưu bản đã parse, để `MessageParser` là nguồn sự thật duy nhất. Chế độ demo không đi qua đường này (không có mạng).

### 3.7 Tự cập nhật (`Updater`)

- Nguồn: `https://api.github.com/repos/phudigital/mailbar/releases/latest` (repo **public**, không token). `Updater.start()` (gọi trong `AppDelegate`, bỏ qua khi không chạy dạng `.app`) kiểm tra sau 20 giây rồi mỗi 24 giờ nếu `Prefs.autoCheckUpdates`; kiểm tra tự động im lặng khi lỗi mạng và báo bằng thông báo **một lần cho mỗi phiên bản**. Nút "Kiểm tra ngay" ở Cài đặt → Chung gọi `check()` không im lặng.
- Release phải có hai asset: `MailBar-<ver>.zip` và `SHA256SUMS.txt` (dạng `shasum -a 256`). `Updater.release(from:)` chỉ chấp nhận link `https://github.com/phudigital/mailbar/releases/download/…`; thiếu asset hoặc link lạ thì coi như không có bản mới. Tag `vX.Y.Z` so với `AppInfo.version` bằng `SemVer`.
- `install()`: kiểm tra quyền ghi thư mục chứa app → tải zip vào thư mục tạm → SHA-256 khớp `SHA256SUMS.txt` → `ditto -x -k` → bản mới phải thoả **Designated Requirement của chính app đang chạy** (`SecStaticCodeCheckValidity`: cùng identifier + cùng chứng chỉ) và đúng `CFBundleShortVersionString`/bundle id → `launchInstaller` ghi `install.sh` rồi chạy nền (`nohup`): chờ PID thoát, `ditto` bản mới thành `<app>.updating`, đổi tên bản cũ thành `<app>.old-update`, đổi tên bản mới vào chỗ, `open`; lỗi bước nào thì khôi phục bản cũ.
- **Hệ quả cho việc ký**: bản ký ad-hoc hoặc ký bằng chứng chỉ khác sẽ KHÔNG nhận được bản cập nhật tự động (cố ý, để chặn bản giả). Mọi bản phát hành phải ký bằng cùng chứng chỉ (`MailBar Local Signing` hoặc Developer ID). Đổi chứng chỉ = người dùng phải cài tay một lần. Đừng đổi `BUNDLE_ID`.
- Kiểm thử đầu-cuối: chạy một bản có `CFBundleShortVersionString` thấp hơn với `--update-selftest` (chỉ kiểm tra/cài/thoát, không đụng tài khoản hay Keychain). Phần logic thuần (`SemVer`, `Updater.release(from:)`, `Updater.checksum`) kiểm thử bằng harness như mục 7 (cần ghép toàn bộ `Sources/MailBar` trừ `MailBarApp.swift`).
- Phát hành: `./build.sh dist` → commit → `./scripts/release.sh`.

---

## 4. Mô tả chi tiết từng file

### `MailBarApp.swift`
- `MailBarApp` (`@main`): một scene duy nhất là `MenuBarExtra` kiểu `.window`. Label là `Image(nsImage: MenuBarIcon.image(...))`.
- `AppDelegate`: khởi động (xem 3.2).
- `MenuBarIcon.image(count:hasUnread:)` vẽ `NSImage` **template** cao 18pt, gồm SF Symbol `envelope` và badge bo tròn **đè lên** góc dưới bên phải. Icon chỉ rộng hơn phong bì 1pt (`max(symbolW + 1, badgeW + 6)`); người dùng yêu cầu icon sát gọn, đừng nới rộng ra. Badge dùng `setBlendMode(.clear)` để khoét viền và `.destinationOut` để khoét chữ số. Số lớn hơn 99 hiện `99+`. Khi `showCount = false` mà vẫn có thư chưa đọc thì dùng `envelope.badge`.

### `Models.swift`
- `MailProvider` (`gmail`, `lark`, `feishu`, `yandex`, `custom`): preset gồm host IMAP, cổng, URL web (có placeholder `{email}`), hướng dẫn lấy mật khẩu ứng dụng, SF Symbol, màu.
- `MailAccount` (`Codable`): id, name, provider, email, username (trống thì dùng email), host, port, useTLS, mailbox (mặc định `INBOX`), webURL, enabled, **checkSpam**.
  - `init(from:)` tự viết, **mọi trường dùng `decodeIfPresent`** để dữ liệu cũ vẫn đọc được. Khi thêm trường: thêm vào `CodingKeys` và thêm một dòng `decodeIfPresent`.
  - `apply(provider:)` đặt lại host, port, TLS, webURL theo preset.
  - `webURL(for:)` thay `{email}`. Với Gmail và khi thư có Message-ID, hàm trả về link `#search/rfc822msgid:<id>` để mở đúng thư.
- `MessageKey(mailbox, uid)`: định danh duy nhất của một thư.
- `MailMessage`: uid, subject, from (tên hiển thị), fromAddress, date, messageID, **mailbox**, **isSpam**; `key`/`id` là `MessageKey`.

### `Storage.swift`
- `Keychain` (`@MainActor`): `password(for:)`, `setPassword(_:for:)`, `deletePassword(for:)`, `isDenied(_:)`.
  - **Cache trong bộ nhớ**: mỗi phiên chỉ đọc Keychain một lần cho mỗi tài khoản, vì mỗi lần đọc macOS có thể hiện hộp thoại xin quyền. Nếu người dùng bấm Deny thì đánh dấu `denied` và không hỏi lại; `MailChecker.check` sẽ hiện lỗi hướng dẫn.
  - `setPassword` **xoá rồi thêm mới** (không dùng update), để bản app hiện tại trở thành chủ của mục Keychain và đọc được mà không bị hỏi.
- `AccountStore`: `@Published accounts`, cùng `upsert`, `remove` (xoá luôn mật khẩu Keychain) và `move`. Mỗi lần thay đổi đều tự `save()`.
- `Prefs`: hằng số khoá `UserDefaults` và `registerDefaults()` (gồm `prefetchMessages`, mặc định bật).

### `IMAPClient.swift`
- `IMAPError`: các lỗi kèm thông báo tiếng Việt (`errorDescription`) hiển thị thẳng trên UI.
- `IMAPConnection`: client IMAP tối giản dùng `NWConnection`.
  - `open(timeout:)`: kết nối, đọc lời chào `* OK` hoặc `* PREAUTH`. **Timeout áp cho cả phiên**: hết giờ thì `cancel()` kết nối, mọi thao tác đang chờ nhận `IMAPError.timeout`.
  - `command(_:)`: gửi lệnh có tag `A001…`, gom các phản hồi untagged cho tới dòng tagged. Nhận `NO` hoặc `BAD` thì ném `commandFailed`.
  - `readResponse()` hỗ trợ **literal** `{n}\r\n<n byte>`. Literal được tách vào `IMAPResponse.literals`, phần chữ nằm trong `text`.
- `IMAPService`: các thao tác cấp cao, mỗi lần gọi **mở một phiên mới** qua `withSession` (connect, LOGIN, ID, CAPABILITY, body, LOGOUT):
  - `fetchUnread` (INBOX + Spam nếu bật), `fetchMessage`, `prefetchMessages` (nhiều thư trong một phiên, callback từng thư), `setSeen`, `moveToTrash`, `moveToSpam`, `moveToInbox`. Các thao tác ghi đều nhận tham số `mailbox`.
  - `findFolder(attribute:names:)`: tìm thư mục theo cờ SPECIAL-USE (`\trash`, `\junk`). Nếu không có thì so tên theo `trashNames` / `spamNames`, gồm cả tên mUTF-7 của Lark/Feishu.
  - `uidSet`: gộp UID liên tiếp thành dải. `quote`: tạo IMAP quoted string. `extractUID`: lấy UID từ phản hồi.

### `MIMEDecoder.swift`
- `parseHeaders(Data)`: gộp các dòng gập (folded), khoá viết thường, giữ giá trị đầu tiên nếu trùng khoá.
- `decodeHeader`: RFC 2047 (`=?charset?B|Q?…?=`). Các encoded-word **liền kề cùng charset được ghép byte trước khi giải mã**, để không vỡ ký tự UTF-8 bị cắt ngang giữa hai word (rất hay gặp với tiếng Việt).
- `displayName(fromHeader:)`, `address(fromHeader:)`, `parseDate` (thử nhiều định dạng RFC 2822), `string(from:charset:)` (map tên charset IANA sang `String.Encoding`, mặc định UTF-8).

### `MessageParser.swift`
- `MessageParser.parse(Data) -> ParsedMessage`: header, thân HTML, thân text, tên tệp đính kèm.
- **Kỹ thuật chính**: chuyển toàn bộ byte thành chuỗi theo ánh xạ 1:1 byte → Unicode scalar (ISO-8859-1) để tách cấu trúc MIME. Sau đó `bytes(_:)` chuyển ngược lại byte trước khi giải mã base64, quoted-printable và charset.
- Duyệt đệ quy `multipart/*` (tối đa 10 tầng). Lấy `text/html` và `text/plain` đầu tiên gặp được. Phần có `Content-Disposition: attachment`, `message/rfc822`, hoặc phần không phải text mà có tên tệp thì đưa vào `attachments` (bỏ qua ảnh inline).
- `HeaderValue`: tách `value; key=val; …`, có hỗ trợ RFC 2231 `filename*=utf-8''…`.
- `ParsedMessage.displayHTML`: ưu tiên HTML; nếu chỉ có text thì escape rồi bọc trong `<pre-wrap>`. `hasRemoteContent` dò `src/background/url()` trỏ tới `http(s)`.

### `MailChecker.swift`
- `Status`: unreadKeys (`unread` = số lượng), messages (INBOX tối đa 50, rồi Spam tối đa 20), spamUnread, spamNote, error, lastChecked, isChecking.
- Hàm công khai: `start`, `scheduleTimer`, `checkAll`, `check`, `reset` (gọi sau khi sửa tài khoản), `markRead`, `markAllRead`, `markUnread`, `moveToTrash`, `markSpam`, `notSpam`, `loadMessage`, `isUnread`, `open`, `showDemo`.
- `totalUnread` là tổng số chưa đọc của các tài khoản đang bật, dùng cho badge.
- Chống chạy chồng: `checkAll` bỏ qua nếu đang `isChecking`; `check(account)` bỏ qua nếu tài khoản đó đang kiểm tra.

### `Notifier.swift`
- Chỉ hoạt động khi `Bundle.main.bundleIdentifier != nil`, tức là phải chạy dạng `.app`. Nếu chạy binary trần, `UNUserNotificationCenter` sẽ crash.
- `userInfo["url"]` được mở bằng `NSWorkspace` khi người dùng bấm vào thông báo.

### `MenuContentView.swift`
- `MenuContentView` chuyển giữa hai chế độ, **cùng bề ngang `panelWidth = 400`** (người dùng muốn bảng gắn menubar giữ nguyên kích thước, không phóng to khi đọc thư):
  - **danh sách**: cao `min(nội dung, màn hình − 110)`. Chiều cao nội dung đo bằng `GeometryReader` đặt ở background của nội dung bên trong `ScrollView`, ghi thẳng vào `@State contentHeight` qua `onAppear`/`onChange`.
  - **đọc thư** (`reading != nil`): cao `min(maxHeight, 520)`.
- `AccountSection`: tiêu đề tài khoản, badge, menu `⋯` (mở web, đánh dấu tất cả đã đọc, kiểm tra lại), dòng lỗi hoặc trạng thái, danh sách thư INBOX. Nếu `checkSpam` bật thì thêm tiêu đề cam "Spam · n chưa đọc" và danh sách thư spam.
- `MessageRow`: bấm vào để đọc; khi rê chuột hiện `RowAction` (đã đọc / [không phải spam, chỉ thư Spam] / xoá / [đánh dấu spam, chỉ thư INBOX, icon `exclamationmark.octagon` kế nút xoá] / mở web). Chấm màu xanh là thư INBOX, cam là Spam.
- Chân bảng: Cài đặt…, số phiên bản `vX.Y.Z` và nút `?` (cả hai mở tab Giới thiệu), Thoát.
- `ReaderView`: tải thư qua `checker.loadMessage`. Nếu bật `markReadOnOpen` thì tự đánh dấu đã đọc. Thanh công cụ có Quay lại (Esc), Đã đọc/Chưa đọc, Xoá, Spam (chỉ thư INBOX), Mở web. Nếu thư có nội dung từ xa thì hiện thanh vàng "Tải hình ảnh".

### `MailWebView.swift`
- `MailWebView` (`NSViewRepresentable`): `allowsContentJavaScript = false`. Link (kể cả `target=_blank`) mở bằng trình duyệt mặc định. Chỉ tải lại khi `html` hoặc `allowRemote` thay đổi (`loadedKey`).
  - Chèn CSS `img{max-width:100%}`. Sau khi tải xong (`didFinish`), đo `scrollWidth`; nếu rộng hơn bảng thì đặt `pageZoom` (tối thiểu 0.5) để thu nhỏ cho vừa. `evaluateJavaScript` của app **vẫn chạy** dù JS của nội dung thư đã tắt (đã kiểm chứng).
- `RemoteContentBlocker`: biên dịch một lần `WKContentRuleList` chặn `^https?://`.

### `SettingsView.swift`
- `SettingsWindowController`: tự tạo `NSWindow` + `NSHostingController`, **không** dùng scene `Settings` hay `Window` của SwiftUI (xem mục 6). `show(tab:)` mở thẳng một tab (`.accounts`, `.general`, `.about`) qua `Navigation` (ObservableObject).
  - Khi mở: chuyển sang `.regular` (hiện trên Dock), gọi `ensureEditMenu()` để ⌘C/⌘V/⌘A hoạt động.
  - Khi đóng: chuyển lại `.accessory`.
- `AccountsSettingsView`: danh sách tài khoản bên trái (nút + có menu chọn nhà cung cấp, nút − xoá có hỏi xác nhận) và `AccountEditor` bên phải. Tài khoản mới là bản nháp (`newAccount`) cho tới khi bấm "Thêm tài khoản".
- `AccountEditor`: form nhập liệu. "Kiểm tra kết nối" gọi `IMAPService.fetchUnread(limit: 1)`. "Lưu" thực hiện: ghi Keychain, `store.upsert`, `checker.reset`.
- `GeneralSettingsView`: tần suất kiểm tra, hiện số trên icon, tự đánh dấu đã đọc, thông báo, âm thanh, thông báo thử, tự khởi động (`SMAppService.mainApp`).

---

## 5. Quy ước bắt buộc

1. **Mặc định chỉ đọc.** Kiểm tra định kỳ phải dùng `EXAMINE` và `BODY.PEEK[...]`. Chỉ thao tác do người dùng bấm mới được dùng `SELECT`, `STORE`, `MOVE`, `COPY`, `EXPUNGE`.
2. **Không bao giờ xoá vĩnh viễn.** "Xoá" luôn là chuyển vào Thùng rác. Nếu không tìm thấy Thùng rác thì ném `IMAPError.noTrash`. **Không** được fallback sang `\Deleted` + `EXPUNGE` khi chưa có bản sao trong Thùng rác.
3. **Mật khẩu chỉ nằm trong Keychain.** Không lưu vào `UserDefaults`, không ghi log, không đưa vào thông báo lỗi.
4. **Không thêm thư viện ngoài** nếu chưa thật cần thiết. Mục tiêu là build được chỉ với Command Line Tools.
5. **Giữ Swift 5 language mode** (`swift-tools-version:5.9`). Nếu nâng lên Swift 6, phải xử lý strict concurrency trong `IMAPConnection` (các callback của `NWConnection`).
6. **Chuỗi UI và comment viết tiếng Việt**, giọng ngắn gọn. Thông báo lỗi người dùng nhìn thấy đặt trong `IMAPError.errorDescription` hoặc tại chỗ gọi.
7. Mọi thao tác ghi mới phải theo **mẫu optimistic + `perform`** trong `MailChecker` (mục 3.4). View không gọi `IMAPService` trực tiếp. Ngoại lệ duy nhất là nút "Kiểm tra kết nối" trong `AccountEditor`, vì nó chạy trên bản nháp chưa lưu.
8. Thao tác IMAP mới phải nằm trong `IMAPService` và dùng `withSession`. Tên thư mục và chuỗi trong lệnh phải đi qua `quote()`. Tập UID phải đi qua `uidSet()`.

---

## 6. Những chỗ dễ sai

| Vấn đề | Giải thích / cách xử lý |
|---|---|
| **Thêm trường vào `MailAccount`** | `MailAccount` có `init(from:)` tự viết dùng `decodeIfPresent`. **Phải** thêm trường mới vào `CodingKeys` **và** vào `init(from:)`. Nếu quên, trường đó sẽ không được lưu, hoặc (nếu xoá init) dữ liệu cũ sẽ decode lỗi và mất toàn bộ tài khoản. |
| **Dùng UID trần làm khoá** | UID chỉ duy nhất trong một thư mục. Luôn dùng `MessageKey`/`message.key`, và truyền `message.mailbox` cho mọi thao tác IMAP. |
| `"\r\n"` là **một** `Character` trong Swift | Tách dòng bằng `split(separator: "\n")` trên `String` sẽ không tách được CRLF. Hãy dùng `unicodeScalars`, như `splitMultipart` đang làm. |
| Notification crash khi chạy `swift run` | Phải chạy qua `.app` (`./build.sh`). `Notifier` đã chặn trường hợp không có bundle id. |
| Keychain hỏi quyền sau khi build | Mặc định Keychain chỉ cho đúng app tạo mục đọc và nhận diện app bằng chữ ký, nên mỗi bản build mới có thể bị hỏi lại (đã gặp dù ký bằng chứng chỉ cố định: ACL của mục tích 3–4 dòng "Always Allow" trùng đường dẫn). Vì vậy `Keychain.setPassword` tạo mục với **ACL mở** (`allowAnyApp`: danh sách app của ACL giải mã = NULL), và `openUpAccessIfNeeded` đổi ACL mục cũ tại chỗ sau lần đọc thành công đầu tiên (cờ `keychainOpenACL.v1` trong UserDefaults). Người dùng đã chọn đánh đổi này (mọi app của user đọc được mật khẩu ứng dụng). **Đừng** dùng `SecAccessCreate(…, [])` (ra ACL không tin app nào) và đừng bỏ cache trong `Keychain`. Chữ ký cố định ở `build.sh` vẫn giữ. Kiểm tra bằng `SecKeychainItemCopyAccess` + `SecACLCopyContents` (apps == nil là "mọi app"). **Đừng thử bằng `kSecUseAuthenticationUIFail` từ tiến trình con của Claude/terminal**: luôn đọc được kể cả app ký sai danh tính, kết quả vô nghĩa. |
| Không gõ hoặc dán được vào ô nhập trong cửa sổ Cài đặt | App chạy kiểu accessory nên có thể thiếu menu Edit. `ensureEditMenu()` xử lý việc này. Đừng xoá hàm đó. |
| Cửa sổ SwiftUI `Window`/`Settings` | Trên macOS 14 trở lên, `showSettingsWindow:` không còn hoạt động, còn `Window` có thể tự mở lúc khởi động. Vì vậy dự án dùng `NSWindow` tự quản lý. |
| Icon menubar bị mất | Khi menubar quá đầy hoặc bị tai thỏ che, macOS đẩy status item ra ngoài màn hình. Đây không phải lỗi code. |
| `ScrollView` trong `MenuBarExtra` không có chiều cao "lý tưởng" | Phải đo chiều cao nội dung rồi đặt `.frame(height:)`. **Không dùng PreferenceKey**: trên macOS, giá trị preference không truyền ra ngoài `ScrollView`, khiến bảng luôn kẹt ở 60px (lỗi đã gặp). Kiểm tra lại bằng chế độ demo `--snapshot` (mục 7). |
| `LOGIN` dùng quoted string | Mật khẩu có ký tự không phải ASCII sẽ lỗi. Muốn hỗ trợ thì phải gửi bằng literal `{n}` (cần xử lý continuation `+`). |
| UIDVALIDITY chưa được theo dõi | Nếu máy chủ đặt lại UID, `knownKeys` có thể bỏ sót thông báo một lần. Hiện chấp nhận điều này. |
| Race nhẹ | Một lần `check` đang chạy dở có thể vẽ lại thư vừa được đánh dấu đã đọc. Lần kiểm tra sau sẽ tự sửa. |
| Thư lớn | `fetchMessage` chỉ lấy khoảng 2 MB đầu (`BODY.PEEK[]<0.2000000>`). `splitMultipart` giữ lại phần cuối chưa có boundary đóng. |
| Lark/Feishu | Có thể cần lệnh `ID`, đã gửi sau LOGIN và bỏ qua lỗi. Mật khẩu là "authorization code" tạo trên app Lark desktop, và admin phải bật quyền dùng client bên thứ ba. |

---

## 7. Build, chạy, gỡ lỗi, phát hành

```bash
swift build -c release          # chỉ biên dịch, kiểm tra lỗi nhanh
./build.sh                      # build/MailBar.app (kiến trúc máy hiện tại, ký ad-hoc)
./build.sh install              # copy vào /Applications và mở
./build.sh dist                 # bản phát hành universal: dist/MailBar-<ver>.dmg, .zip, SHA256SUMS.txt
open build/MailBar.app          # chạy bản build
build/MailBar.app/Contents/MacOS/MailBar   # chạy trong terminal để xem print/crash log
pkill -x MailBar                # tắt app
rm build/AppIcon.icns && ./build.sh        # vẽ lại icon app sau khi sửa scripts/make-icon.swift
```

### Phiên bản & quy trình phát hành

- **Phiên bản**: file `VERSION` (SemVer `MAJOR.MINOR.PATCH`) → `CFBundleShortVersionString`. Build number `CFBundleVersion` = `yyyymmddHHMM` lúc build. Trong app đọc qua `AppInfo.version` / `AppInfo.build`. **Không** ghi cứng số phiên bản ở chỗ khác.
- **Universal**: Command Line Tools không có `xcbuild`, nên `swift build --arch arm64 --arch x86_64` **không chạy được**. `build.sh dist` build riêng `--triple arm64-apple-macosx13.0` và `--triple x86_64-apple-macosx13.0` rồi ghép bằng `lipo`.
- **Ký số** (`SIGN_IDENTITY`):
  - `local` (mặc định): chứng chỉ tự cấp cố định, tạo tự động ở lần build đầu tại `~/Library/Application Support/MailBar-Signing/` (keychain riêng `signing.keychain-db`, mật khẩu keychain trong `keychain.pass`, SHA-1 trong `identity.sha1`). `sign_local` thêm tạm keychain này vào danh sách tìm kiếm của `security` rồi khôi phục ngay, vì `codesign` không nhận `--keychain` cho identity "không tin cậy". Không bao giờ đụng keychain đăng nhập. Xoá thư mục đó = tạo chứng chỉ mới = Keychain hỏi quyền lại một lần. Có thể đổi chỗ bằng `MAILBAR_SIGNING_DIR`.
  - `-`: ad-hoc (chỉ dùng để thử nhanh; gây hỏi Keychain lại).
  - `"Developer ID Application: …"`: ký Apple, hardened runtime; thêm `NOTARY_PROFILE=<profile notarytool>` để công chứng và staple DMG. DMG chỉ được ký khi dùng Developer ID.
  - Dùng `/usr/bin/openssl` (LibreSSL) để tạo `.p12`; OpenSSL 3 của Homebrew mặc định xuất định dạng mà `security import` không đọc được (cần `-legacy`).
- **DMG** gồm `MailBar.app`, symlink `Applications` và "Đọc trước khi cài.txt" (từ `packaging/`).

Các bước phát hành:
1. Tăng số trong `VERSION`.
2. Thêm mục mới ở đầu `CHANGELOG.md`.
3. Chạy `./build.sh dist`.
4. Kiểm tra `lipo -archs`, mở thử DMG.
5. Commit, rồi `./scripts/release.sh`: đẩy lên `github.com/phudigital/mailbar` và tạo Release (dmg, zip, `SHA256SUMS.txt` riêng cho phiên bản này). Các app đời 1.4.0+ sẽ tự thấy bản mới (mục 3.7).

Xoá dữ liệu để thử lại từ đầu (**cẩn thận**: mất toàn bộ tài khoản đã cấu hình):

```bash
defaults delete com.phudigital.MailBar
```

### Chế độ demo — xem và kiểm tra giao diện không cần tài khoản thật

```bash
open build/MailBar.app --args --demo                          # chạy app với 4 tài khoản × 12 thư giả
build/MailBar.app/Contents/MacOS/MailBar --demo --accounts 5 --messages 20 --snapshot /tmp/menu.png
#   → in "snapshot 400xH (màn hình khả dụng cao …)" rồi thoát; mở /tmp/menu.png để xem bảng
build/MailBar.app/Contents/MacOS/MailBar --demo --snapshot-about /tmp/about.png   # chụp tab Giới thiệu
#   Demo: tài khoản thứ 2 bật checkSpam và có 3 thư spam.
```

Chế độ demo không kết nối mạng, không đọc Keychain, không ghi `UserDefaults` (`AccountStore.useTemporary`, `MailChecker.showDemo`). **Sau khi sửa UI của bảng menubar, hãy chụp snapshot với vài kích cỡ** (ít thư, nhiều thư) để kiểm tra chiều cao và bố cục. Lưu ý trong zsh phải truyền từng tham số riêng, không gộp vào một biến chuỗi.

### Kiểm thử

Dự án **chưa có test target**: XCTest không có sẵn khi chỉ cài Command Line Tools. Cách kiểm thử logic không phụ thuộc UI là biên dịch một harness tạm, ghép với các file nguồn thuần logic:

```bash
# main.swift: gọi MIMEDecoder / MessageParser / IMAPService rồi in kết quả
swiftc -o /tmp/t main.swift Sources/MailBar/{IMAPClient,MIMEDecoder,Models,MessageParser}.swift && /tmp/t
```

Các file trên **không phụ thuộc** SwiftUI hay AppKit (riêng `Models.swift` có import SwiftUI cho `Color`, vẫn biên dịch được). Hãy giữ chúng như vậy để còn kiểm thử được bằng cách này.

Kiểm tra kết nối nhanh mà không cần tài khoản thật: gọi `IMAPService.fetchUnread` với mật khẩu sai. Kết quả đúng là `IMAPError.authFailed` kèm thông báo từ máy chủ (đã thử với Gmail, Yandex, Lark).

**Checklist trước khi kết thúc một thay đổi:**
1. `swift build -c release` không lỗi và không thêm cảnh báo mới.
2. `./build.sh` thành công, app mở được.
3. Nếu đụng tới IMAP hoặc MIME: chạy harness với dữ liệu mẫu, gồm tiêu đề tiếng Việt, multipart, base64, quoted-printable.
4. Cập nhật `AGENTS.md` (tài liệu này) và `README.md` nếu hành vi hoặc cấu trúc thay đổi.

---

## 8. Công thức cho thay đổi thường gặp

### Thêm nhà cung cấp mail mới
1. `Models.swift`: thêm `case` vào `MailProvider`, rồi bổ sung **mọi** `switch`: `displayName`, `defaultHost`, `defaultWebURL`, `helpText`, `symbol`, `tint`. Trình biên dịch sẽ báo những chỗ còn thiếu.
2. Nếu máy chủ dùng tên Thùng rác đặc biệt mà không có cờ `\Trash`, thêm tên đó vào `IMAPService.trashNames` (tên mUTF-7 như máy chủ trả về).
3. Cập nhật bảng nhà cung cấp trong `README.md`.

### Thêm một thao tác IMAP (ví dụ: Lưu trữ, gắn sao)
1. `IMAPService`: thêm `static func xxx(account:password:uids:) async throws`, dùng `withSession`, `SELECT`, `uidSet`, `quote`. Kiểm tra `caps` nếu cần extension (`MOVE`, `UIDPLUS`…).
2. `MailChecker`: thêm hàm công khai theo mẫu optimistic: sửa `statuses`, rồi `perform(account, "<nhãn>") { pw in try await IMAPService.xxx(...) }`.
3. UI: thêm `RowAction` trong `MessageRow` (truyền closure từ `AccountSection`) và/hoặc nút trong `ReaderView.toolbar`.

### Thêm một tuỳ chọn cài đặt
1. `Prefs`: thêm hằng khoá và giá trị mặc định trong `registerDefaults()`.
2. `GeneralSettingsView`: thêm `@AppStorage(Prefs.xxx)` và control tương ứng.
3. Nơi dùng giá trị: View đọc qua `@AppStorage`; code ngoài View đọc qua `UserDefaults.standard`.

### Thêm trường cho tài khoản
1. Khai báo trường có giá trị mặc định trong `MailAccount`.
2. Thêm vào `CodingKeys` và thêm dòng `decodeIfPresent` trong `init(from:)`.
3. Thêm control trong `AccountEditor` (xem `checkSpam` làm mẫu). Nếu trường ảnh hưởng tới việc kiểm tra thư, `save()` đã gọi `checker.reset`.

### Theo dõi thêm một thư mục (giống Spam)
Làm theo mẫu `checkSpam`:
- thêm cờ trong `MailAccount`;
- thêm danh sách tên dự phòng và cờ SPECIAL-USE cho `findFolder`;
- gọi `fetchUnreadHeaders` trong `fetchUnread`;
- đánh dấu `MailMessage` bằng một thuộc tính;
- thêm nhóm hiển thị trong `AccountSection`.

### Đổi giao diện danh sách hoặc trình đọc
- Kích thước: `MenuContentView.panelWidth` (400, dùng chung cho danh sách và trình đọc) và `maxHeight`. Không phóng to bảng khi đọc thư; đó là yêu cầu của người dùng.
- Hàng thư: `MessageRow`. Nút khi rê chuột: `RowAction`.
- Trình đọc: `ReaderView` (thanh công cụ, phần header, thanh chặn ảnh).

---

## 9. Giới hạn hiện tại & hướng phát triển

- Chỉ theo dõi một hộp thư cho mỗi tài khoản (mặc định `INBOX`). Với Gmail, con số bao gồm mọi tab (Quảng cáo, Mạng xã hội…).
- Spam: chỉ hiển thị tối đa 20 thư chưa đọc mới nhất, không gửi thông báo.
- Không dùng IMAP IDLE (push); kiểm tra theo chu kỳ, tối thiểu 60 giây.
- Không hỗ trợ OAuth2 (XOAUTH2), chỉ mật khẩu ứng dụng. Outlook/Microsoft 365 đã tắt đăng nhập bằng mật khẩu nên chưa dùng được.
- Không hỗ trợ STARTTLS (cổng 143). Chỉ có SSL/TLS trực tiếp hoặc kết nối thường.
- Trình đọc thư chưa hiển thị ảnh nhúng `cid:`, chưa tải được tệp đính kèm, chưa có trả lời/soạn thư (SMTP).
- Chưa có test target, chưa có localization. Tự cập nhật chỉ dùng được giữa các bản cùng chữ ký (mục 3.7), chưa có kênh beta, chưa có công chứng Apple.

Gợi ý ưu tiên tiếp theo: Archive cho Gmail (`UID MOVE` vào thư mục có cờ `\All`), IMAP IDLE cho tài khoản chính, ký Developer ID + notarize.
