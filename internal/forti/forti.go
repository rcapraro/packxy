// Package forti is the native macOS driver for openfortivpn.
//
// Lifecycle:
//
//	Start  → writes split-tunnel-safe config, launches openfortivpn,
//	         waits for ppp0 to come up.
//	Wait   → blocks until openfortivpn exits, returns a classified Reason.
//	Stop   → SIGTERM with timeout, then SIGKILL.
//
// Split tunneling is preserved: openfortivpn is configured with set-routes=0
// and set-dns=0; pppd is configured (via /etc/ppp/peers/packxy) with
// nodefaultroute. Callers (internal/macnet) add macOS routes and
// /etc/resolver entries explicitly for the CIDRs/domains in .env, leaving the
// host default route and /etc/resolv.conf untouched.
//
// Privileges: openfortivpn requires root on macOS to open /dev/ppp and create
// ppp0. Start invokes it via `sudo -n openfortivpn ...`, which is expected to
// be password-free thanks to the sudoers drop-in installed by `packxy install`.
// When already running as root, sudo is skipped.
package forti

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/rcapraro/packxy/internal/state"
)

// Iface is the PPP interface name openfortivpn creates on macOS.
const Iface = "ppp0"

// PeerName is the pppd peer file basename written under /etc/ppp/peers/.
// It carries the split-tunnel-safe pppd options (nodefaultroute, LCP echo)
// and is referenced by openfortivpn via --pppd-call.
const PeerName = "packxy"

// Default LCP echo settings: heartbeat every 10s, declare link dead after 6
// missed echoes (~60s tolerance window). Aggressive enough to keep NAT timeouts
// at bay and detect dead links quickly, lenient enough to absorb brief blips.
const (
	DefaultLCPEchoInterval = 10
	DefaultLCPEchoFailure  = 6
)

// authErrorRE matches openfortivpn output that indicates an authentication
// failure (typically a burned/expired OTP). Used by Classify to distinguish
// auth-class drops from generic link drops.
var authErrorRE = regexp.MustCompile(
	`(?i)Could not authenticate to gateway|check the password, client certificate|Authentication failed|Invalid (password|OTP)|OTP required|Permission denied`,
)

// errPattern is the user-facing error pattern used by ExtractError to surface
// a meaningful message when a connection attempt fails.
var errPattern = regexp.MustCompile(
	`(?i)Could not authenticate to gateway|Authentication failed|Invalid OTP|OTP required|Connection failed|check the password, client certificate|Invalid password|Certificate error|Gateway unreachable`,
)

var fatalPat = regexp.MustCompile(`(?i)ERROR:|error:|fatal`)

// Config describes one openfortivpn invocation.
type Config struct {
	Host        string
	Port        string // "443" if empty
	User        string
	Password    string
	OTP         string
	Realm       string
	TrustedCert string
	NoFTMPush   bool

	LCPEchoInterval int // 0 → DefaultLCPEchoInterval
	LCPEchoFailure  int // 0 → DefaultLCPEchoFailure

	StateDir string // defaults to state.Dir
}

// Process represents a running openfortivpn subprocess.
type Process struct {
	PID   int    // PID of openfortivpn (or sudo wrapper if not root)
	Iface string // "ppp0"
	IP    string // VPN-assigned IP, populated once ppp0 is up

	cmd     *exec.Cmd
	logPath string
	cfgPath string
	started time.Time
}

// LogPath returns the path of the openfortivpn log file for this process.
func (p *Process) LogPath() string { return p.logPath }

// Started returns the moment Start was invoked, used to scope log scans.
func (p *Process) Started() time.Time { return p.started }

