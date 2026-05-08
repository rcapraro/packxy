// macOS user-notification dispatch via cgo + AppKit.
//
// We deliberately use the older NSUserNotification API rather than the
// modern UserNotifications framework. NSUserNotification:
//
//   - is synchronous and fire-and-forget (no permission request flow), so
//     it works from a Setsid'd watcher daemon without UI;
//   - picks up the calling process's bundle icon and bundle identifier
//     automatically — no extra wiring beyond shipping the binary inside a
//     .app bundle with an Info.plist + AppIcon.icns;
//   - is deprecated since macOS 11 but still functional through (at least)
//     macOS 15. We stay on it until Apple actually removes the symbol.
//
// UserNotifications is the supposed replacement but requires authorization
// flow + a run-loop, neither of which fits a one-shot CLI invocation from a
// long-lived background process.

package macnet

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Foundation -framework AppKit

#include <Foundation/Foundation.h>
#include <AppKit/AppKit.h>

static void packxy_send_notification(const char* title, const char* body) {
    @autoreleasepool {
        NSUserNotification* n = [[NSUserNotification alloc] init];
        n.title = [NSString stringWithUTF8String:title];
        n.informativeText = [NSString stringWithUTF8String:body];
        // Suppress the bundled "default" sound — packxy notifications fire
        // on every drop and the Mac's notification chime is overkill.
        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:n];
    }
}
*/
import "C"

import "unsafe"

// sendNSNotification posts title/body to NSUserNotificationCenter. Must be
// called from a process running inside a .app bundle for the notification
// to show our icon and identifier — runningInsideBundle gates this.
func sendNSNotification(title, body string) {
	cTitle := C.CString(title)
	cBody := C.CString(body)
	defer C.free(unsafe.Pointer(cTitle))
	defer C.free(unsafe.Pointer(cBody))
	C.packxy_send_notification(cTitle, cBody)
}
