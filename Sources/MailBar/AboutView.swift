import AppKit
import SwiftUI

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    /// Đang chạy như một `.app` có bundle id (không phải binary trần của `swift run`) — điều kiện để tự cập nhật.
    static var isRelease: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "© Phu Digital"
    }

    /// Thông tin để gửi khi cần hỗ trợ.
    static var diagnostics: String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var arch = "arm64"
        #if arch(x86_64)
        arch = "x86_64"
        #endif
        return "MailBar \(version) (build \(build)) — macOS \(os) — \(arch)"
    }
}

/// Tab "Giới thiệu": phiên bản, hướng dẫn nhanh, link lấy mật khẩu ứng dụng.
struct AboutView: View {
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MailBar").font(.title2.weight(.semibold))
                        Text("Phiên bản \(AppInfo.version) (build \(AppInfo.build))")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Kiểm tra thư Gmail, Lark, Yandex… ngay trên menubar — xem tiêu đề, đọc nhanh, đánh dấu đã đọc, xoá.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Hướng dẫn nhanh") {
                Step(number: 1, text: "Tạo **mật khẩu ứng dụng** ở nhà cung cấp mail (xem link bên dưới). Không dùng mật khẩu đăng nhập thường.")
                Step(number: 2, text: "Mở tab **Tài khoản** → bấm **+** → chọn nhà cung cấp → nhập email và mật khẩu ứng dụng → **Kiểm tra kết nối** → **Thêm tài khoản**.")
                Step(number: 3, text: "Khi macOS hỏi quyền truy cập Keychain, bấm **Always Allow** để không bị hỏi lại.")
                Step(number: 4, text: "Bấm icon phong bì trên menubar để xem thư. Bấm vào một thư để **đọc**; rê chuột lên thư để **đánh dấu đã đọc**, **xoá** (vào Thùng rác) hoặc **mở trên web**.")
                Step(number: 5, text: "Thư có **mã xác minh (OTP)** hoặc **link xác minh**: mở thư ra sẽ thấy khung ở đầu thư với nút **Sao chép** mã, **Mở** hoặc **Sao chép link**. Nội dung thư vẫn hiện như thường; tắt được trong tab **Chung**.")
                Step(number: 6, text: "Menu **⋯** cạnh mỗi tài khoản: đánh dấu tất cả đã đọc, mở hộp thư web, kiểm tra lại.")
                Step(number: 7, text: "Muốn xem cả thư rác: trong từng tài khoản, bật **Kiểm tra cả thư mục Spam**. Thư spam hiện thành nhóm riêng màu cam, có nút **Không phải spam**. Thư rác ở Hộp thư đến: bấm icon **bát giác chấm than** cạnh nút xoá để chuyển vào Spam.")
                Step(number: 8, text: "Tab **Chung**: tần suất kiểm tra, thông báo, và **Tự khởi động cùng macOS**, **Tải sẵn nội dung thư mới** (mở thư là xem ngay).")
            }

            Section("Lấy mật khẩu ứng dụng") {
                LinkRow(title: "Gmail / Google Workspace",
                        detail: "Cần bật Xác minh 2 bước",
                        url: "https://myaccount.google.com/apppasswords")
                LinkRow(title: "Lark Mail",
                        detail: "App Lark desktop → Settings → Email → Third-party email client login",
                        url: "https://www.larksuite.com/hc/en-US/articles/378111206512-log-in-to-lark-mail-through-a-third-party-email-client")
                LinkRow(title: "Yandex Mail",
                        detail: "Bật IMAP trong cài đặt mail trước",
                        url: "https://id.yandex.com/security/app-passwords")
            }

            Section("Lưu ý") {
                Label("Xoá thư luôn là chuyển vào Thùng rác, không xoá vĩnh viễn.", systemImage: "trash")
                Label("Mật khẩu chỉ lưu trong Keychain của máy này.", systemImage: "lock")
                Label("Không thấy icon? Menubar có thể đã đầy hoặc bị \"tai thỏ\" che — giữ ⌘ và kéo để sắp xếp lại.", systemImage: "menubar.rectangle")
            }
            .font(.callout)

            Section {
                HStack {
                    Text(AppInfo.copyright).foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Đã sao chép" : "Sao chép thông tin phiên bản") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AppInfo.diagnostics, forType: .string)
                        copied = true
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LinkRow: View {
    let title: String
    let detail: String
    let url: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let link = URL(string: url) {
                Link("Mở trang", destination: link)
            }
        }
    }
}
