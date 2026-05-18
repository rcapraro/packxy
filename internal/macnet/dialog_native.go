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
// `title` is rendered as messageText (bold, beside the alert icon).
// `detail` is rendered as informativeText (smaller, beneath the title).
//
// Caller (Go) is responsible for freeing the returned char* via free().
static char* packxy_prompt_otp(const char* title, const char* detail, int* out_cancelled) {
    @autoreleasepool {
        // Bootstrap NSApp. finishLaunching is what most "headless" Cocoa
        // tools forget — without it some plumbing (CGS connections,
        // services menu, default activation) stays half-initialised and
        // runModal can block silently waiting for events that never come.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        [NSApp activateIgnoringOtherApps:YES];

        NSAlert* alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = [NSString stringWithUTF8String:title];
        alert.informativeText = [NSString stringWithUTF8String:detail];
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"];

        NSTextField* input = [[NSTextField alloc]
            initWithFrame:NSMakeRect(0, 0, 240, 24)];
        [input setEditable:YES];
        [input setSelectable:YES];
        [input setBezeled:YES];
        alert.accessoryView = input;

        // Pin the dialog above other windows + bring it on screen now so
        // we don't depend on activation propagating through the run loop.
        [alert.window setLevel:NSStatusWindowLevel];
        [alert.window center];
        [alert.window makeKeyAndOrderFront:nil];
        [alert.window orderFrontRegardless];
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

// CocoaPromptOTP displays a native NSAlert with a text input and returns
// the user's entry, or ("", true) on cancel. Must be invoked from a
// process running inside the .app bundle for the dialog to be attributed
// correctly.
//
// `title` becomes the alert's messageText (Packxy-branded bold line
// beside the icon); `detail` is the informativeText shown beneath.
// Splitting them mirrors Apple's HIG for alert layout — single-paragraph
// dialogs look amateurish.
//
// Exported (and intended to run in its own short-lived process) because
// the watcher daemon — being Setsid'd and lacking a Cocoa run loop —
// can't reliably bring up an NSAlert directly. The watcher therefore
// spawns `packxy _otpdialog` as a child; that child invokes this
// function once and exits, giving Cocoa a clean process to work with.
func CocoaPromptOTP(title, detail string) (string, bool) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	cTitle := C.CString(title)
	cDetail := C.CString(detail)
	defer C.free(unsafe.Pointer(cTitle))
	defer C.free(unsafe.Pointer(cDetail))

	var cancelled C.int
	cResult := C.packxy_prompt_otp(cTitle, cDetail, &cancelled)
	if cancelled != 0 {
		return "", true
	}
	if cResult == nil {
		return "", false
	}
	defer C.free(unsafe.Pointer(cResult))
	return C.GoString(cResult), false
}
