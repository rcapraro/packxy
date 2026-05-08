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
// `headline` is the bold "what happened" line (used as NSAlert's
// messageText); `action` is the call to action shown beneath it (used as
// informativeText). Splitting them this way matches Apple's HIG layout
// for alerts and keeps the dialog readable instead of one wall of text.
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
func PromptOTP(headline, action string) (string, error) {
	if runningInsideBundle() {
		return promptOTPViaChild(headline, action)
	}

	// osascript can't render a separate "headline + body" the way NSAlert
	// does, so fold both into one with a blank line in between for
	// readability.
	combined := headline + "\n\n" + action
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

// promptOTPViaChild spawns `packxy _otpdialog -headline H -action A` and
// reads the user's OTP from the child's stdout. Exit code 2 maps to
// ErrDialogCancelled.
func promptOTPViaChild(headline, action string) (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("locate self: %w", err)
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}

	cmd := exec.Command(exe, "_otpdialog",
		"-headline", headline,
		"-action", action)
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

// PromptOTPWithReason wraps PromptOTP with a headline/action pair tailored
// to the cause of the disconnection.
func PromptOTPWithReason(reason state.Reason) (string, error) {
	return PromptOTP(OTPHeadline(reason), otpAction(reason))
}

// OTPHeadline returns the bold "what happened" line — used both at the
// top of the OTP dialog (as NSAlert.messageText) and as the body of the
// drop notification, so the two surfaces stay coherent. Single sentence
// ending with a period, per Apple's HIG.
func OTPHeadline(reason state.Reason) string {
	switch reason {
	case state.ReasonAuthExpired:
		return "Your 2FA token has expired (typically after a Mac sleep)."
	case state.ReasonNetworkDrop:
		return "VPN link dropped (link silent or peer reset)."
	case state.ReasonWake:
		return "Mac woke from sleep — VPN tunnel was dropped."
	case state.ReasonStartupFailure:
		return "openfortivpn failed to start."
	default:
		return "VPN disconnected."
	}
}

// otpAction returns the call-to-action line shown below the headline in
// the dialog. Different drops carry slightly different verbs ("retry"
// after a startup failure, "reconnect" otherwise) so the prompt matches
// the situation.
func otpAction(reason state.Reason) string {
	switch reason {
	case state.ReasonStartupFailure:
		return "Enter a fresh 2FA code to retry."
	default:
		return "Enter a fresh 2FA code to reconnect."
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