// Start writes the config files and launches openfortivpn. Returns when ppp0
// is up with an IP, or with an error if openfortivpn fails to authenticate or
// set up the link within ~40s.
func Start(ctx context.Context, cfg Config) (*Process, error) {
	if cfg.LCPEchoInterval <= 0 {
		cfg.LCPEchoInterval = DefaultLCPEchoInterval
	}
	if cfg.LCPEchoFailure <= 0 {
		cfg.LCPEchoFailure = DefaultLCPEchoFailure
	}
	if cfg.StateDir == "" {
		cfg.StateDir = state.Dir
	}
	if err := os.MkdirAll(cfg.StateDir, 0o755); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", cfg.StateDir, err)
	}

	cfgPath := filepath.Join(cfg.StateDir, "openfortivpn.conf")
	logPath := filepath.Join(cfg.StateDir, "openfortivpn.log")

	if err := writeOpenfortivpnConfig(cfgPath, cfg); err != nil {
		return nil, err
	}
	if err := EnsurePeerFile(cfg.LCPEchoInterval, cfg.LCPEchoFailure); err != nil {
		return nil, err
	}
	if err := os.WriteFile(logPath, nil, 0o644); err != nil {
		return nil, fmt.Errorf("truncate %s: %w", logPath, err)
	}

	// Capture the default route BEFORE openfortivpn touches the routing table.
	// macOS pppd / SystemConfiguration installs a new default route via ppp0
	// when the interface comes up, which would put the host in full-tunnel
	// mode. We restore the original default after ppp0 is up so split
	// tunneling is preserved.
	origDefault := captureDefaultRoute()

	logF, err := os.OpenFile(logPath, os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", logPath, err)
	}

	args := []string{"-c", cfgPath, "--pppd-call=" + PeerName, "--persistent=0"}
	if cfg.NoFTMPush {
		args = append(args, "--no-ftm-push")
	}

	var cmd *exec.Cmd
	if os.Geteuid() == 0 {
		cmd = exec.Command("openfortivpn", args...)
	} else {
		cmd = exec.Command("sudo", append([]string{"-n", "openfortivpn"}, args...)...)
	}
	cmd.Stdout = logF
	cmd.Stderr = logF

	if err := cmd.Start(); err != nil {
		_ = logF.Close()
		return nil, fmt.Errorf("launch openfortivpn: %w", err)
	}
	_ = logF.Close()

	p := &Process{
		PID:     cmd.Process.Pid,
		Iface:   Iface,
		cmd:     cmd,
		logPath: logPath,
		cfgPath: cfgPath,
		started: time.Now(),
	}

	ip, err := waitForInterface(ctx, p, 40*time.Second)
	if err != nil {
		_ = stopCmd(cmd, 3*time.Second)
		return nil, err
	}
	p.IP = ip

	// macOS workaround: despite `nodefaultroute`, the SystemConfiguration
	// framework installs a default route via ppp0 when the interface comes
	// up, replacing the host's normal default. Restore the original default
	// so only the explicit VPN_ROUTES (added later by macnet.AddRoute)
	// reach ppp0. Best-effort: failure leaves full-tunnel mode but the VPN
	// itself is up.
	restoreDefaultIfHijacked(origDefault)

	return p, nil
}

// defaultRouteInfo captures the gateway + interface of the active IPv4
// default route. Empty Iface means no default route is set.
type defaultRouteInfo struct {
	Gateway string
	Iface   string
}

// captureDefaultRoute reads the current default route via `route -n get
// default`. Returns an empty struct if no default route exists or the command
// fails — callers should treat empty as "nothing to restore".
func captureDefaultRoute() defaultRouteInfo {
	out, err := exec.Command("route", "-n", "get", "default").Output()
	if err != nil {
		return defaultRouteInfo{}
	}
	var d defaultRouteInfo
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "gateway:"):
			d.Gateway = strings.TrimSpace(strings.TrimPrefix(line, "gateway:"))
		case strings.HasPrefix(line, "interface:"):
			d.Iface = strings.TrimSpace(strings.TrimPrefix(line, "interface:"))
		}
	}
	return d
}

// restoreDefaultIfHijacked reinstates the original default route iff the
// current default has been replaced by one pointing at ppp0. Idempotent.
//
// Two-step: delete the hijacking default-via-ppp0, then re-add the captured
// original. We never delete a default that isn't ours to undo.
func restoreDefaultIfHijacked(orig defaultRouteInfo) {
	if orig.Iface == "" || orig.Iface == Iface {
		return
	}
	current := captureDefaultRoute()
	if current.Iface != Iface {
		return // pppd didn't hijack — nothing to do.
	}
	runRoute := func(args ...string) {
		if os.Geteuid() == 0 {
			_ = exec.Command("route", args...).Run()
			return
		}
		full := append([]string{"-n", "route"}, args...)
		_ = exec.Command("sudo", full...).Run()
	}
	runRoute("-q", "delete", "default")
	if orig.Gateway != "" {
		runRoute("-q", "add", "-net", "default", orig.Gateway, "-interface", orig.Iface)
	} else {
		runRoute("-q", "add", "-net", "default", "-interface", orig.Iface)
	}
}

