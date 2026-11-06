#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreFoundation/CFMachPort.h>
#import <CoreFoundation/CFRunLoop.h>
#import <ApplicationServices/ApplicationServices.h>

/// Reads `NSTouch.normalizedPosition` without letting an ObjC exception escape.
///
/// `normalizedPosition` raises `NSInternalInconsistencyException` for some valid
/// indirect touches — notably ones forwarded by Universal Control from another
/// Mac's trackpad. Swift cannot catch `NSException`, so the read has to happen
/// behind an Objective-C `@try`/`@catch`. A touch whose position cannot be read
/// is reported as unavailable and skipped by the gesture detector.
BOOL NFReadNormalizedPosition(NSTouch *touch, NSPoint *outPosition);

/// Adds a `CFMachPort`'s run-loop source to the current run loop.
///
/// `CFRunLoopAddSource` has an overload that takes a `CFMachPort` and one that
/// takes a `CFRunLoopSource`, and Swift cannot pick between them for a
/// `CFMachPort` — this shim removes the ambiguity.
void NFAddMachPortSourceToCurrentRunLoop(CFMachPortRef machPort);

/// Asks the system to grant the「输入监控」(Input Monitoring) permission.
///
/// The gesture tap needs this permission; without it the tap is created but
/// never receives events. The system shows its own prompt.
void NFRequestListenEventAccess(void);

/// Returns YES when the process already may observe input events.
BOOL NFHasListenEventAccess(void);

/// Returns YES when the process is trusted for Accessibility.
///
/// The gesture tap needs this permission — without it the tap is created but
/// never receives a single event.
BOOL NFHasAccessibilityAccess(void);

/// Asks the system to grant the「辅助功能」permission (shows the system prompt).
void NFRequestAccessibilityAccess(void);
