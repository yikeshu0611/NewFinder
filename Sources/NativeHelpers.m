#import "NativeHelpers.h"

BOOL NFReadNormalizedPosition(NSTouch *touch, NSPoint *outPosition) {
    if (touch == nil) {
        return NO;
    }
    @try {
        NSPoint position = touch.normalizedPosition;
        if (outPosition != NULL) {
            *outPosition = position;
        }
        return YES;
    } @catch (NSException *exception) {
        // Universal Control forwarded touches — the position is not available.
        return NO;
    }
}

void NFAddMachPortSourceToCurrentRunLoop(CFMachPortRef machPort) {
    if (machPort == NULL) {
        return;
    }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0);
    if (source == NULL) {
        return;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
}

// Asks the system for the「输入监控」permission. Without it the event tap is
// created but never delivers gesture events, so the swipe cannot be detected.
void NFRequestListenEventAccess(void) {
    if (@available(macOS 10.15, *)) {
        CGRequestListenEventAccess();
    }
}

// Returns YES when the process already has permission to observe events.
BOOL NFHasListenEventAccess(void) {
    if (@available(macOS 10.15, *)) {
        return CGPreflightListenEventAccess() ? YES : NO;
    }
    return YES;
}

// Returns YES when the process is trusted for Accessibility.
//
// This is the permission that actually matters for the gesture tap: without
// it the tap object is created but never receives a single event.
BOOL NFHasAccessibilityAccess(void) {
    return AXIsProcessTrusted() ? YES : NO;
}

// Asks the system to grant the「辅助功能」permission. The system shows its own
// prompt; the user still has to enable the switch in System Settings.
void NFRequestAccessibilityAccess(void) {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}
