# workflow-next-step.md — việc đã làm & việc có thể làm tiếp

Nhật ký công việc sống của dự án MailBar: **đã xong gì, còn gì, và bài học khi làm**. AI agent đọc file này (cùng `AGENTS.md`) trước khi bắt đầu và **cập nhật nó khi kết thúc** (quy định ở `AGENTS.md` mục 10).
Lịch sử phát hành chi tiết nằm ở `CHANGELOG.md`; file này tập trung vào *việc kế tiếp* và *ngữ cảnh để làm tiếp*.

Cập nhật lần cuối: 2026-10-10, sau khi phát hành **2.0.0**.

---

## 1. Đã xong (theo phiên bản)

| Phiên bản | Nội dung chính | File chính |
|---|---|---|
| 1.2.0 | **Tải sẵn nội dung thư mới** vào cache tạm `~/Library/Caches/com.phudigital.MailBar/Messages/`; mở thư là xem ngay. Tự dọn khi thư đã đọc/xoá. Công tắc ở Cài đặt → Chung. Sửa lỗi biên dịch có sẵn (`HTMLText.decodeEntities`). | `MessageCache.swift`, `IMAPService.prefetchMessages`, `MailChecker.prefetch` |
| 1.2.1 | **Hết hỏi quyền Keychain** mỗi bản build mới: mục Keychain lưu với ACL "mọi app được đọc" (người dùng đã chọn đánh đổi này); mục cũ được đổi quyền tại chỗ. | `Storage.swift` (`allowAnyApp`, `openUpAccessIfNeeded`) |
| 1.3.0 | **Đánh dấu spam**: icon bát giác chấm than cạnh nút xoá (hàng thư + trình đọc), chuyển vào thư mục Spam. | `IMAPService.moveToSpam`, `MailChecker.markSpam`, `MenuContentView.swift` |
| 1.4.0 | **Tự cập nhật** qua GitHub Releases `phudigital/mailbar` (SHA-256 + kiểm tra chữ ký cùng chứng chỉ + script thay app). Repo public, `scripts/release.sh`. | `Updater.swift`, `scripts/release.sh` |
| 2.0.0 | **Tổng rà soát đa agent** (9 reviewer × 2 phản biện) và sửa: crash literal IMAP âm, WebView (scheme, fail-closed, data store tạm), hiệu năng trình đọc, lỗi Spam không phá cả lần kiểm tra, chia đợt UID, epoch chống ghi đè, retry mạng, `movedBack`, Keychain báo lỗi, link Gmail có `+&=#`, banner cập nhật, cảnh báo tắt TLS, **nối lại OTP/link xác minh vào trình đọc**. | `IMAPClient.swift`, `MailChecker.swift`, `MailWebView.swift`, `MessageParser.swift`, `MenuContentView.swift` |

Ngoài ra đã có: repo công khai <https://github.com/phudigital/mailbar>, mỗi bản phát hành có `dmg`, `zip`, `SHA256SUMS.txt`.

---

## 2. Việc có thể làm tiếp

Ưu tiên theo giá trị / rủi ro. "Xác nhận" = đã được 2 agent phản biện độc lập đồng ý là có thật trong cuộc rà soát của 2.0.0.

### 2.1 Lỗi đã xác nhận nhưng chưa sửa (gợi ý gom vào 2.1.0)

