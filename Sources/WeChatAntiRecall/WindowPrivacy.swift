import Foundation

// Opt-in: keep every WeChat window out of screen sharing, recordings and other apps'
// screenshots. The runtime (WindowPrivacy.mm) enforces it inside WeChat.

struct WindowPrivacySettings: Codable, Equatable {
    static let preferenceKey = "WeChatAntiRecall_WindowPrivacy"
    static let runtimeMarker = "WeChatAntiRecallWindowPrivacy:1"
    var enabled = false
}

struct WindowPrivacyOptions {
    enum Action: Equatable {
        case get, on, off
    }

    let action: Action
    let appPath: String
    let json: Bool

    init(_ arguments: [String]) throws {
        let actions: [String: Action] = ["get": .get, "on": .on, "off": .off]
        guard let name = arguments.first, let action = actions[name] else {
            throw ToolError.usage("window-privacy 需要 get、on 或 off。")
        }
        var app = "/Applications/WeChat.app"
        var jsonOutput = false
        var seen: Set<String> = []
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard seen.insert(flag).inserted else { throw ToolError.usage("重复参数：\(flag)") }
            if flag == "--json" {
                jsonOutput = true
            } else if flag == "--app" {
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw ToolError.usage("--app 需要一个值。")
                }
                app = arguments[index]
            } else {
                throw ToolError.usage("未知参数：\(flag)")
            }
            index += 1
        }
        self.action = action
        appPath = app
        json = jsonOutput
    }
}

struct WindowPrivacyPreferenceStore {
    // Shares the recall-tip store so writes go through cfprefsd and survive WeChat relaunches.
    let preferences: RecallTipPreferenceStore

    func load() throws -> WindowPrivacySettings {
        guard let value = try preferences.preferenceValue(forKey: WindowPrivacySettings.preferenceKey) else {
            return WindowPrivacySettings()
        }
        guard let dictionary = value as? [String: Any], let enabled = dictionary["enabled"] as? Bool else {
            throw ToolError.usage("窗口隐私设置已损坏，请运行 window-privacy off 后重新开启。")
        }
        return WindowPrivacySettings(enabled: enabled)
    }

    func save(_ settings: WindowPrivacySettings) throws {
        try preferences.setPreferenceValue(
            ["enabled": settings.enabled], forKey: WindowPrivacySettings.preferenceKey)
    }
}

struct WindowPrivacyReport: Encodable {
    let schemaVersion: Int
    let settings: WindowPrivacySettings
    let build: String
    let runtimeAvailable: Bool
}
