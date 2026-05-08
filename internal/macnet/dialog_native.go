// Native macOS dialog via cgo + AppKit.
//
// The osascript-based PromptOTP works but has two unwanted side-effects:
//
//  1. macOS attributes the dialog to the AppleScript runner, so the user
//     sees a transient "Script Editor" icon in the menu bar / Dock for
//     the lifetime of the dialog.
//  2. From a Setsid'd daemon, getting the dialog to come to the front
//     reliably requires shell-quoting tricks that don't always work.
//
// When packxy runs inside its .app bundle (post-`packxy install`), this
// file's `cocoaPromptOTP` displays an NSAlert with a text field directly
// from the watcher process. Because the dialog is owned by our bundle,
// macOS uses the packxy icon and bundle identifier — no AppleScript icon,
// no menu-bar surprise.
//
// Threading: NSAlert.runModal must be called on the thread where NSApp
// was bootstrapped. We runtime.LockOSThread on the calling goroutine and
// run all the Cocoa setup + modal on that same thread.

package macnet

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Foundation -framework AppKit

#include <Foundation/Foundation.h>
#include <AppKit/AppKit.h>
#include <stdlib.h>
#include <string.h>

// packxy_prompt_otp shows a modal NSAlert with a text input. Returns a
// strdup'd UTF-8 string with the user's input on OK; NULL on Cancel.
// `out_cancelled` is set non-zero on Cancel.
//
// Caller (Go) is responsible for freeing the returned char* via free().
static char* packxy_prompt_otp(const char* title, const char* message, int* out_cancelled) {
    @autoreleasepool {
        // sharedApplication is idempotent; LSUIElement=true in Info.plist
        // gives us NSApplicationActivationPolicyAccessory by default, but
        // setting it explicitly makes the call safe even if Info.plist
        // is missing.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp activateIgnoringOtherApps:YES];

        NSAlert* alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = [NSString stringWithUTF8String:title];
        alert.informativeText = [NSString stringWithUTF8String:message];
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"];

        NSTextField* input = [[NSTextField alloc]
            initWithFrame:NSMakeRect(0, 0, 240, 24)];
        [input setEditable:YES];
        [input setSelectable:YES];
        [input setBezeled:YES];
        alert.accessoryView = input;

        // Pin the dialog above other windows so a Setsid'd daemon doesn't
        // get its modal stuck behind everything.
        [alert.window setLevel:NSStatusWindowLevel];
        [alert.window setInitialFirstResponder:input];
        [alert.window makeFirstResponder:input];

        NSModalResponse resp = [alert runModal];
        if (resp != NSAlertFirstButtonReturn) {
            *out_cancelled = 1;
            return NULL;
        }
        *out_cancelled = 0;
        const char* utf8 = [[input stringValue] UTF8String];
        if (utf8 == NULL) {
            return strdup("");
        }
        return strdup(utf8);
    }
}
*/
import "C"

import (
	"runtime"
	"unsafe"
)

// cocoaPromptOTP displays a native NSAlert with a text input and returns
// the user's entry, or ("", true) on cancel. Must be invoked from a
// process running inside the .app bundle for the dialog to be attributed
// correctly — `runningInsideBundle` gates this.
func cocoaPromptOTP(title, message string) (string, bool) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	cTitle := C.CString(title)
	cMessage := C.CString(message)
	defer C.free(unsafe.Pointer(cTitle))
	defer C.free(unsafe.Pointer(cMessage))

	var cancelled C.int
	cResult := C.packxy_prompt_otp(cTitle, cMessage, &cancelled)
	if cancelled != 0 {
		return "", true
	}
	if cResult == nil {
		return "", false
	}
	defer C.free(unsafe.Pointer(cResult))
	return C.GoString(cResult), false
}
