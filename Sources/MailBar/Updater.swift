import AppKit
import CryptoKit
import Security

/// Số phiên bản `MAJOR.MINOR.PATCH` (chấp nhận tiền tố `v`). Phần hậu tố như `-beta` bị bỏ qua.
struct SemVer: Comparable, Equatable {
    let parts: [Int]

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        s = String(s.prefix { $0.isNumber || $0 == "." })
        let nums = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !nums.isEmpty, !nums.contains(where: { $0 == nil }) else { return nil }
        parts = nums.compactMap { $0 }
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: SemVer, b: SemVer) -> Bool { !(a < b) && !(b < a) }
}

/// Bản phát hành mới trên GitHub Releases.
struct ReleaseInfo: Equatable {
    let version: String
    let notes: String
    let pageURL: URL
    let zipURL: URL
    let zipName: String
    let sumsURL: URL
}

/// Tự cập nhật qua GitHub Releases của `Updater.repo` (repo công khai, không cần token).
///
/// Luồng: hỏi API `releases/latest` → so phiên bản → khi người dùng đồng ý: tải `MailBar-<ver>.zip`, đối chiếu SHA-256
/// với `SHA256SUMS.txt` cùng release, giải nén, kiểm tra bản mới thoả **Designated Requirement của chính app đang chạy**
/// (cùng identifier + cùng chứng chỉ ký, nên kẻ không có khoá ký không giả được) → script nền chờ app thoát, thay bundle, mở lại.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    nonisolated static let repo = "phudigital/mailbar"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var timer: Timer?

    var available: ReleaseInfo? {
        if case .available(let release) = state { return release }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .installing: return true
        default: return false
        }
    }

    /// Kiểm tra sau ít giây khi mở app, rồi mỗi 24 giờ (nếu người dùng bật kiểm tra tự động).
    func start() {
        guard AppInfo.isRelease else { return }
        Task {
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            await autoCheck()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.autoCheck() }
        }
        timer?.tolerance = 3600
    }

    private func autoCheck() async {
        guard UserDefaults.standard.bool(forKey: Prefs.autoCheckUpdates) else { return }
        await check(silent: true)
    }

    /// `silent`: kiểm tra tự động — lỗi mạng không hiện ra, và có bản mới thì báo bằng thông báo (một lần cho mỗi phiên bản).
    func check(silent: Bool = false) async {
        guard !isBusy else { return }
        guard AppInfo.isRelease, let current = SemVer(AppInfo.version) else {
            state = .failed("Bản chạy thử (không phải .app phát hành) không tự cập nhật.")
            return
        }
        let previous = state
        state = .checking
        do {
            let latest = try await Self.fetchLatest()
            if let latest, let v = SemVer(latest.version), v > current {
                state = .available(latest)
                notifyOnce(latest, silent: silent)
            } else {
                state = .upToDate
            }
        } catch {
            state = silent ? previous : .failed("Không kiểm tra được bản mới: \(error.localizedDescription)")
        }
        UserDefaults.standard.set(Date(), forKey: Prefs.lastUpdateCheck)
    }

    private func notifyOnce(_ release: ReleaseInfo, silent: Bool) {
        guard silent, UserDefaults.standard.string(forKey: Prefs.notifiedUpdateVersion) != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: Prefs.notifiedUpdateVersion)
        Notifier.shared.notify(title: "Có bản MailBar mới: \(release.version)",
                               body: "Mở MailBar và bấm Cập nhật.",
                               url: release.pageURL)
    }

    // MARK: - Tải thông tin bản mới

    private struct APIRelease: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]
    }

    /// `nil` nếu repo chưa có release nào. Chỉ chấp nhận link tải nằm trong đúng repo này.
    nonisolated private static func fetchLatest() async throws -> ReleaseInfo? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MailBar/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw UpdateError.http(status) }
        return try release(from: data)
    }

    /// Tách riêng để kiểm thử được bằng JSON mẫu.
    nonisolated static func release(from data: Data) throws -> ReleaseInfo? {
        let api = try JSONDecoder().decode(APIRelease.self, from: data)
        let version = api.tag_name.hasPrefix("v") ? String(api.tag_name.dropFirst()) : api.tag_name
        guard SemVer(version) != nil else { return nil }
        func asset(_ name: String) -> URL? {
            api.assets.first { $0.name == name }?.browser_download_url
        }
        let zipName = "MailBar-\(version).zip"
        guard let zip = asset(zipName), let sums = asset("SHA256SUMS.txt"),
              isTrusted(zip), isTrusted(sums) else { return nil }
        return ReleaseInfo(version: version, notes: api.body ?? "", pageURL: api.html_url,
                           zipURL: zip, zipName: zipName, sumsURL: sums)
    }

    nonisolated private static func isTrusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.path.hasPrefix("/\(repo)/releases/download/")
    }

    // MARK: - Cài đặt

    enum UpdateError: LocalizedError {
        case http(Int)
        case notWritable(String)
        case badChecksum
        case missingChecksum
        case badArchive
        case badSignature
        case versionMismatch

        var errorDescription: String? {
            switch self {
            case .http(let code): return "GitHub trả về mã \(code)"
            case .notWritable(let dir): return "Không ghi được vào \(dir). Hãy kéo bản mới vào Applications bằng tay."
            case .badChecksum: return "Mã băm SHA-256 của file tải về không khớp"
            case .missingChecksum: return "Không thấy mã băm của file trong SHA256SUMS.txt"
            case .badArchive: return "Không giải nén được file cập nhật"
            case .badSignature: return "Bản mới không cùng chữ ký với bản đang chạy nên bị từ chối"
            case .versionMismatch: return "Phiên bản trong file tải về không khớp với release"
            }
        }
    }

    /// Tải, kiểm tra, rồi thay app và mở lại. Thành công thì app tự thoát; lỗi thì để nguyên bản hiện tại.
    func install() async {
        guard let release = available, !isBusy else { return }
        do {
            let bundle = Bundle.main.bundleURL
            let parent = bundle.deletingLastPathComponent()
            guard bundle.pathExtension == "app", FileManager.default.isWritableFile(atPath: parent.path) else {
                throw UpdateError.notWritable(parent.path)
            }

            state = .installing("Đang tải \(release.version)…")
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("MailBarUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let newApp = try await Self.download(release, into: work) { [weak self] message in
                self?.state = .installing(message)
            }

            state = .installing("Đang cài đặt…")
            try Self.launchInstaller(newApp: newApp, target: bundle, work: work)
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        } catch {
            state = .failed("Cập nhật thất bại: \(error.localizedDescription)")
        }
    }

    /// Tải zip, đối chiếu SHA-256, giải nén, kiểm tra chữ ký và phiên bản. Trả về đường dẫn `MailBar.app` mới.
    nonisolated private static func download(_ release: ReleaseInfo, into work: URL,
                                 progress: @MainActor @escaping (String) -> Void) async throws -> URL {
        let (sums, _) = try await URLSession.shared.data(from: release.sumsURL)
        let sumText = String(decoding: sums, as: UTF8.self)
        guard let expected = checksum(for: release.zipName, in: sumText) else { throw UpdateError.missingChecksum }

        let (tmp, _) = try await URLSession.shared.download(from: release.zipURL)
        let zip = work.appendingPathComponent(release.zipName)
        try FileManager.default.moveItem(at: tmp, to: zip)

        await progress("Đang kiểm tra…")
        return try await Task.detached(priority: .userInitiated) { () -> URL in
            let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw UpdateError.badChecksum }

            let extracted = work.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, extracted.path]
            try ditto.run()
            ditto.waitUntilExit()
            let app = extracted.appendingPathComponent("MailBar.app")
            guard ditto.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
                throw UpdateError.badArchive
            }
            guard try satisfiesRunningAppRequirement(app) else { throw UpdateError.badSignature }
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleShortVersionString"] as? String == release.version,
                  info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
                throw UpdateError.versionMismatch
            }
            return app
        }.value
    }

    /// Dòng dạng `<sha256>  <tên file>` (định dạng `shasum -a 256`).
    nonisolated static func checksum(for name: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 2, fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name {
                return fields[0].lowercased()
            }
        }
        return nil
    }

    /// Bản mới phải thoả Designated Requirement của app đang chạy (identifier + chứng chỉ ký).
    nonisolated private static func satisfiesRunningAppRequirement(_ app: URL) throws -> Bool {
        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
            == errSecSuccess
    }

    /// Script nền (sống sau khi app thoát): chờ app thoát → chép bản mới cạnh bản cũ → hoán đổi → mở lại.
    /// Có lỗi ở bước nào thì khôi phục bản cũ và mở lại.
    nonisolated private static func launchInstaller(newApp: URL, target: URL, work: URL) throws {
        let script = work.appendingPathComponent("install.sh")
        try #"""
        #!/bin/sh
        PID="$1"; TARGET="$2"; NEW="$3"; WORK="$4"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done
        rm -rf "$TARGET.updating" "$TARGET.old-update"
        ditto "$NEW" "$TARGET.updating" || { rm -rf "$TARGET.updating"; open "$TARGET"; exit 1; }
        xattr -dr com.apple.quarantine "$TARGET.updating" 2>/dev/null
        mv "$TARGET" "$TARGET.old-update" || { rm -rf "$TARGET.updating"; open "$TARGET"; exit 1; }
        mv "$TARGET.updating" "$TARGET" || { mv "$TARGET.old-update" "$TARGET"; open "$TARGET"; exit 1; }
        open "$TARGET"
        rm -rf "$TARGET.old-update" "$WORK"
        """#.write(to: script, atomically: true, encoding: .utf8)

        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        // nohup + & để script không chết theo MailBar.
        launcher.arguments = ["-c", #"nohup /bin/sh "$0" "$@" >/dev/null 2>&1 &"#,
                              script.path, pid, target.path, newApp.path, work.path]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try launcher.run()
    }
}