// Wait blocks until the openfortivpn process exits and returns a classified
// Reason. Returns context.Canceled / DeadlineExceeded if the wait is interrupted.
func Wait(ctx context.Context, p *Process) (state.Reason, error) {
	if p == nil || p.cmd == nil {
		return state.ReasonUnknown, errors.New("nil process")
	}

	done := make(chan error, 1)
	go func() { done <- p.cmd.Wait() }()

	select {
	case <-ctx.Done():
		return state.ReasonUnknown, ctx.Err()
	case err := <-done:
		return Classify(err, p.logPath), nil
	}
}

// Stop sends SIGTERM, waits up to 3s, then SIGKILL. Idempotent.
func Stop(p *Process) error {
	if p == nil || p.cmd == nil || p.cmd.Process == nil {
		return nil
	}
	return stopCmd(p.cmd, 3*time.Second)
}

// Status returns "running" if the process is alive and ppp0 has an IP, or a
// terse status string otherwise.
func Status(p *Process) (string, string) {
	if p == nil || p.cmd == nil || p.cmd.Process == nil {
		return "absent", ""
	}
	if !state.ProcessAlive(p.PID) {
		return "exited", ""
	}
	ip, err := readPPP0IP()
	if err != nil || ip == "" {
		return "running", ""
	}
	return "running", ip
}

// Classify maps a process exit error + log content to a Reason.
//
//   - log contains an auth-class error  → ReasonAuthExpired
//   - process exited normally with code 0 → ReasonUnknown (clean exit)
//   - process exited with non-zero code   → ReasonNetworkDrop
//   - process killed by signal            → ReasonNetworkDrop
func Classify(err error, logPath string) state.Reason {
	if logsContainAuthError(logPath) {
		return state.ReasonAuthExpired
	}
	if err == nil {
		return state.ReasonUnknown
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return state.ReasonNetworkDrop
	}
	return state.ReasonNetworkDrop
}

// ClassifyFromLog returns a Reason based purely on log file content. Used by
// the watcher when it doesn't have a process-exit error to inspect (it polls
// the openfortivpn PID rather than waiting on it directly).
func ClassifyFromLog(logPath string) state.Reason {
	if logsContainAuthError(logPath) {
		return state.ReasonAuthExpired
	}
	return state.ReasonNetworkDrop
}

// ExtractError returns up to 3 lines from the log that look like errors,
// suitable for surfacing to the user.
func ExtractError(logPath string) string {
	b, err := os.ReadFile(logPath)
	if err != nil {
		return "Could not read openfortivpn log."
	}
	lines := strings.Split(string(b), "\n")
	var matches []string
	for _, l := range lines {
		if errPattern.MatchString(l) {
			matches = append(matches, l)
		}
	}
	if len(matches) == 0 {
		for _, l := range lines {
			if fatalPat.MatchString(l) {
				matches = append(matches, l)
			}
		}
	}
	if len(matches) == 0 {
		return "Connection timed out or failed without a specific error."
	}
	if len(matches) > 3 {
		matches = matches[len(matches)-3:]
	}
	return strings.Join(matches, "\n")
}

// CleanupPeerFile removes the /etc/ppp/peers/packxy file. Called by
// `packxy uninstall`.
func CleanupPeerFile() error {
	target := filepath.Join("/etc/ppp/peers", PeerName)
	if _, err := os.Stat(target); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if os.Geteuid() == 0 {
		return os.Remove(target)
	}
	return exec.Command("sudo", "-n", "rm", "-f", target).Run()
}

// =====================================================================
//  install / uninstall — one-time setup
// =====================================================================

// SudoersPath is where the packxy sudoers drop-in lives. The drop-in grants
// the current user permission to run openfortivpn without a password, which
// is what allows the (user-level) watcher to restart the VPN process after a
// drop without prompting for sudo each time (sudo cache expires after ~5 min).
const SudoersPath = "/etc/sudoers.d/packxy"

