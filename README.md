# MailBar

App nhỏ chạy trên menubar macOS, kiểm tra thư chưa đọc của Gmail, Lark, Feishu, Yandex hoặc bất kỳ máy chủ IMAP nào.

- Icon phong bì trên menubar, số thư chưa đọc hiện bằng badge nhỏ ở góc dưới bên phải.
- Hộp xổ xuống cao gần bằng màn hình, mỗi tài khoản hiện tới 50 thư chưa đọc mới nhất.
- Rê chuột vào một thư sẽ hiện các nút: **đánh dấu đã đọc**, **xoá** (chuyển vào Thùng rác) và **mở trên web**.
- Mỗi tài khoản có menu `⋯`: mở hộp thư trên web, đánh dấu tất cả đã đọc, kiểm tra lại.
- Có thể **kiểm tra cả thư mục Spam**, bật/tắt riêng cho từng tài khoản. Thư spam hiện thành nhóm màu cam và có nút "Không phải spam".
- Thư rác ở Hộp thư đến: bấm icon **bát giác chấm than** cạnh nút xoá (trong hàng thư hoặc khi đang đọc) để chuyển vào thư mục Spam.
- Bấm vào một thư để **đọc ngay trong hộp**:
  - Hiện người gửi, người nhận, Cc và danh sách tệp đính kèm.
  - JavaScript bị tắt, hình ảnh từ xa bị chặn cho tới khi bấm "Tải hình ảnh".
  - Có nút đã đọc/chưa đọc, xoá và mở web.
  - Có thể tự đánh dấu đã đọc khi mở thư (bật/tắt trong Cài đặt → Chung).
  - Nội dung thư mới được **tải sẵn** vào cache tạm (`~/Library/Caches/com.phudigital.MailBar`) nên bấm vào là xem ngay; file tự xoá khi thư đã đọc/bị xoá. Tắt được trong Cài đặt → Chung.
- Có thông báo macOS khi thư mới đến. Bấm vào thông báo sẽ mở webmail.
- Việc kiểm tra định kỳ chỉ đọc hộp thư (`EXAMINE` + `BODY.PEEK`). App chỉ thay đổi cờ của thư khi bạn bấm thao tác.
- Mật khẩu ứng dụng được lưu trong Keychain của macOS.

## Cài đặt

**Từ bộ cài:** mở `MailBar-<phiên bản>.dmg`, kéo MailBar vào Applications.

Bản này chưa được Apple công chứng, nên lần đầu mở trên máy khác sẽ bị chặn. Cách cho phép:
- **macOS 15 trở lên:** System Settings → Privacy & Security → **Open Anyway**.
- **macOS 13–14:** chuột phải vào app → **Open**.

Chi tiết nằm trong file "Đọc trước khi cài.txt" đi kèm DMG.

**Từ mã nguồn** (cần macOS 13+ và Xcode Command Line Tools):

```bash
./build.sh            # build/MailBar.app (kiến trúc máy hiện tại)
./build.sh install    # build, copy vào /Applications và mở
./build.sh dist       # bản phát hành universal → dist/MailBar-<version>.dmg + .zip + SHA256SUMS.txt
```

## Phiên bản

- Số phiên bản nằm trong file `VERSION`; lịch sử thay đổi ở `CHANGELOG.md`.
- Build number được lấy tự động theo thời điểm build.
- Xem phiên bản trong app: chân bảng menubar, hoặc **Cài đặt → Giới thiệu**.

## Thêm tài khoản

Mở **Cài đặt… → Tài khoản → +**, rồi chọn nhà cung cấp. Máy chủ và địa chỉ web sẽ được điền sẵn. Sau đó nhập email và mật khẩu ứng dụng, bấm **Kiểm tra kết nối** rồi **Lưu**.

| Nhà cung cấp | IMAP | Cách lấy mật khẩu ứng dụng |
|---|---|---|
| Gmail / Workspace | `imap.gmail.com:993` | Bật xác minh 2 bước → myaccount.google.com/apppasswords |
| Lark | `imap.larksuite.com:993` | App Lark desktop → Settings → Email → Third-party email client login → Generate (admin phải cho phép) |
| Feishu | `imap.feishu.cn:993` | Settings → Third-party client |
| Yandex | `imap.yandex.com:993` | Bật IMAP trong cài đặt mail → id.yandex.com/security/app-passwords |

SMTP chỉ dùng để **gửi** thư, nên app này không cần SMTP.

## Ghi chú

- Lần kiểm tra đầu tiên sau khi mở app sẽ không bắn thông báo. Từ lần sau, chỉ thư mới đến mới được thông báo.
- Lần đầu chạy, macOS hỏi quyền truy cập Keychain: chọn **Always Allow** (nhập mật khẩu máy Mac). App được ký bằng một chứng chỉ cố định tạo trên máy build, nên sau đó build lại hoặc cập nhật sẽ không bị hỏi nữa.
- Nếu không thấy icon, có thể menubar đã quá đầy hoặc icon bị khuất sau "tai thỏ". Hãy bớt icon khác, hoặc giữ ⌘ rồi kéo để sắp xếp lại.

## Cập nhật

Từ bản 1.4.0, MailBar tự kiểm tra bản mới trên [GitHub Releases](https://github.com/phudigital/mailbar/releases). Khi có bản mới, bảng menubar hiện thanh **Có bản mới** với nút **Cập nhật**; app tự tải, kiểm tra mã SHA-256 và chữ ký, thay chính nó rồi mở lại. Tắt/bật hoặc kiểm tra ngay trong Cài đặt → Chung → Cập nhật. Bản cũ hơn 1.4.0 cần cài tay một lần.