| Mức | Vị trí | Vấn đề | Hướng sửa |
|---|---|---|---|
| Trung bình | `MIMEDecoder.swift` `address`/`displayName` (~dòng 68–87) | **Header `From:` giả địa chỉ**: lấy `<…>` đầu tiên sau khi đã giải mã RFC 2047, nên tên hiển thị chứa `<fake@x>` đánh lừa người đọc. | Tách trên header **thô** trước khi giải mã, lấy cặp `<…>` cuối ngoài dấu nháy/comment/encoded-word; một helper dùng chung cho cả hai hàm; ở `ReaderView.headerInfo` tô cam khi tên chứa `@` khác địa chỉ thật. Thêm ca harness: `"A <x@y.com>" <real@z.com>`, encoded-word chứa `<…>`, `"Smith <Sales>" <a@b.com>`. |
| Trung bình | `MIMEDecoder.string(from:charset:)` (~dòng 152) | Giải mã charset nghiêm ngặt, thất bại thì rơi về UTF-8 lossy: thư `gb2312` (chứa GBK mở rộng) thành cả trang U+FFFD; `iso-8859-1` lẫn nháy cong windows-1252. | Chuẩn hoá bí danh (gb2312/gbk→gb18030; latin1/us-ascii→windows-1252), thử strict → cắt ≤3 byte cuối (thư cắt ở 2 MB) → UTF-8 strict → isoLatin1 → lossy. |
| Trung bình | `MessageParser.swift` `HTMLText.named` (~dòng 188) | Bảng entity quá nhỏ: `&agrave; &eacute; &zwnj;`… hiện nguyên chữ. | Mở rộng bảng (chữ Latin có dấu, zwnj/zwj, laquo/raquo, euro, …). |
| Thấp | `MessageParser.swift` HTML→text | Không ngắt giữa ô bảng (`</td>`), nhãn và giá trị dính liền. | Thêm `</t[dh]>` → khoảng trắng/tab. |
| Thấp | `MessageParser.swift` (~dòng 265) | RFC 2231 nối đoạn `filename*0*=`, `filename*1*=` không được ghép. | Ghép theo chỉ số. |
| Thấp | `MIMEDecoder.swift` `parseDate` (~dòng 110) | Đổi `dateFormat` của `DateFormatter` dùng chung từ nhiều luồng (race); chưa đặt calendar gregorian. | Dựng sẵn `static let dateFormatters: [DateFormatter]` (en_US_POSIX, gregorian), chỉ đọc. |
| Trung bình | `MenuContentView.swift` (~dòng 14–28) | `ReaderView`/`WKWebView` không được giải phóng khi bảng menubar đóng; WebKit nằm lại bộ nhớ. | Đặt lại `reading = nil` khi bảng ẩn **nhưng** không làm mất thư khi người dùng chỉ chuyển ứng dụng ngắn (cần thử kỹ). |
| Trung bình | `Updater.swift` `launchInstaller` (~dòng 291–297) | `install.sh` lỗi thì im lặng (app mở lại bản cũ, không báo, bỏ lại thư mục tạm); xoá bản cũ ngay sau `open` bản mới, không rollback nếu bản mới không khởi động. | Ghi log/tệp trạng thái đọc ở lần mở sau; giữ bản cũ tới khi bản mới báo "đã chạy ổn"; kiểm `LSMinimumSystemVersion` và kiến trúc trước khi cài. |
| Thấp | `Updater.swift` (~dòng 201, 221, 291) | Lỗi giữa chừng không xoá thư mục tạm; tải sums/zip không kiểm HTTP status/hạn tổng thời gian; hết 30 giây chờ vẫn thay bundle khi app chưa thoát. | Dọn thư mục tạm khi lỗi; kiểm `HTTPURLResponse`; `timeoutIntervalForResource`. |
| Thấp | `MailChecker.swift` prefetch (~dòng 274) | Prefetch đang chạy vẫn ghi cache sau khi tài khoản bị xoá/tắt; ghi cache lỗi (đĩa đầy) khiến mỗi chu kỳ tải lại 20 thư. | Kiểm epoch trước khi ghi; nhớ khoá đã lỗi trong phiên. |
| Thấp | `MenuContentView.swift` `MessageRow` | Hàng thư và nút thao tác chỉ dùng được bằng chuột (không a11y/bàn phím); hover làm hàng đổi bề ngang chữ. | `accessibilityLabel`/`accessibilityAction`; giữ bề rộng cố định cho vùng ngày/nút. |
| Thấp | `SettingsView.swift` `AccountEditor.save` | Mọi lần Lưu đều `checker.reset`, kể cả khi chỉ đổi tên/URL web. | Chỉ reset khi host/cổng/TLS/user/mật khẩu/mailbox/checkSpam đổi. |
| Thấp | `Notifier.swift` | Chưa được cấp quyền thông báo thì thất bại im lặng, Cài đặt không cảnh báo. | Hiện trạng thái quyền trong Cài đặt → Chung kèm nút mở System Settings. |

### 2.2 Phát hiện chưa kịp phản biện (mảng build/tài liệu — workflow bị dừng giữa chừng)

Cần tự kiểm chứng trước khi sửa:
- `build.sh` mục `ensure_local_identity`: `dist` có thể âm thầm **tạo chứng chỉ ký mới** (khi thư mục `~/Library/Application Support/MailBar-Signing/` mất) → bản phát hành mới **không tự cập nhật được** từ bản cũ (khác chữ ký). `release.sh` nên chặn: so `identity.sha1` với chứng chỉ của bản đã phát hành trước (hoặc in cảnh báo lớn).
- `build.sh` tạo chứng chỉ không dọn khoá riêng khi lỗi giữa chừng và có thể không khôi phục danh sách keychain.
- `release.sh`: chưa kiểm artifact có mới hơn mã nguồn / `VERSION` khớp bản đã build.
- `packaging/Doc-truoc-khi-cai.txt`: hướng dẫn gỡ cài đặt chưa nhắc xoá cache `~/Library/Caches/com.phudigital.MailBar` (chứa nội dung thư chưa đọc dạng thô).
- `README.md`: bản tự build từ mã nguồn (ký ad-hoc/chứng chỉ khác) luôn thấy banner cập nhật nhưng không bao giờ cập nhật được (thiếu giải thích).
- `AGENTS.md`/`README.md` chưa mô tả đầy đủ `SmartActions.swift` (mục 4 `AGENTS.md` chưa có phần riêng).

