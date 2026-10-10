# MailBar

App nhỏ chạy trên menubar macOS, kiểm tra thư chưa đọc của Gmail, Lark, Feishu, Yandex hoặc bất kỳ máy chủ IMAP nào.

**Phiên bản mới nhất: 2.0.0** · macOS 13+ · không dùng thư viện ngoài · [Tải về](https://github.com/phudigital/mailbar/releases/latest) · [Lịch sử thay đổi](CHANGELOG.md)

- Icon phong bì trên menubar, số thư chưa đọc hiện bằng badge nhỏ ở góc dưới bên phải.
- Hộp xổ xuống cao gần bằng màn hình, mỗi tài khoản hiện tới 50 thư chưa đọc mới nhất.
- Rê chuột vào một thư sẽ hiện các nút: **đánh dấu đã đọc**, **xoá** (chuyển vào Thùng rác) và **mở trên web**.
- Mỗi tài khoản có menu `⋯`: mở hộp thư trên web, đánh dấu tất cả đã đọc, kiểm tra lại.
- Có thể **kiểm tra cả thư mục Spam**, bật/tắt riêng cho từng tài khoản. Thư spam hiện thành nhóm màu cam và có nút "Không phải spam".
- Thư rác ở Hộp thư đến: bấm icon **bát giác chấm than** cạnh nút xoá (trong hàng thư hoặc khi đang đọc) để chuyển vào thư mục Spam.
- Bấm vào một thư để **đọc ngay trong hộp**:
  - Hiện người gửi, người nhận, Cc và danh sách tệp đính kèm.
  - JavaScript bị tắt, hình ảnh từ xa bị chặn cho tới khi bấm "Tải hình ảnh". Link trong thư chỉ mở khi là `http`/`https`/`mailto`; không lưu cookie hay cache của nội dung từ xa.
  - **Nhận diện mã xác minh (OTP) và link xác minh / đăng nhập / đặt lại mật khẩu**: khung đầu thư có nút **Sao chép** mã, **Mở** hoặc **Sao chép link** kèm tên miền đích. App không bao giờ tự mở link. Tắt được trong Cài đặt → Chung.
  - Có nút đã đọc/chưa đọc, xoá và mở web.
  - Có thể tự đánh dấu đã đọc khi mở thư (bật/tắt trong Cài đặt → Chung).
  - Nội dung thư mới được **tải sẵn** vào cache tạm (`~/Library/Caches/com.phudigital.MailBar`) nên bấm vào là xem ngay; file tự xoá khi thư đã đọc/bị xoá. Tắt được trong Cài đặt → Chung.
- Có thông báo macOS khi thư mới đến. Bấm vào thông báo sẽ mở webmail.
- Mất mạng tạm thời (ví dụ Wi-Fi chưa lên lại sau khi máy thức dậy) thì app tự thử lại sau 15 và 45 giây trước khi báo lỗi.
- **Tự cập nhật** qua GitHub Releases (xem mục [Cập nhật](#cập-nhật)).
- Việc kiểm tra định kỳ chỉ đọc hộp thư (`EXAMINE` + `BODY.PEEK`). App chỉ thay đổi cờ của thư khi bạn bấm thao tác.
- Mật khẩu ứng dụng được lưu trong Keychain của macOS (xem [ghi chú về quyền Keychain](#ghi-chú)).

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
- Lần đầu chạy (hoặc khi nâng cấp từ bản cũ), macOS có thể hỏi quyền truy cập Keychain: chọn **Always Allow** (nhập mật khẩu máy Mac). Từ bản 1.2.1, mật khẩu ứng dụng được lưu với quyền "mọi app của bạn được đọc" nên sau đó build lại hay cập nhật sẽ không bị hỏi nữa. Đổi lại, app nào chạy dưới tài khoản của bạn cũng đọc được các mật khẩu ứng dụng này mà không bị hỏi; đây là mật khẩu phạm vi hẹp, thu hồi được ở nhà cung cấp mail.
- Nội dung thư tải sẵn nằm trong `~/Library/Caches/com.phudigital.MailBar/Messages` (chỉ chủ máy đọc được). Khi gỡ app, có thể xoá thư mục này.
- Nếu không thấy icon, có thể menubar đã quá đầy hoặc icon bị khuất sau "tai thỏ". Hãy bớt icon khác, hoặc giữ ⌘ rồi kéo để sắp xếp lại.

## Cập nhật

Từ bản 1.4.0, MailBar tự kiểm tra bản mới trên [GitHub Releases](https://github.com/phudigital/mailbar/releases) (sau khi mở app và mỗi 24 giờ). Khi có bản mới, bảng menubar hiện thanh **Có bản mới** với nút **Cập nhật**. App tự tải file, đối chiếu mã SHA-256, kiểm tra bản mới **cùng chữ ký** với bản đang chạy, thay chính nó rồi mở lại; lỗi ở bước nào thì giữ nguyên bản cũ.

- Tắt/bật kiểm tra tự động hoặc kiểm tra ngay: Cài đặt → Chung → Cập nhật.
- Bản cũ hơn 1.4.0 cần cài tay một lần.
- Bản tự build từ mã nguồn (ký bằng chứng chỉ khác) sẽ thấy thông báo bản mới nhưng không tự cài được; hãy build lại từ mã nguồn hoặc cài bản DMG.
- Thư mục chứa app phải ghi được (như `/Applications`); nếu không, app báo lỗi và bạn kéo bản mới vào tay.

## Dành cho người phát triển

- [AGENTS.md](AGENTS.md): kiến trúc, quy ước bắt buộc, những chỗ dễ sai, quy trình build/phát hành, và quy định làm việc cho AI agent.
- [workflow-next-step.md](workflow-next-step.md): việc đã làm, việc có thể làm tiếp (kèm vị trí file và hướng sửa), bài học.
- Phát hành: `VERSION` → `CHANGELOG.md` → `./build.sh dist` → commit → `./scripts/release.sh`.
