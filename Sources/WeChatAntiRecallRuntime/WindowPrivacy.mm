#import <AppKit/AppKit.h>
#include <atomic>
#include <dispatch/dispatch.h>
#include <os/log.h>

#include "WeChatAntiRecallRuntime.h"
#include "WindowPrivacyInternal.h"

// Opt-in: keep every WeChat window out of screen sharing, screen recordings and other
// apps' screenshots by setting NSWindow.sharingType to none. This uses only public AppKit
// API and no per-build address, so it works on every build the runtime loads into.
namespace {

constexpr const char *runtimeVersion = "WeChatAntiRecallWindowPrivacy:1";
constexpr const char *settingsKey = "WeChatAntiRecall_WindowPrivacy";
constexpr uint64_t sweepIntervalNanoseconds = NSEC_PER_SEC / 2;

std::atomic<bool> enforcing{false};

// A dictionary with a strict boolean `enabled`; anything else is off.
bool enabledFromValue(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return false;
    id enabled = ((NSDictionary *)value)[@"enabled"];
    return [enabled isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)enabled) == CFBooleanGetTypeID() &&
        [enabled boolValue];
}

// Only cfprefsd is consulted: this runs twice a second, and the CLI always writes through it.
bool loadEnabled() {
    @autoreleasepool {
        CFPropertyListRef value = CFPreferencesCopyAppValue(
            (__bridge CFStringRef)@(settingsKey), kCFPreferencesCurrentApplication);
        if (value == nullptr) return false;
        const bool enabled = enabledFromValue((__bridge id)value);
        CFRelease(value);
        return enabled;
    }
}

// Main queue only. Remembers each window's own sharing type before the first change, so
// switching the feature off puts it back, and never touches a window it did not change.
NSMapTable<NSWindow *, NSNumber *> *originals() {
    static NSMapTable<NSWindow *, NSNumber *> *table = [NSMapTable weakToStrongObjectsMapTable];
    return table;
}

void hide(NSWindow *window) {
    if (![window isKindOfClass:NSWindow.class]) return;
    // A window that is already hidden (WeChat's own "hide window" option) is left alone and
    // untracked, so it is never "restored" into view.
    if (window.sharingType == NSWindowSharingNone) return;
    // If WeChat re-exposed a window we had hidden, its newest choice is the one to restore.
    [originals() setObject:@(window.sharingType) forKey:window];
    window.sharingType = NSWindowSharingNone;
}

void restore(NSWindow *window) {
    NSNumber *original = [originals() objectForKey:window];
    if (original == nil) return;
    [originals() removeObjectForKey:window];
    if (window.sharingType == NSWindowSharingNone) {
        window.sharingType = static_cast<NSWindowSharingType>(original.integerValue);
    }
}

void sweep(NSArray<NSWindow *> *windows, bool enabled) {
    if (enabled) {
        for (NSWindow *window in windows) hide(window);
        return;
    }
    // Disabled: undo only what this module did. The table is empty if it never ran.
    for (NSWindow *window in originals().keyEnumerator.allObjects) restore(window);
}

void tick() {
    const bool enabled = loadEnabled();
    enforcing.store(enabled);
    // NSApp stays nil until WeChat creates its application object.
    if (NSApp == nil && enabled) return;
    sweep(NSApp.windows, enabled);
}

}  // namespace

void wechat_antirecall_window_privacy_start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            static dispatch_source_t timer;
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                      sweepIntervalNanoseconds, sweepIntervalNanoseconds / 5);
            dispatch_source_set_event_handler(timer, ^{ tick(); });
            dispatch_resume(timer);

            // A window that becomes key is on screen now; do not wait for the next tick.
            auto hideIfEnforcing = ^(NSNotification *note) {
                if (enforcing.load()) hide(note.object);
            };
            for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification,
                                              NSWindowDidExposeNotification]) {
                [NSNotificationCenter.defaultCenter addObserverForName:name object:nil
                                                                 queue:NSOperationQueue.mainQueue
                                                            usingBlock:hideIfEnforcing];
            }
        });
    });
}

extern "C" {

const char *wechat_antirecall_window_privacy_runtime_version(void) {
    return runtimeVersion;
}

int wechat_antirecall_window_privacy_enabled_for_plist(const char *plistPath) {
    @autoreleasepool {
        if (plistPath == nullptr) return 0;
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:@(plistPath)];
        return enabledFromValue(plist[@(settingsKey)]) ? 1 : 0;
    }
}

// Runs one enforcement pass over `windows` (NSWindow pointers, not retained) exactly as the
// timer does for NSApp.windows. Main thread only.
void wechat_antirecall_window_privacy_sweep_for_test(const void *const *windows, size_t count, int enabled) {
    @autoreleasepool {
        NSMutableArray<NSWindow *> *list = [NSMutableArray arrayWithCapacity:count];
        for (size_t index = 0; index < count; index += 1) [list addObject:(__bridge NSWindow *)windows[index]];
        sweep(list, enabled != 0);
    }
}

}  // extern "C"
