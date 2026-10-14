import XCTest
import AppKit
import Foundation
import WeChatAntiRecallRuntime
@testable import WeChatAntiRecall

final class WindowPrivacyTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
        super.tearDown()
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("window-privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func runtimeEnabled(_ value: Any?) throws -> Bool {
        let url = try makeFolder().appendingPathComponent("prefs.plist")
        let root: [String: Any] = value.map { ["WeChatAntiRecall_WindowPrivacy": $0] } ?? ["Other": 1]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
        return wechat_antirecall_window_privacy_enabled_for_plist(url.path) == 1
    }

    // The same pass the runtime's timer makes over NSApp.windows.
    private func sweep(_ windows: [NSWindow], enabled: Bool) {
        let pointers: [UnsafeRawPointer?] = windows.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) }
        pointers.withUnsafeBufferPointer { buffer in
            wechat_antirecall_window_privacy_sweep_for_test(buffer.baseAddress, buffer.count, enabled ? 1 : 0)
        }
    }

    private func makeWindow(sharing: NSWindow.SharingType) throws -> NSWindow {
        try XCTSkipIf(NSScreen.screens.isEmpty, "needs a window server session")
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.sharingType = sharing
        return window
    }

    // MARK: - Settings

    func testRuntimeMarkerMatchesRuntimeExport() {
        XCTAssertEqual(String(cString: wechat_antirecall_window_privacy_runtime_version()), WindowPrivacySettings.runtimeMarker)
        XCTAssertEqual(WindowPrivacySettings.runtimeMarker, "WeChatAntiRecallWindowPrivacy:1")
    }

    func testRuntimeSettingRequiresStrictBooleanDictionary() throws {
        XCTAssertTrue(try runtimeEnabled(["enabled": true]))
        XCTAssertFalse(try runtimeEnabled(["enabled": false]))
        XCTAssertFalse(try runtimeEnabled(["enabled": 1]))
        XCTAssertFalse(try runtimeEnabled(["enabled": "true"]))
        XCTAssertFalse(try runtimeEnabled([String: Any]()))
        XCTAssertFalse(try runtimeEnabled(true))
        XCTAssertFalse(try runtimeEnabled(nil), "off by default")
        XCTAssertEqual(wechat_antirecall_window_privacy_enabled_for_plist(try makeFolder().appendingPathComponent("missing.plist").path), 0)
    }

    func testStrictCLIOptions() throws {
        XCTAssertEqual(try WindowPrivacyOptions(["get", "--json"]).action, .get)
        XCTAssertTrue(try WindowPrivacyOptions(["get", "--json"]).json)
        XCTAssertEqual(try WindowPrivacyOptions(["on", "--app", "/tmp/WeChat.app"]).appPath, "/tmp/WeChat.app")
        XCTAssertEqual(try WindowPrivacyOptions(["off"]).action, .off)
        XCTAssertEqual(try WindowPrivacyOptions(["on"]).appPath, "/Applications/WeChat.app")
        for args in [[], ["enable"], ["on", "--app"], ["on", "--app", "--json"], ["get", "--json", "--json"],
                     ["on", "--app", "/a", "--app", "/b"], ["on", "--unknown"], ["on", "--keyword", "x"]] {
            XCTAssertThrowsError(try WindowPrivacyOptions(args), "\(args)")
        }
    }

    func testPreferenceRoundTripKeepsOtherSettingsAndRejectsDamage() throws {
        let folder = try makeFolder()
        let store = WindowPrivacyPreferenceStore(
            preferences: RecallTipPreferenceStore(homeDirectory: folder, domain: "com.tencent.xinWeChat"))
        XCTAssertEqual(try store.load(), WindowPrivacySettings(), "off by default")
        XCTAssertFalse(WindowPrivacySettings().enabled)

        let plist = store.preferences.preferenceFileURL
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = ["Unrelated": "preserve"]
        try PropertyListSerialization.data(fromPropertyList: existing, format: .binary, options: 0).write(to: plist)
        try store.save(WindowPrivacySettings(enabled: true))
        XCTAssertEqual(try store.load(), WindowPrivacySettings(enabled: true))
        let saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        XCTAssertEqual(saved["Unrelated"] as? String, "preserve")
        // What the CLI stores must be exactly what the runtime accepts.
        XCTAssertEqual(wechat_antirecall_window_privacy_enabled_for_plist(plist.path), 1)

        let damaged: [String: Any] = ["WeChatAntiRecall_WindowPrivacy": ["enabled": "yes"]]
        try PropertyListSerialization.data(fromPropertyList: damaged, format: .binary, options: 0).write(to: plist)
        XCTAssertThrowsError(try store.load())
    }

    // MARK: - Enforcement

    func testHidesWindowsWhenEnabledAndRestoresThemWhenDisabled() throws {
        let readOnly = try makeWindow(sharing: .readOnly)
        let readWrite = try makeWindow(sharing: .readWrite)
        sweep([readOnly, readWrite], enabled: true)
        XCTAssertEqual(readOnly.sharingType, .none)
        XCTAssertEqual(readWrite.sharingType, .none)

        sweep([readOnly, readWrite], enabled: false)
        XCTAssertEqual(readOnly.sharingType, .readOnly)
        XCTAssertEqual(readWrite.sharingType, .readWrite, "the window's own earlier value comes back, not a default")
    }

    func testNeverTouchesWindowsWhileDisabled() throws {
        let plain = try makeWindow(sharing: .readOnly)
        let hidden = try makeWindow(sharing: .none)
        sweep([plain, hidden], enabled: false)
        XCTAssertEqual(plain.sharingType, .readOnly)
        XCTAssertEqual(hidden.sharingType, .none)
    }

    func testLeavesWindowsWeChatAlreadyHidesHidden() throws {
        let hiddenByWeChat = try makeWindow(sharing: .none)
        sweep([hiddenByWeChat], enabled: true)
        sweep([hiddenByWeChat], enabled: false)
        XCTAssertEqual(hiddenByWeChat.sharingType, .none, "turning the feature off must not expose a window WeChat hid itself")
    }

    func testReappliesWhenWeChatExposesAWindowAgainAndRestoresItsLatestChoice() throws {
        let window = try makeWindow(sharing: .readOnly)
        sweep([window], enabled: true)
        XCTAssertEqual(window.sharingType, .none)

        window.sharingType = .readWrite  // WeChat sets the window up again
        sweep([window], enabled: true)
        XCTAssertEqual(window.sharingType, .none)

        sweep([window], enabled: false)
        XCTAssertEqual(window.sharingType, .readWrite, "the latest value WeChat chose is the one restored")
    }

    func testEnablingTwiceKeepsTheOriginalValue() throws {
        let window = try makeWindow(sharing: .readOnly)
        sweep([window], enabled: true)
        sweep([window], enabled: true)
        sweep([window], enabled: false)
        XCTAssertEqual(window.sharingType, .readOnly)
    }
}