### 2.3 Hướng phát triển (tính năng)

1. **Ký Developer ID + notarize** (cần tài khoản Apple Developer): gỡ hộp thoại Gatekeeper, chữ ký ổn định cho Keychain và tự cập nhật; kèm `NOTARY_PROFILE` trong `build.sh`. Lưu ý: đổi chứng chỉ ký = người dùng cài tay một lần (xem `AGENTS.md` mục 3.7).
2. **Archive cho Gmail**: `UID MOVE` vào thư mục có cờ `\All`, thêm `RowAction` theo công thức "Thêm một thao tác IMAP" (`AGENTS.md` mục 8).
3. **IMAP IDLE** cho tài khoản chính (push thay cho kiểm tra theo chu kỳ; giữ chu kỳ làm dự phòng).
4. **Test target**: hiện chưa có XCTest (chỉ Command Line Tools). Cân nhắc gói các harness trong `AGENTS.md` mục 7 thành script chạy được (`scripts/test.sh`) với dữ liệu mẫu đã dùng ở 2.0.0 (OTP, strip HTML 3 triệu ký tự, `uidChunks`, cache).
5. **Tệp đính kèm**: tải/lưu file, ảnh nhúng `cid:` trong trình đọc.
6. **Soạn/trả lời thư (SMTP)** — lớn; chỉ làm nếu thật sự cần.
7. **OAuth2 (XOAUTH2)** để dùng Outlook/Microsoft 365.
8. **Localization** (hiện chuỗi tiếng Việt viết thẳng trong code).
9. **Kênh beta** cho tự cập nhật (release `prerelease` + tuỳ chọn trong Cài đặt).
10. Các cảnh báo "deprecated" (7 cái) ở `Storage.swift` do API ACL Keychain cũ — chưa có thay thế cho keychain đăng nhập; giữ nguyên trừ khi chuyển sang cách lưu khác.

---

## 3. Bài học & lưu ý khi làm tiếp

- **Đừng thử Keychain bằng `kSecUseAuthenticationUIFail` từ tiến trình con của Claude/terminal**: luôn đọc được kể cả app ký sai danh tính → kết quả vô nghĩa. Kiểm tra ACL bằng `SecKeychainItemCopyAccess` + `SecACLCopyContents` (`apps == nil` là "mọi app"). `SecAccessCreate(…, [])` KHÔNG cho ra "mọi app" (ra "không tin app nào"); phải `SecACLSetContents(acl, nil, …)`.
- **Thử tự cập nhật đầu-cuối**: copy `build/MailBar.app` ra thư mục tạm, hạ `CFBundleShortVersionString` bằng `PlistBuddy`, ký lại **cùng chứng chỉ** (`sign_local` trong `build.sh`), chạy `MailBar --update-selftest`. Bản ký ad-hoc phải bị từ chối ("không cùng chữ ký").
- **Nhiều sub-agent cùng sửa code**: chia theo **file rời nhau**, cấm chạy `swift build` song song (tranh chấp `.build`; chỉ `swiftc -typecheck Sources/MailBar/*.swift`), cấm `git commit`. Khi người dùng dừng giữa chừng, các sửa dở vẫn nằm trên đĩa: luôn `git diff` + build kiểm tra trước khi phát hành.
- **Workflow rà soát**: 9 mảng (imap, mime, state, ui, security, updater, smart, lifecycle, build), mỗi phát hiện 2 verifier (góc "có thật không" + góc "sửa có an toàn không"). Kết quả lưu trong `journal.jsonl` của thư mục workflow; phát hiện chỉ "xác nhận" khi cả hai verifier cho `real = true`. Tuyên bố của reviewer có thể sai: vd "ReDoS trong `SmartActions`" **không tái hiện** (0,01 s với 60 KB) — luôn đo trước khi sửa.
- `swift build` không được thêm cảnh báo mới ngoài nhóm Keychain deprecated; harness ghép toàn bộ `Sources/MailBar` trừ `MailBarApp.swift` (có `@main`).
- Chế độ demo: `DemoMode` phải đưa **mọi** `environmentObject` mà `MenuContentView` cần (đã từng thiếu `Updater` → crash khi `--snapshot`). Thêm `environmentObject` mới ở `MailBarApp` thì thêm cả ở `DemoMode.snapshot`.
- Phát hành: `VERSION` → `CHANGELOG.md` → `./build.sh dist` → kiểm tra (`lipo -archs`, `codesign --verify`, chạy `--demo`) → commit → `./scripts/release.sh`. Phát hành **chỉ khi người dùng yêu cầu**; repo là public nên đừng đưa dữ liệu nhạy cảm vào commit.