// Install writes the sudoers drop-in and the pppd peer file. It is the
// `packxy install` command — run once per machine. Both files are then
// referenced (read-only) by every subsequent `packxy start`.
//
// `username` is the user that should be allowed to run openfortivpn without
// a password. `binPath` is the absolute path of the openfortivpn binary
// (typically /opt/homebrew/bin/openfortivpn or /usr/local/bin/openfortivpn).
//
// The function is idempotent: rerunning replaces the existing files.
func Install(username, binPath string, interval, failure int) error {
	if username == "" {
		return errors.New("install: username is required")
	}
	if binPath == "" {
		return errors.New("install: openfortivpn binary path is required")
	}

	if err := EnsurePeerFile(interval, failure); err != nil {
		return fmt.Errorf("write peer file: %w", err)
	}

	body := fmt.Sprintf(`# Generated by packxy. Allows %s to run openfortivpn without a password
# so the packxy watcher can restart the VPN after a drop without prompting.
# pkill is granted only for the openfortivpn process so the watcher can
# pre-stop it on macOS sleep notifications and on teardown.
# Remove this file with `+"`packxy uninstall`"+` or `+"`sudo rm %s`"+`.
%s ALL=(root) NOPASSWD: %s, /usr/bin/pkill -x openfortivpn, /usr/bin/pkill -[0-9]* -x openfortivpn, /usr/bin/pkill -TERM -x openfortivpn, /usr/bin/pkill -KILL -x openfortivpn
`, username, SudoersPath, username, binPath)

	tmp, err := os.CreateTemp("", "packxy-sudoers-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.WriteString(body); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}

	if out, err := exec.Command("sudo", "-n", "visudo", "-cf", tmpName).CombinedOutput(); err != nil {
		return fmt.Errorf("visudo validation failed: %v: %s", err, strings.TrimSpace(string(out)))
	}

	if out, err := exec.Command("sudo", "-n", "install", "-m", "0440", "-o", "root", "-g", "wheel", tmpName, SudoersPath).CombinedOutput(); err != nil {
		return fmt.Errorf("install %s: %v: %s", SudoersPath, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// Uninstall removes the sudoers drop-in and the pppd peer file.
func Uninstall() error {
	if err := CleanupPeerFile(); err != nil {
		return fmt.Errorf("remove peer file: %w", err)
	}
	if _, err := os.Stat(SudoersPath); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if os.Geteuid() == 0 {
		return os.Remove(SudoersPath)
	}
	if out, err := exec.Command("sudo", "-n", "rm", "-f", SudoersPath).CombinedOutput(); err != nil {
		return fmt.Errorf("rm %s: %v: %s", SudoersPath, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// IsInstalled reports whether both the sudoers drop-in and the pppd peer file
// are present. `packxy start` checks this and offers to run install if not.
func IsInstalled() bool {
	if _, err := os.Stat(SudoersPath); err != nil {
		return false
	}
	if _, err := os.Stat(filepath.Join("/etc/ppp/peers", PeerName)); err != nil {
		return false
	}
	return true
}

// FindBinary returns the absolute path of the openfortivpn binary in PATH,
// or an error if it cannot be found.
func FindBinary() (string, error) {
	p, err := exec.LookPath("openfortivpn")
	if err != nil {
		return "", fmt.Errorf("openfortivpn not found in PATH — install with `brew install openfortivpn`: %w", err)
	}
	return p, nil
}

// =====================================================================
//  config file generation
// =====================================================================

func writeOpenfortivpnConfig(path string, cfg Config) error {
	port := cfg.Port
	if port == "" {
		port = "443"
	}
	var b strings.Builder
	b.WriteString("# Generated by packxy — split tunneling preserved.\n")
	b.WriteString("# openfortivpn does NOT add routes or modify DNS; packxy\n")
	b.WriteString("# (via internal/macnet) handles routes and /etc/resolver.\n")
	b.WriteString("set-routes = 0\n")
	b.WriteString("set-dns = 0\n")
	b.WriteString("pppd-use-peerdns = 0\n")
	fmt.Fprintf(&b, "host = %s\n", cfg.Host)
	fmt.Fprintf(&b, "port = %s\n", port)
	fmt.Fprintf(&b, "username = %s\n", cfg.User)
	fmt.Fprintf(&b, "password = %s\n", cfg.Password)
	if cfg.TrustedCert != "" {
		fmt.Fprintf(&b, "trusted-cert = %s\n", cfg.TrustedCert)
	}
	if cfg.Realm != "" {
		fmt.Fprintf(&b, "realm = %s\n", cfg.Realm)
	}
	if cfg.OTP != "" {
		fmt.Fprintf(&b, "otp = %s\n", cfg.OTP)
	}
	return os.WriteFile(path, []byte(b.String()), 0o600)
}

// EnsurePeerFile ensures /etc/ppp/peers/packxy exists with the
// split-tunnel-safe pppd options. The file is normally written by
// `packxy install`; this function is idempotent and rewrites the file when
// needed (e.g. when LCP echo settings change).
//
// 230400          — explicit baud rate. macOS BSD pppd refuses to start over
//                   a pty without one ("Baud rate for /dev/ttysNNN is 0;
//                   need explicit baud rate"). The number is irrelevant —
//                   pppd just needs *some* explicit value. Linux pppd
//                   doesn't require this. See openfortivpn issues #759, #1208.
// nodefaultroute  — pppd does NOT replace the macOS default route.
// lcp-echo-*      — keepalive heartbeat, fast dead-link detection.
//
// Note: macOS BSD pppd does not have a `nodns` option (Linux-only). The
// openfortivpn config passes `pppd-use-peerdns = 0`, which means pppd is
// never told to request DNS from the peer in the first place — so DNS is
// naturally not propagated to /etc/resolv.conf.
func EnsurePeerFile(interval, failure int) error {
	if interval <= 0 {
		interval = DefaultLCPEchoInterval
	}
	if failure <= 0 {
		failure = DefaultLCPEchoFailure
	}
	body := fmt.Sprintf(`# Generated by packxy — split-tunnel-safe pppd options.
230400
nodefaultroute
lcp-echo-interval %d
lcp-echo-failure %d
`, interval, failure)

	target := filepath.Join("/etc/ppp/peers", PeerName)

	// Skip rewriting if content already matches — avoids needless sudo calls.
	if existing, err := os.ReadFile(target); err == nil && string(existing) == body {
		return nil
	}

	if os.Geteuid() == 0 {
		if err := os.MkdirAll("/etc/ppp/peers", 0o755); err != nil {
			return fmt.Errorf("mkdir /etc/ppp/peers: %w", err)
		}
		return os.WriteFile(target, []byte(body), 0o644)
	}

	if err := exec.Command("sudo", "-n", "mkdir", "-p", "/etc/ppp/peers").Run(); err != nil {
		return fmt.Errorf("sudo mkdir /etc/ppp/peers: %w", err)
	}
	var stderr bytes.Buffer
	cmd := exec.Command("sudo", "-n", "tee", target)
	cmd.Stdin = strings.NewReader(body)
	cmd.Stdout = io.Discard
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("write %s: %v: %s", target, err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

// =====================================================================
//  process and interface helpers
// =====================================================================

// waitForInterface polls for ppp0 to appear with an IP. Aborts early if the
// process has died or an auth-class error appears in the log (avoids burning
// the full timeout on a doomed connection).
func waitForInterface(ctx context.Context, p *Process, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		if !state.ProcessAlive(p.PID) {
			return "", errors.New("openfortivpn exited before ppp0 came up")
		}
		if logsContainAuthError(p.logPath) {
			return "", errors.New("authentication error in openfortivpn log")
		}
		ip, err := readPPP0IP()
		if err == nil && ip != "" {
			return ip, nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return "", fmt.Errorf("timed out waiting for %s", Iface)
}

// readPPP0IP returns the IPv4 address assigned to ppp0, or "" if the interface
// doesn't exist yet or has no IP.
func readPPP0IP() (string, error) {
	out, err := exec.Command("ifconfig", Iface).Output()
	if err != nil {
		// "no such interface" is expected before ppp0 comes up.
		return "", nil
	}
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "inet ") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		// "inet 10.212.134.220 --> 10.212.134.1 ..."
		return fields[1], nil
	}
	return "", nil
}

func logsContainAuthError(logPath string) bool {
	b, err := os.ReadFile(logPath)
	if err != nil {
		return false
	}
	return authErrorRE.Match(b)
}

// stopCmd sends SIGTERM, waits up to timeout for the process to exit, then
// sends SIGKILL. Returns nil if the process is gone, an error otherwise.
//
// When openfortivpn was launched via `sudo`, signals sent to the sudo wrapper
// are forwarded to the openfortivpn child. When packxy is already root, the
// signal goes straight to openfortivpn.
func stopCmd(cmd *exec.Cmd, timeout time.Duration) error {
	if cmd == nil || cmd.Process == nil {
		return nil
	}
	pid := cmd.Process.Pid

	// SIGTERM via the appropriate authority. As user, the sudo wrapper is owned
	// by root, so we need sudo to signal it.
	if os.Geteuid() == 0 {
		_ = cmd.Process.Signal(syscall.SIGTERM)
	} else {
		_ = exec.Command("sudo", "-n", "kill", "-TERM", fmt.Sprint(pid)).Run()
	}

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if !state.ProcessAlive(pid) {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}

	if os.Geteuid() == 0 {
		_ = cmd.Process.Kill()
	} else {
		_ = exec.Command("sudo", "-n", "kill", "-KILL", fmt.Sprint(pid)).Run()
	}
	return nil
}
