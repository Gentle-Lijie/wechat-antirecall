import Foundation

@MainActor
final class RecallLogController: ObservableObject {
    struct Record: Decodable, Identifiable, Equatable {
        let loggedAt: Int64
        let createTime: Int64?
        let session: String
        let msgId: String
        let newMsgId: String
        let notice: String
        let content: String?

        var id: String { newMsgId.isEmpty ? "\(loggedAt)-\(msgId)-\(session)" : newMsgId }
        var isGroup: Bool { session.hasSuffix("@chatroom") }
        var date: Date { Date(timeIntervalSince1970: TimeInterval(loggedAt)) }
    }

    struct Report: Decodable {
        struct Settings: Decodable { let enabled: Bool }
        let schemaVersion: Int
        let settings: Settings
        let build: String
        let runtimeAvailable: Bool
        let entryCount: Int?
    }

    struct ListReport: Decodable {
        let schemaVersion: Int
        let entries: [Record]
        let total: Int
        let unreadableLines: Int
    }

    /// Entries requested from the CLI; older ones stay in the file.
    static let displayLimit = 200

    @Published private(set) var enabled = false
    @Published private(set) var runtimeAvailable = false
    @Published private(set) var entries: [Record] = []
    @Published private(set) var total = 0
    @Published private(set) var unreadableLines = 0
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published private(set) var needsDiskAccess = false
    private var revision: UInt64 = 0

    func load(appPath: String) async {
        let activeRevision = beginRequest(resetting: true)
        // Settings come first and never need disk access; the list may be refused without it.
        guard await refreshSettings(appPath: appPath, revision: activeRevision) else { return }
        await refreshList(appPath: appPath, revision: activeRevision)
        finishRequest(activeRevision)
    }

    func setEnabled(_ newValue: Bool, appPath: String) async {
        let activeRevision = beginRequest(resetting: false)
        guard await refreshSettings(
            appPath: appPath, revision: activeRevision, arguments: [newValue ? "on" : "off"]) else { return }
        message = newValue
            ? "已开启。新的撤回会记录到下方列表；安装或更新运行组件后，请完全退出并重新打开微信。"
            : "已关闭。已有记录仍然保留，可随时清空。"
        finishRequest(activeRevision)
    }

    func clear(appPath: String) async {
        let activeRevision = beginRequest(resetting: false)
        guard await refreshSettings(appPath: appPath, revision: activeRevision, arguments: ["clear"]) else { return }
        entries = []
        total = 0
        unreadableLines = 0
        message = "已清空撤回记录。"
        finishRequest(activeRevision)
    }

    private func beginRequest(resetting: Bool) -> UInt64 {
        revision &+= 1
        busy = true
        error = nil
        needsDiskAccess = false
        message = nil
        if resetting {
            enabled = false
            runtimeAvailable = false
            entries = []
            total = 0
            unreadableLines = 0
        }
        return revision
    }

    private func finishRequest(_ activeRevision: UInt64) {
        guard revision == activeRevision else { return }
        busy = false
    }

    /// Runs a settings-shaped command (`get`, `on`, `off`, `clear`). Returns false after reporting a failure.
    private func refreshSettings(appPath: String, revision activeRevision: UInt64, arguments: [String] = ["get"]) async -> Bool {
        let result = await CLIRunner.runUser(
            BundledPaths.cli, ["recall-log"] + arguments + ["--app", appPath, "--json"])
        guard revision == activeRevision else { return false }
        // `clear` prints a progress line before its JSON report; the report starts at the first brace.
        let output = result.output.firstIndex(of: "{").map { String(result.output[$0...]) } ?? result.output
        if result.succeeded,
           let report = try? JSONDecoder().decode(Report.self, from: Data(output.utf8)),
           report.schemaVersion == GUICLIProtocol.schemaVersion {
            enabled = report.settings.enabled
            runtimeAvailable = report.runtimeAvailable
            return true
        }
        report(failure: result.output + result.stderr, envelopeText: output)
        busy = false
        return false
    }

    private func refreshList(appPath: String, revision activeRevision: UInt64) async {
        let result = await CLIRunner.runUser(
            BundledPaths.cli,
            ["recall-log", "list", "--limit", String(Self.displayLimit), "--app", appPath, "--json"])
        guard revision == activeRevision else { return }
        if result.succeeded,
           let report = try? JSONDecoder().decode(ListReport.self, from: Data(result.output.utf8)),
           report.schemaVersion == GUICLIProtocol.schemaVersion {
            entries = report.entries
            total = report.total
            unreadableLines = report.unreadableLines
        } else {
            report(failure: result.output + result.stderr, envelopeText: result.output)
        }
    }

    private func report(failure text: String, envelopeText: String) {
        let lowered = text.lowercased()
        if lowered.contains("permission") || lowered.contains("not permitted") || lowered.contains("权限") {
            needsDiskAccess = true
            error = "无法读取微信容器里的撤回记录。请为本工具开启「完全磁盘访问权限」，退出并重新打开后重试。"
        } else if let envelope = try? JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(envelopeText.utf8)) {
            error = envelope.error.message
        } else {
            error = "无法读取撤回记录设置。请重新读取后重试。"
        }
    }
}
