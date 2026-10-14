import Foundation

@MainActor
final class WindowPrivacyController: ObservableObject {
    struct Report: Decodable {
        struct Settings: Decodable { let enabled: Bool }
        let schemaVersion: Int
        let settings: Settings
        let build: String
        let runtimeAvailable: Bool
    }

    @Published private(set) var enabled = false
    @Published private(set) var runtimeAvailable = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    private var revision: UInt64 = 0

    func load(appPath: String) async {
        await run(["get"], appPath: appPath, saving: false, successMessage: nil)
    }

    func setEnabled(_ newValue: Bool, appPath: String) async {
        await run([newValue ? "on" : "off"], appPath: appPath, saving: true,
                  successMessage: newValue
                    ? "已开启。已经打开的微信窗口半秒内生效，新窗口一出现就会隐藏。"
                    : "已关闭，微信窗口恢复原来的可见性。")
    }

    private func run(_ arguments: [String], appPath: String, saving: Bool, successMessage: String?) async {
        revision &+= 1
        let activeRevision = revision
        busy = true
        error = nil
        message = nil
        if !saving { enabled = false; runtimeAvailable = false }
        let result = await CLIRunner.runUser(
            BundledPaths.cli, ["window-privacy"] + arguments + ["--app", appPath, "--json"])
        guard revision == activeRevision else { return }
        busy = false
        if result.succeeded,
           let report = try? JSONDecoder().decode(Report.self, from: Data(result.output.utf8)),
           report.schemaVersion == GUICLIProtocol.schemaVersion {
            enabled = report.settings.enabled
            runtimeAvailable = report.runtimeAvailable
            message = successMessage
        } else if let envelope = try? JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(result.output.utf8)) {
            error = envelope.error.message
        } else {
            let failureText = (result.output + result.stderr).lowercased()
            if failureText.contains("permission") || failureText.contains("not permitted") || failureText.contains("权限") {
                error = "无法读取微信设置。请为本工具开启「完全磁盘访问权限」，退出并重新打开后重试。"
            } else {
                error = "无法读取或保存窗口隐私设置。请重新读取后重试。"
            }
        }
    }
}
