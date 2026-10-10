# Nhật ký thay đổi

Định dạng theo [Keep a Changelog](https://keepachangelog.com/vi/1.1.0/), phiên bản theo [Semantic Versioning](https://semver.org/lang/vi/):
`MAJOR.MINOR.PATCH`. Tăng MAJOR khi thay đổi lớn hoặc không tương thích dữ liệu, MINOR khi thêm tính năng, PATCH khi sửa lỗi.

## [2.0.0] — 2026-10-10

Bản tổng rà soát: 9 reviewer chạy song song, mỗi phát hiện được 2 agent phản biện độc lập; các lỗi dưới đây đều được xác nhận trên code thật.

### Sửa lỗi nghiêm trọng / bảo mật
- **Crash khi máy chủ gửi độ dài literal IMAP âm**, và phình RAM khi literal/dòng quá lớn: giờ từ chối literal > 32 MB, dòng > 1 MB, chỉ nhận chữ số.
- **Link trong thư**: chỉ mở `http`/`https`/`mailto` bằng ứng dụng mặc định (trước đây mở mọi scheme); chặn chuyển trang ngay trong bảng (meta refresh, form); chặn nội dung từ xa giờ **fail-closed** (không dựng được bộ chặn thì không tải thư); WebView không còn lưu cookie/cache lên đĩa.
- **Trình đọc không còn đơ** với thư HTML lớn: `plainText`/`hasRemoteContent` tính một lần lúc phân tích (ngoài main thread) thay vì chạy regex mỗi lần vẽ; HTML > 1,5 triệu ký tự bị cắt trước khi bỏ thẻ; thư văn bản > 200.000 ký tự được rút gọn. HTML chỉ có ảnh tự chuyển sang chế độ HTML thay vì trang trắng.

### Sửa lỗi
- **Lỗi thư mục Spam không còn làm hỏng cả lần kiểm tra** (mất thông báo Hộp thư đến): hạ thành ghi chú Spam.
- "Đánh dấu tất cả đã đọc", xoá, chuyển spam với hàng nghìn thư: chia đợt ~400 UID mỗi lệnh (máy chủ hay từ chối dòng quá dài).
- Đổi/sửa tài khoản rồi lưu: lần kiểm tra cũ đang chạy dở không còn ghi đè trạng thái mới (thêm "thế hệ" cấu hình).
- "Không phải spam" không còn gây thông báo "thư mới" giả cho thư vừa chuyển về.
- **Lỗi mạng tạm thời** (Wi-Fi chưa lên lại sau khi thức dậy): tự thử lại sau 15 giây và 45 giây trước khi báo lỗi, thay vì kẹt lỗi tới hết chu kỳ.
- Đóng trình đọc trong lúc thư đang tải không còn tự đánh dấu đã đọc.
- Keychain: báo lỗi khi không lưu được mật khẩu (trước đây im lặng báo đã lưu); chỉ coi là "Deny" khi người dùng thật sự từ chối, lỗi tạm thì lần sau thử lại.
- Mở Gmail đúng tài khoản với email chứa `+`, `&`, `=`, `#`.
- Banner cập nhật trong bảng menubar hiện tiến trình khi đang cài và báo lỗi (nút Thử lại) thay vì biến mất.
- Lệnh `ID` gửi đúng phiên bản app thay vì "1.0".
- Cảnh báo cam khi tắt SSL/TLS cho một tài khoản.

### Tính năng được nối lại
- **Nhận diện mã xác minh (OTP) và link xác minh trong trình đọc** (ghi trong 1.1.0 nhưng phần giao diện bị thiếu trong mã nguồn): khung đầu thư có nút **Sao chép** mã (đánh dấu concealed cho clipboard), **Mở** và **Sao chép link** kèm tên miền đích; cảnh báo với thư Spam; không bao giờ tự mở link. Chạy ngoài main thread. Công tắc ở Cài đặt → Chung.

### Ghi chú
- Các phát hiện còn lại (độ chính xác header `From:` giả, bảng charset gb2312/windows-1252, entity HTML hiếm, RFC 2231 nối đoạn, `parseDate` dùng chung formatter, giải phóng WKWebView khi bảng đóng, cập nhật rollback…) đã được xác nhận nhưng chưa sửa; sẽ làm ở bản sau.

## [1.4.0] — 2026-10-10

### Tính năng
- **Tự cập nhật.** App tự hỏi GitHub Releases của `phudigital/mailbar` sau 20 giây khi mở và mỗi 24 giờ. Có bản mới thì hiện thanh "Có bản mới x.y.z" trong bảng menubar (nút **Cập nhật** / **Chi tiết**) và gửi một thông báo cho mỗi phiên bản. Bấm Cập nhật: app tải zip, đối chiếu SHA-256 với `SHA256SUMS.txt`, kiểm tra bản mới **cùng identifier và cùng chứng chỉ ký** với bản đang chạy, rồi tự thay chính nó và mở lại. Lỗi ở bước nào thì giữ nguyên bản cũ.
  - Chỉ chấp nhận link tải nằm trong đúng repo `phudigital/mailbar` trên github.com. Không dùng thư viện ngoài, không cần token.
  - Cài đặt → Chung → **Cập nhật**: bật/tắt kiểm tra tự động, nút "Kiểm tra ngay", trạng thái.
  - Cần quyền ghi vào thư mục chứa app (như `/Applications`); không có thì báo và để bạn cài tay.
  - Bản 1.3.0 trở về trước chưa có tính năng này: cài 1.4.0 bằng tay một lần.
- Thêm `scripts/release.sh` để tạo GitHub Release (zip, dmg, `SHA256SUMS.txt`, ghi chú lấy từ CHANGELOG).

## [1.3.0] — 2026-10-10

### Tính năng
- **Đánh dấu spam**: nút icon (hình bát giác chấm than) ngay cạnh nút Xoá, trong hàng thư (hiện khi rê chuột) và trên thanh công cụ của trình đọc. Thư được chuyển vào thư mục Spam của máy chủ (tìm theo cờ `\Junk` hoặc tên quen thuộc, kể cả Gmail/Lark/Feishu); không có thư mục Spam thì báo lỗi và không làm gì. Không xoá vĩnh viễn. Nút chỉ hiện với thư ở Hộp thư đến; thư đã ở Spam vẫn có "Không phải spam".
  - Nếu tài khoản bật theo dõi Spam, thư hiện ở nhóm Spam sau lần kiểm tra kế tiếp.

## [1.2.1] — 2026-10-10

### Sửa lỗi
- **Hết hỏi quyền Keychain mỗi lần chạy bản build mới.** Mật khẩu ứng dụng giờ được lưu với ACL "mọi app được đọc" (danh sách app tin cậy = NULL) thay vì gắn với chữ ký của đúng một bản build. Mục Keychain cũ tự được đổi quyền tại chỗ (không xoá) ở lần đọc thành công đầu tiên, nên sau bản này có thể còn hỏi thêm **một** lần cuối.
  - Đánh đổi (đã chọn có chủ đích): app nào chạy dưới tài khoản người dùng cũng đọc được các mật khẩu ứng dụng này mà không bị hỏi. Đây là mật khẩu ứng dụng phạm vi hẹp, thu hồi được ở nhà cung cấp mail.

## [1.2.0] — 2026-10-10

### Tính năng
- **Tải sẵn nội dung thư mới.** Khi kiểm tra thấy thư chưa đọc, app tải luôn nội dung (chỉ đọc, không đổi trạng thái đã đọc) và lưu tạm trong thư mục cache `~/Library/Caches/com.phudigital.MailBar/Messages/`. Bấm vào thư là hiện ngay, không phải chờ kết nối máy chủ.
  - Chỉ tải sẵn thư chưa đọc, tối đa 20 thư mới nhất mỗi tài khoản mỗi lượt, một phiên IMAP cho cả lượt. Thông báo thư mới vẫn gửi ngay, không phải chờ tải xong.
  - Cache tự dọn: file của thư đã đọc/đã xoá bị xoá sau mỗi lần kiểm tra; xoá hoặc tắt tài khoản, sửa tài khoản, hoặc tắt tuỳ chọn thì xoá cache tương ứng.
  - Riêng tư: thư mục cache chỉ chủ máy đọc được (0700/0600). Mở thư mà Message-ID không khớp với cache (máy chủ cấp lại UID) thì bỏ cache và tải lại.
  - Bật/tắt trong Cài đặt → Chung ("Tải sẵn nội dung thư mới"), mặc định bật.

### Sửa lỗi
- Sửa lỗi biên dịch: `SmartActions.swift` gọi `HTMLText.decodeEntities` nhưng hàm này đã bị gộp vào `HTMLText.strip`; tách lại thành hàm riêng.

## [1.1.0] — 2026-10-09

### Tính năng
- **Nhận diện mã xác minh và link xác minh** trong trình đọc thư. Thư có mã OTP (vd. "Mã xác minh của bạn là 482 910", "G-482910 is your Google verification code") hiện ô mã kèm nút **Sao chép**; thư có link xác minh email, đăng nhập bằng link hoặc đặt lại mật khẩu hiện nút **Mở** và **Sao chép link** kèm tên miền đích. Nội dung thư vẫn hiển thị như cũ.
  - Hiểu tiếng Anh, Việt (có dấu hoặc không dấu), Trung, Nga. Chỉ nhận khi có từ khoá rõ ràng, tránh nhầm số đơn hàng, số điện thoại, mã khuyến mãi, mã đặt chỗ.
  - Mã được đánh dấu "concealed" trên clipboard để các trình quản lý lịch sử clipboard không lưu lại.
  - Link chỉ mở khi người dùng bấm, không bao giờ tự tải. Thư trong Spam có cảnh báo.
  - Bật/tắt trong Cài đặt → Chung ("Nhận diện mã xác minh và link xác minh").
  - Tab "Giới thiệu" có thêm một bước hướng dẫn tính năng này.
- Chế độ demo: bấm vào thư demo mở thư mẫu (có sẵn 3 thư mẫu mã/link xác minh), thao tác trong demo chỉ cập nhật cục bộ. Thêm `--snapshot-reader` và `--dark` để chụp trình đọc / giao diện tối.

## [1.0.0] — 2026-10-09

Bản phát hành đầu tiên.

### Tính năng
- Icon phong bì trên menubar, số thư chưa đọc hiện bằng badge nhỏ đè lên góc dưới bên phải (icon chỉ rộng hơn phong bì 1pt).
- Theo dõi nhiều tài khoản IMAP, có sẵn cấu hình cho Gmail / Google Workspace, Lark, Feishu, Yandex và IMAP tuỳ chỉnh.
- Đăng nhập bằng mật khẩu ứng dụng, lưu trong Keychain. Nút "Kiểm tra kết nối" khi thêm tài khoản.
- Bảng menubar tự giãn theo số thư (tối đa gần hết chiều cao màn hình) và cuộn được.
- Tuỳ chọn **kiểm tra thư mục Spam** riêng cho từng tài khoản. Thư mục được tự tìm theo cờ `\Junk` hoặc theo tên quen thuộc. Thư spam hiện thành nhóm riêng, được tính vào số trên icon nhưng không gửi thông báo, và có nút "Không phải spam".
- Thao tác nhanh trên từng thư: đánh dấu đã đọc, chuyển vào Thùng rác, mở trên web. Mỗi tài khoản có lệnh "Đánh dấu tất cả đã đọc".
- Đọc thư ngay trong bảng: tắt JavaScript, chặn hình ảnh từ xa, tự thu nhỏ thư HTML cho vừa bảng.
- Thông báo macOS khi có thư mới. Bấm vào thông báo để mở webmail (Gmail mở đúng thư).
- Cài đặt: tần suất kiểm tra, thông báo/âm thanh, tự đánh dấu đã đọc khi mở thư, tự khởi động cùng macOS.
- Tab "Giới thiệu" có phiên bản, hướng dẫn nhanh và link lấy mật khẩu ứng dụng. Nút `?` và số phiên bản ở chân bảng menubar.
- Dữ liệu tài khoản đọc được cả khi thiếu trường (`decodeIfPresent`): nâng cấp phiên bản không làm mất tài khoản.
- Chế độ demo (`--demo`, `--snapshot`) để xem trước giao diện.
- Đóng gói `.dmg` và `.zip` universal (Apple Silicon + Intel).
- Ký app bằng chứng chỉ tự cấp cố định trên máy build, nên macOS chỉ hỏi quyền Keychain một lần, không hỏi lại sau mỗi lần build/cập nhật.
