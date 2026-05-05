package macnet

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"

	"github.com/rcapraro/packxy/internal/state"
)

// ErrDialogCancelled is returned by PromptOTP when the user dismisses the dialog.
var ErrDialogCancelled = errors.New("dialog cancelled")

// PromptOTP shows a native macOS dialog asking for a fresh OTP.
// Returns the entered code, ErrDialogCancelled on cancel, or another error on
// osascript failure.
//
// The OTP is shown in cleartext: it's a 30-second token, hiding it only
// hides typos.
func PromptOTP(message string) (string, error) {
	script := `set d to display dialog ` + appleQuote(message) +
		` default answer "" with title "packxy"` +
		` buttons {"Cancel", "OK"} default button "OK" cancel button "Cancel"` +
		"\nreturn text returned of d"

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

// PromptOTPWithReason wraps PromptOTP with a message tailored to the cause of
// the disconnection.
func PromptOTPWithReason(reason state.Reason) (string, error) {
	return PromptOTP(otpMessage(reason))
}

// OTPDropMessage returns a short user-facing line summarising why the VPN
// dropped — suitable for a notification body.
func OTPDropMessage(reason state.Reason) string {
	switch reason {
	case state.ReasonAuthExpired:
		return "2FA token expired (likely after Mac sleep). Enter a fresh code to reconnect."
	case state.ReasonNetworkDrop:
		return "VPN connection lost after several reconnect attempts. A new 2FA code is needed."
	default:
		return "VPN disconnected. Enter a fresh 2FA code to reconnect."
	}
}

func otpMessage(reason state.Reason) string {
	switch reason {
	case state.ReasonAuthExpired:
		return "Your 2FA token has expired (typically after a Mac sleep).\nEnter a fresh code to reconnect:"
	case state.ReasonNetworkDrop:
		return "VPN connection lost after several reconnect attempts.\nEnter a fresh 2FA code:"
	default:
		return "VPN disconnected. Enter a fresh 2FA code to reconnect:"
	}
}

// Notify posts a native macOS notification.
func Notify(title, body string) error {
	script := `display notification ` + appleQuote(body) + ` with title ` + appleQuote(title)
	return exec.Command("osascript", "-e", script).Run()
}

// appleQuote returns an AppleScript-safe double-quoted literal of s.
func appleQuote(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return `"` + s + `"`
}
