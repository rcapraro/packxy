package macnet

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/rcapraro/packxy/internal/state"
)

// ErrDialogCancelled is returned by PromptOTP when the user dismisses the dialog.
var ErrDialogCancelled = errors.New("dialog cancelled")

// PromptOTP shows a native macOS dialog asking for a fresh OTP.
// Returns the entered code, ErrDialogCancelled on cancel, or another error
// on failure.
//
// The OTP is shown in cleartext: it's a 30-second token, hiding it only
// hides typos.
//
// `title` is the Packxy-branded bold line shown beside the icon (NSAlert
// messageText); `detail` is the smaller-text body beneath it (NSAlert
// informativeText) carrying any explanation plus the call to action.
// Splitting them this way matches Apple's HIG and keeps the dialog
// readable instead of one wall of text.
//
// Two backends:
//
//   - When running inside the .app bundle (post-`packxy install`),
//     PromptOTP forks a short-lived child — `packxy _otpdialog` — that
//     calls NSAlert via cgo + AppKit. The child runs without Setsid in a
//     clean process, which is what NSAlert.runModal needs to come up
//     reliably. The child returns the OTP via stdout, exit 0 on OK, exit
//     2 on cancel.
//   - Running the bare CLI binary outside any bundle, falls back to
//     `osascript display dialog`. Works but shows the AppleScript
//     script-runner icon and momentarily places a script entry in the
//     menu bar.
func PromptOTP(title, detail string) (string, error) {
	if runningInsideBundle() {
		return promptOTPViaChild(title, detail)
	}

	// osascript can't render a separate "title + body" the way NSAlert
	// does, so fold both into one with a blank line in between for
	// readability.
	combined := title + "\n\n" + detail
	script := `tell me to activate
set d to display dialog ` + appleQuote(combined) +
		` default answer "" with title "Packxy"` +
		` buttons {"Cancel", "OK"} default button "OK" cancel button "Cancel"
return text returned of d`

	cmd := exec.Command("osascript", "-e", script)
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && strings.Contains(string(ee.Stderr), "User canceled") {
			return "", ErrDialogCancelled
		}
		return "", fmt.Errorf("osascript: %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}

// promptOTPViaChild spawns `packxy _otpdialog -title T -detail D` and
// reads the user's OTP from the child's stdout. Exit code 2 maps to
// ErrDialogCancelled.
func promptOTPViaChild(title, detail string) (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("locate self: %w", err)
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}

	cmd := exec.Command(exe, "_otpdialog",
		"-title", title,
		"-detail", detail)
	// Inherit stderr so any cgo / AppKit error is visible in watcher.log.
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && ee.ExitCode() == 2 {
			return "", ErrDialogCancelled
		}
		return "", fmt.Errorf("_otpdialog: %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}

// PromptOTPWithReason wraps PromptOTP with a title/detail pair tailored
// to the cause of the disconnection.
func PromptOTPWithReason(reason state.Reason) (string, error) {
	return PromptOTP(otpDialogTitle(reason), otpDialogDetail(reason))
}

// otpDialogTitle returns the Packxy-branded bold line shown beside the
// alert icon (NSAlert messageText). The `Packxy — …` prefix mirrors the
// drop-notification title so the two surfaces feel like the same product;
// the second clause names the situation in user-level terms (no "pppd",
// "openfortivpn", "peer reset" — those belong in the watcher log).
func otpDialogTitle(reason state.Reason) string {
	switch reason {
	case state.ReasonAuthExpired:
		return "Packxy — 2FA token expired"
	case state.ReasonNetworkDrop:
		return "Packxy — VPN connection dropped"
	case state.ReasonWake:
		return "Packxy — Mac woke from sleep"
	case state.ReasonStartupFailure:
		return "Packxy — VPN failed to start"
	default:
		return "Packxy — VPN disconnected"
	}
}

// otpDialogDetail returns the smaller-text body shown beneath the title
// (NSAlert informativeText): an optional explanation followed by the call
// to action. Different drops carry slightly different verbs ("retry"
// after a startup failure, "reconnect" otherwise) so the prompt matches
// the situation.
func otpDialogDetail(reason state.Reason) string {
	action := "Enter a fresh 2FA code to reconnect."
	if reason == state.ReasonStartupFailure {
		action = "Enter a fresh 2FA code to retry."
	}
	// ReasonWake is the only case where the title alone ("Mac woke from
	// sleep") doesn't tell the full story; spell out the consequence
	// before the action.
	if reason == state.ReasonWake {
		return "The VPN tunnel was dropped.\n\n" + action
	}
	return action
}

// OTPNotificationBody returns the short situation sentence shown as the
// body of the drop notification — same source of truth as otpDialogTitle
// (minus the `Packxy — ` brand prefix, since the notification carries the
// brand in its title).
func OTPNotificationBody(reason state.Reason) string {
	switch reason {
	case state.ReasonAuthExpired:
		return "2FA token expired."
	case state.ReasonNetworkDrop:
		return "VPN connection dropped."
	case state.ReasonWake:
		return "Mac woke from sleep — the VPN tunnel was dropped."
	case state.ReasonStartupFailure:
		return "VPN failed to start."
	default:
		return "VPN disconnected."
	}
}

// Notify posts a native macOS notification.
//
// When packxy runs from inside its .app bundle (after `packxy install`), it
// uses NSUserNotification via cgo: the notification is attributed to our
// bundle and picks up the packxy padlock icon. Otherwise (running the bare
// CLI binary outside the .app), it falls back to osascript — that path
// shows the AppleScript script-runner icon, but at least surfaces the
// notification reliably.
func Notify(title, body string) error {
	if runningInsideBundle() {
		sendNSNotification(title, body)
		return nil
	}
	script := `display notification ` + appleQuote(body) + ` with title ` + appleQuote(title)
	return exec.Command("osascript", "-e", script).Run()
}

// runningInsideBundle reports whether the running executable lives inside a
// macOS .app bundle (.../Contents/MacOS/...). Used to gate cgo notification
// calls — they only render correctly when the calling process has a bundle
// identity.
//
// Crucially, we resolve the path through any symlinks first: `packxy
// install` drops a `/usr/local/bin/packxy` symlink that points at the
// bundled binary, and a user typing `packxy start` would otherwise see
// `os.Executable()` return the symlink path — which doesn't contain
// "/Contents/MacOS/", causing us to mis-detect the bundle and fall back to
// osascript.
func runningInsideBundle() bool {
	exe, err := os.Executable()
	if err != nil {
		return false
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	return strings.Contains(exe, ".app/Contents/MacOS/")
}

// appleQuote returns an AppleScript-safe double-quoted literal of s.
func appleQuote(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return `"` + s + `"`
}
