// Command packxy is a self-contained macOS split-tunneling launcher for
// FortiGate VPN.
//
// It runs openfortivpn natively as a subprocess, creating a ppp0 interface
// on the host. macOS routes for the configured CIDRs are pointed at ppp0,
// and /etc/resolver entries are written for the configured internal
// domains. The default route and /etc/resolv.conf are left untouched —
// openfortivpn is configured with set-routes=0 / set-dns=0 and pppd with
// nodefaultroute to preserve split tunneling.
//
// User-facing subcommands:
//
//	packxy install   — one-time: install sudoers drop-in + /etc/ppp/peers/packxy
//	                   (and /usr/local/bin/packxy symlink when run from .app)
//	packxy uninstall — remove the install artifacts
//	packxy start     — launch openfortivpn, add routes/DNS, arm the watcher,
//	                   and (from the .app bundle) the menu-bar tray
//	packxy stop      — tear everything down
//	packxy status    — show watcher / VPN / tray / routes state
//
// Internal subcommands (re-exec'd by `packxy start` itself):
//
//	packxy _watcher    — Setsid'd daemon that monitors openfortivpn, reacts
//	                     to IOKit sleep/wake notifications, and re-prompts
//	                     OTP via _otpdialog on drop.
//	packxy _otpdialog  — short-lived child of the watcher that bootstraps
//	                     NSApp and shows a native NSAlert with a text input
//	                     (the watcher itself can't reliably runModal a
//	                     dialog from a Setsid'd process).
//	packxy _tray       — long-lived menu-bar status item (NSStatusItem) that
//	                     polls /tmp/packxy state and renders an icon plus a
//	                     dropdown menu. Spawned only when `packxy start` is
//	                     itself invoked from the .app bundle.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/rcapraro/packxy/internal/envcfg"
	"github.com/rcapraro/packxy/internal/forti"
	"github.com/rcapraro/packxy/internal/macnet"
	"github.com/rcapraro/packxy/internal/state"
	"github.com/rcapraro/packxy/internal/ui"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}
	switch os.Args[1] {
	case "start":
		os.Exit(runStart())
	case "stop":
		os.Exit(runStop())
	case "status":
		os.Exit(runStatus())
	case "install":
		os.Exit(runInstall())
	case "uninstall":
		os.Exit(runUninstall())
	case "_watcher":
		os.Exit(runWatcher(os.Args[2:]))
	case "_otpdialog":
		os.Exit(runOTPDialog(os.Args[2:]))
	case "_tray":
		os.Exit(runTray(os.Args[2:]))
	case "-h", "--help", "help":
		usage()
		os.Exit(0)
	default:
		usage()
		os.Exit(1)
	}
}

func usage() {
	ui.Header()
	ui.Section("Usage")
	ui.Line("packxy <command>")

	ui.Section("Commands")
	ui.KeyValue("install", "One-time setup (sudoers drop-in + pppd peer file)")
	ui.KeyValue("uninstall", "Remove the install artifacts")
	ui.KeyValue("start", "Connect to VPN and enable split tunneling")
	ui.KeyValue("stop", "Disconnect VPN and remove split tunneling")
	ui.KeyValue("status", "Show watcher and VPN state")

	ui.Section("Options")
	ui.KeyValue("-h, --help", "Show this message")
	fmt.Println()
}

// =====================================================================
//  install / uninstall
// =====================================================================

func runInstall() int {
	bin, err := forti.FindBinary()
	if err != nil {
		ui.PrintErr("%v", err)
		return 1
	}

	u, err := user.Current()
	if err != nil {
		ui.PrintErr("could not determine current user: %v", err)
		return 1
	}

	bundleExe, bundled := bundleExecutable()
	cfgDefault, _ := envcfg.DefaultPath()

	ui.Page()
	ui.Header()
	ui.Section("Install")
	ui.StepInfo("This will write:")
	ui.Line(fmt.Sprintf("  • %s (sudoers drop-in)", forti.SudoersPath))
	ui.Line(fmt.Sprintf("  • /etc/ppp/peers/%s (pppd options)", forti.PeerName))
	if bundled {
		ui.Line(fmt.Sprintf("  • %s → %s (CLI symlink)", cliSymlinkPath, bundleExe))
	}
	if cfgDefault != "" {
		ui.Line(fmt.Sprintf("  • %s (starter config — only if missing)", cfgDefault))
	}
	fmt.Println()
	ui.StepInfo("sudo password may be required.")

	if err := macnet.SudoValidate(); err != nil {
		ui.PrintErr("sudo authentication failed.")
		return 1
	}

	if err := forti.Install(u.Username, bin, forti.DefaultLCPEchoInterval, forti.DefaultLCPEchoFailure); err != nil {
		ui.PrintErr("install failed: %v", err)
		return 1
	}
	ui.StepOK("Installed sudoers drop-in for " + u.Username)
	ui.StepOK("Installed /etc/ppp/peers/" + forti.PeerName)

	if bundled {
		if err := installCLISymlink(bundleExe); err != nil {
			ui.StepWarn("CLI symlink not created: " + err.Error())
		} else {
			ui.StepOK("Symlinked " + cliSymlinkPath + " → bundle binary")
		}
	}

	switch cfgPath, created, err := envcfg.SeedDefault(); {
	case err != nil:
		ui.StepWarn("Starter config not written: " + err.Error())
	case created:
		ui.StepOK("Wrote starter config " + cfgPath + " — edit it before `packxy start`")
	default:
		ui.StepInfo("Config already present at " + cfgPath + " — left untouched")
	}

	fmt.Println()
	return 0
}

// cliSymlinkPath is where the .app installer drops a `packxy` symlink so
// users can invoke the CLI from anywhere on $PATH without typing the full
// bundle path.
const cliSymlinkPath = "/usr/local/bin/packxy"

// bundleExecutable reports whether the running binary lives inside a .app
// bundle, and if so returns the absolute path to that binary. Anything
// else means the user is running the bare CLI without bundle benefits.
//
// Resolves symlinks before testing — `packxy install` drops a
// /usr/local/bin/packxy symlink at the bundled binary, so a user typing
// `packxy start` would otherwise see os.Executable() return the symlink
// path (which doesn't match ".app/Contents/MacOS/") and never get the
// bundle-only features (tray, native dialogs).
func bundleExecutable() (string, bool) {
	exe, err := os.Executable()
	if err != nil {
		return "", false
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	if !strings.Contains(exe, ".app/Contents/MacOS/") {
		return "", false
	}
	return exe, true
}

// installCLISymlink writes a `/usr/local/bin/packxy` symlink pointing at
// the bundled executable. Idempotent: a correct existing symlink is a
// no-op; a wrong one is replaced.
func installCLISymlink(target string) error {
	if existing, err := os.Readlink(cliSymlinkPath); err == nil && existing == target {
		return nil
	}
	if err := exec.Command("sudo", "-n", "mkdir", "-p", filepath.Dir(cliSymlinkPath)).Run(); err != nil {
		return fmt.Errorf("mkdir %s: %w", filepath.Dir(cliSymlinkPath), err)
	}
	if err := exec.Command("sudo", "-n", "rm", "-f", cliSymlinkPath).Run(); err != nil {
		return fmt.Errorf("rm old symlink: %w", err)
	}
	if err := exec.Command("sudo", "-n", "ln", "-s", target, cliSymlinkPath).Run(); err != nil {
		return fmt.Errorf("ln -s: %w", err)
	}
	return nil
}

func runUninstall() int {
	ui.Page()
	ui.Header()
	ui.Section("Uninstall")
	ui.StepInfo("sudo password may be required.")
	if err := macnet.SudoValidate(); err != nil {
		ui.PrintErr("sudo authentication failed.")
		return 1
	}
	if err := forti.Uninstall(); err != nil {
		ui.PrintErr("uninstall failed: %v", err)
		return 1
	}
	ui.StepOK("Removed packxy install artifacts")

	// Remove the CLI symlink if it points at any packxy bundle. We don't
	// touch the .app itself — the user installed it somewhere of their
	// choosing and removing it isn't our call.
	if existing, err := os.Readlink(cliSymlinkPath); err == nil &&
		strings.Contains(existing, ".app/Contents/MacOS/packxy") {
		if err := exec.Command("sudo", "-n", "rm", "-f", cliSymlinkPath).Run(); err == nil {
			ui.StepOK("Removed " + cliSymlinkPath)
		}
	}

	fmt.Println()
	return 0
}

// =====================================================================
//  start
// =====================================================================

func runStart() int {
	cfgPath, err := envcfg.Resolve()
	if err != nil {
		def, _ := envcfg.DefaultPath()
		ui.PrintErr("%v", err)
		ui.PrintErr("Run `packxy install` to drop a starter config at %s, then edit it.", def)
		return 1
	}

	cfg, err := envcfg.Load(cfgPath)
	if err != nil {
		ui.PrintErr("error loading %s: %v", cfgPath, err)
		return 1
	}

	if !cfg.HasSplitTunneling() {
		ui.PrintErr("VPN_ROUTES is not configured in %s — split tunneling cannot start.", cfgPath)
		ui.PrintErr("Set VPN_ROUTES (and ideally VPN_DNS, VPN_DOMAINS) and try again.")
		return 1
	}

	if !forti.IsInstalled() {
		ui.PrintErr("Packxy is not installed — run `packxy install` first.")
		return 1
	}

	if _, err := forti.FindBinary(); err != nil {
		ui.PrintErr("%v", err)
		return 1
	}

	// Cleanup before we ask the user anything — otherwise a leftover
	// watcher from a previous `packxy start` would react to our
	// openfortivpn kill by popping its own OTP dialog and the user
	// would get two prompts (and probably enter the code into the
	// wrong one).
	silentTeardown()

	ui.StepInfo("sudo is needed for routes and DNS entries.")
	if err := macnet.SudoValidate(); err != nil {
		ui.PrintErr("sudo authentication failed.")
		return 1
	}

	ui.Page()
	ui.Header()
	ui.Section("Credentials")

	if err := promptCredentials(cfg); err != nil {
		ui.PrintErr("input cancelled: %v", err)
		return 1
	}
	exportEnv(cfg)

	ui.Page()
	ui.Header()
	ui.Section("Pipeline")

	fcfg := fortiConfig(cfg)

	var p *forti.Process
	dur, err := ui.Spin("Connecting to VPN...", func() error {
		var e error
		p, e = forti.Start(context.Background(), fcfg)
		return e
	})
	if err != nil {
		ui.Page()
		ui.Header()
		ui.Banner(ui.ColFail, "✖ Connection Failed", "")
		ui.Tagline(ui.ColFail, "Can't Pack today... check credentials 🔧")
		ui.ErrorCard(forti.ExtractError(filepath.Join(state.Dir, "openfortivpn.log")))
		fmt.Println()
		ui.MutedHint("     📋  Full log: cat /tmp/packxy/openfortivpn.log")
		fmt.Println()
		ui.PressEnter("Press Enter to exit...")
		return 1
	}
	ui.StepOK("VPN connected (ppp0 "+p.IP+")", dur)
	_ = state.WriteVPNPID(p.PID)

	routes := addRoutes(forti.Iface, cfg.VPNRoutes)
	if routes != "" {
		ui.StepOK("Routes  " + routes)
	}

	domains := configureDNS(cfg)
	if domains != "" {
		ui.StepOK("DNS     " + domains)
	}

	if err := spawnWatcher(); err != nil {
		ui.StepWarn("Watcher not started: " + err.Error())
	} else {
		ui.StepOK("Watcher armed (re-prompts OTP if VPN drops)")
	}

	// Tray indicator: only meaningful when packxy was launched from the
	// .app bundle (otherwise the icon won't carry our identity and the
	// menu won't render reliably). Skip silently for the bare-CLI flow.
	if _, bundled := bundleExecutable(); bundled {
		if err := spawnTray(); err != nil {
			ui.StepWarn("Menu-bar tray not started: " + err.Error())
		} else {
			ui.StepOK("Menu-bar indicator enabled")
		}
	}

	ui.Page()
	ui.Header()
	ui.Banner(ui.ColOK, "🔒 Connected", "All traffic to VPN networks is routed")
	ui.Tagline(ui.ColOK, "All Packed up and ready to tunnel! 🚀")
	ui.Section("Connection")

	card := []ui.CardLine{
		{Icon: "🌐", Label: "VPN IP", Value: p.IP},
		{Icon: "🔌", Label: "Iface", Value: forti.Iface},
		{Icon: "🔀", Label: "Routes", Value: routes},
	}
	if domains != "" {
		card = append(card, ui.CardLine{Icon: "🔍", Label: "DNS", Value: domains})
	}
	ui.SummaryCard(ui.ColOK, card)
	ui.Footer()
	return 0
}

// promptCredentials reconciles the on-disk config with what the VPN
// session needs.
//
// Anything already set in the config is shown back as a "📄 From config"
// card — the user gets a visual confirmation of what's about to be sent
// without having to retype it. Only fields the user truly needs to enter
// are prompted for (always including the OTP, which is a 30 s single-use
// code that has no business living in a file).
//
// The card and the huh-styled prompts are visually distinct (border vs.
// no border, different colour palette) so the boundary between
// "remembered" and "to enter" is unambiguous.
func promptCredentials(cfg *envcfg.Config) error {
	var card []ui.CardLine
	add := func(icon, label, value string) {
		if value != "" {
			card = append(card, ui.CardLine{Icon: icon, Label: label, Value: value})
		}
	}
	add("🌐", "Hostname", cfg.Host)
	add("🚪", "Port", cfg.Port)
	add("👤", "Username", cfg.User)
	if cfg.Password != "" {
		add("🔑", "Password", "••••••••")
	}
	if cfg.TrustedCert != "" {
		add("📜", "Trusted Cert", truncate(cfg.TrustedCert, 28))
	}
	if cfg.Realm != "" {
		add("🎫", "Realm", cfg.Realm)
	}
	if len(card) > 0 {
		ui.StepInfo("From config:")
		ui.SummaryCard(ui.ColMuted, card)
		fmt.Println()
	}

	if cfg.Host == "" {
		v, err := ui.Input("  VPN Hostname", "vpn.company.com", "")
		if err != nil {
			return err
		}
		cfg.Host = v
	}
	if cfg.Port == "" {
		v, err := ui.Input("  VPN Port", "443", "")
		if err != nil {
			return err
		}
		cfg.Port = v
	}
	if cfg.User == "" {
		v, err := ui.Input("  Username", "john.doe", "")
		if err != nil {
			return err
		}
		cfg.User = v
	}
	if cfg.Password == "" {
		v, err := ui.Password("  Password", "••••••••", "")
		if err != nil {
			return err
		}
		cfg.Password = v
	}
	if cfg.TrustedCert == "" {
		v, err := ui.Input("  Trusted Certificate (optional)", "sha256 fingerprint...", "")
		if err != nil {
			return err
		}
		cfg.TrustedCert = v
	}

	v, err := ui.SixDigitOTP("")
	if err != nil {
		return err
	}
	cfg.OTP = v

	return nil
}

// truncate shortens a long string for display, replacing the chopped-off
// tail with a single ellipsis. Used for the SHA-256 trusted-cert reminder.
func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "…"
}

func exportEnv(cfg *envcfg.Config) {
	setenv := func(k, v string) {
		_ = os.Setenv(k, v)
	}
	setenv("FORTI_HOST", cfg.Host)
	setenv("FORTI_PORT", cfg.Port)
	setenv("FORTI_USER", cfg.User)
	setenv("FORTI_PASS", cfg.Password)
	setenv("FORTI_OTP", cfg.OTP)
	setenv("FORTI_TRUSTED_CERT", cfg.TrustedCert)
	setenv("FORTI_REALM", cfg.Realm)
	setenv("FORTI_NO_FTM_PUSH", cfg.NoFTMPush)
	setenv("FORTI_OTP_PROMPT", cfg.OTPPrompt)
}

// fortiConfig builds a forti.Config from the current envcfg. The OTP is
// consumed from FORTI_OTP and intended to be burned on the next start; the
// watcher prompts a fresh one on each reconnect.
func fortiConfig(cfg *envcfg.Config) forti.Config {
	return forti.Config{
		Host:        cfg.Host,
		Port:        cfg.Port,
		User:        cfg.User,
		Password:    cfg.Password,
		OTP:         cfg.OTP,
		Realm:       cfg.Realm,
		TrustedCert: cfg.TrustedCert,
		OTPPrompt:   cfg.OTPPrompt,
		NoFTMPush:   cfg.NoFTMPush == "1",
	}
}

// silentTeardown undoes any leftover state from a previous `packxy
// start` that wasn't paired with `packxy stop` (or that crashed before
// stop ran). Called at the very top of runStart, before SudoValidate,
// before promptCredentials — so the rest of runStart starts from a
// clean slate.
//
// The kill order matters:
//
//  1. _otpdialog: an in-flight NSAlert from the previous watcher's
//     reconnectLoop. Killing it first lets the watcher's blocking
//     exec.Wait return so its SIGTERM in step 2 is actually observed
//     instead of getting stuck behind a modal.
//  2. _watcher: kill before openfortivpn so it can't react to the VPN
//     dying by popping its own OTP dialog at the user — the bug that
//     made `packxy start` twice send the user into an OTP loop.
//  3. _tray: kill before spawning the new tray so we don't end up with
//     two padlock icons in the menu bar.
//  4. openfortivpn: kill last so /dev/ppp is free for the new
//     forti.Start. Routes via the old ppp0 are flushed automatically by
//     the kernel as the interface goes down.
func silentTeardown() {
	killStrayDaemon("packxy _otpdialog")
	killStrayDaemon("packxy _watcher")
	killStrayDaemon("packxy _tray")
	_ = exec.Command("sudo", "-n", "pkill", "-TERM", "-x", "openfortivpn").Run()
	// Brief moment for the kernel to tear down ppp0 + flush routes.
	time.Sleep(200 * time.Millisecond)
}

// killStrayDaemon TERMinates then (if needed) KILLs every process whose
// command line matches `pattern`. Runs without sudo because the user-owned
// _watcher / _otpdialog / _tray daemons don't need privilege escalation
// (only openfortivpn does, handled separately).
//
// Polls pgrep between signals so the immediately-following spawn doesn't
// race a still-dying daemon for resources (PID file, menu-bar slot).
func killStrayDaemon(pattern string) {
	_ = exec.Command("pkill", "-TERM", "-f", pattern).Run()
	if waitProcessGone(pattern, 20) {
		return
	}
	_ = exec.Command("pkill", "-KILL", "-f", pattern).Run()
	_ = waitProcessGone(pattern, 10)
}

func waitProcessGone(pattern string, polls int) bool {
	for i := 0; i < polls; i++ {
		// pgrep exit code 1 = no match left = success.
		if exec.Command("pgrep", "-f", pattern).Run() != nil {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
	return false
}

// spawnWatcher re-execs ourselves as `packxy _watcher` in a new session so the
// daemon survives the parent's exit. Stdout and stderr are redirected to
// state/watcher.log. Env (incl. FORTI_*) is inherited so the watcher can
// rebuild a forti.Config and prompt fresh OTPs on reconnect.
//
// The executable path is resolved through any symlinks before launching
// the child. Without this, a user invoking the CLI through the
// `/usr/local/bin/packxy` symlink would have the watcher inherit the
// symlink path as its argv[0], causing both `runningInsideBundle()` and
// `[NSBundle mainBundle]` to misidentify the process — notifications
// would silently fall back to osascript with the script-runner icon.
func spawnWatcher() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	if err := state.Ensure(); err != nil {
		return err
	}

	logF, err := os.OpenFile(state.WatcherLogPath(), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	devNull, err := os.Open(os.DevNull)
	if err != nil {
		_ = logF.Close()
		return err
	}

	cmd := exec.Command(exe, "_watcher")
	cmd.Env = os.Environ()
	cmd.Stdin = devNull
	cmd.Stdout = logF
	cmd.Stderr = logF
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		_ = logF.Close()
		_ = devNull.Close()
		return err
	}
	_ = logF.Close()
	_ = devNull.Close()

	if err := state.WriteWatcherPID(cmd.Process.Pid); err != nil {
		return err
	}

	go func() { _ = cmd.Wait() }()
	return nil
}

func addRoutes(dev string, cidrs []string) string {
	var added []string
	for _, c := range cidrs {
		if err := macnet.AddRoute(c, dev); err != nil {
			continue
		}
		_ = state.AppendRoute(c)
		added = append(added, c)
	}
	return strings.Join(added, ", ")
}

func configureDNS(cfg *envcfg.Config) string {
	if !cfg.HasSplitDNS() {
		return ""
	}
	var added []string
	for _, d := range cfg.VPNDomains {
		if err := macnet.WriteResolver(d, cfg.VPNDNS); err != nil {
			continue
		}
		_ = state.AppendDomain(d)
		added = append(added, d)
	}
	return strings.Join(added, ", ")
}

// =====================================================================
//  stop
// =====================================================================

func runStop() int {
	ui.Page()
	ui.Header()
	ui.Section("Teardown")

	if stopTray() {
		ui.StepOK("Menu-bar tray stopped")
	}

	if stopWatcher() {
		ui.StepOK("Watcher stopped")
	}

	stopVPN()
	ui.StepOK("VPN stopped")

	if domains, err := state.ReadDomains(); err == nil {
		for _, d := range domains {
			_ = macnet.RemoveResolver(d)
		}
	}

	if err := state.Clear(); err != nil {
		ui.StepWarn("State cleanup failed: " + err.Error())
	}

	ui.Page()
	ui.Header()
	ui.Banner(ui.ColOK, "🔓 Disconnected", "")
	ui.Tagline(ui.ColMuted, "Packed up. See you next time! 👋")
	fmt.Println()
	return 0
}

// stopWatcher signals the watcher daemon (if any) to exit. Returns true if a
// signal was sent successfully.
func stopWatcher() bool {
	pid, err := state.ReadWatcherPID()
	if err != nil || pid <= 0 {
		return false
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	if err := proc.Signal(syscall.SIGTERM); err != nil {
		return false
	}
	// Give the watcher a moment to clean up.
	for i := 0; i < 10; i++ {
		if !state.ProcessAlive(pid) {
			return true
		}
		time.Sleep(200 * time.Millisecond)
	}
	return true
}

// stopVPN signals openfortivpn to terminate via `sudo -n pkill -x
// openfortivpn`, which the sudoers drop-in installed by `packxy install`
// allows without a password. SIGTERM first, then SIGKILL if the process
// doesn't exit within ~3s. Idempotent: a no-op if openfortivpn isn't
// running.
//
// Using pkill (rather than `sudo kill -TERM <pid>`) lets the watcher stop
// the VPN even after the original sudo cache has expired — critical for the
// pre-sleep teardown path, which fires hours into a session.
func stopVPN() {
	pid, _ := state.ReadVPNPID()
	state.ClearVPNPID()

	_ = exec.Command("sudo", "-n", "pkill", "-TERM", "-x", "openfortivpn").Run()

	// Wait for actual exit. If we have a PID, watch it; otherwise sleep
	// briefly and assume the SIGTERM did the job.
	if pid > 0 {
		for i := 0; i < 15; i++ {
			if !state.ProcessAlive(pid) {
				return
			}
			time.Sleep(200 * time.Millisecond)
		}
		_ = exec.Command("sudo", "-n", "pkill", "-KILL", "-x", "openfortivpn").Run()
		return
	}
	time.Sleep(300 * time.Millisecond)
}

// =====================================================================
//  status
// =====================================================================

func runStatus() int {
	ui.Page()
	ui.Header()
	ui.Section("Status")

	watcherPID, _ := state.ReadWatcherPID()
	vpnPID, _ := state.ReadVPNPID()
	trayPID, _ := state.ReadTrayPID()
	routes, _ := state.ReadRoutes()
	domains, _ := state.ReadDomains()
	lastDrop, hasDrop, _ := state.ReadLastDrop()

	watcherUp := watcherPID > 0
	vpnUp := vpnPID > 0 && state.ProcessAlive(vpnPID)
	ip := ""
	if vpnUp {
		ip = macnet.IfaceIPv4(forti.Iface)
	}
	upCount := boolToInt(watcherUp) + boolToInt(vpnUp)

	connIcon, connLabel, connColor := connectionState(upCount)

	card := []ui.CardLine{
		{Icon: connIcon, Label: "Connection", Value: connLabel},
		{Icon: statusIcon(watcherUp), Label: "Watcher", Value: pidValue(watcherPID)},
		{Icon: statusIcon(vpnUp), Label: "VPN", Value: vpnValue(vpnPID, ip)},
	}
	if trayPID > 0 {
		card = append(card, ui.CardLine{
			Icon:  statusIcon(true),
			Label: "Tray",
			Value: pidValue(trayPID),
		})
	}
	if len(routes) > 0 {
		card = append(card, ui.CardLine{Icon: "🔀", Label: "Routes", Value: strings.Join(routes, ", ")})
	}
	if len(domains) > 0 {
		card = append(card, ui.CardLine{Icon: "🔍", Label: "DNS", Value: strings.Join(domains, ", ")})
	}
	if hasDrop {
		card = append(card, ui.CardLine{
			Icon:  "💔",
			Label: "Last drop",
			Value: fmt.Sprintf("%s (%s)", ui.HumanizeAge(lastDrop.At), lastDrop.Reason),
		})
	}

	ui.SummaryCard(connColor, card)
	fmt.Println()
	return 0
}

func statusIcon(ok bool) string {
	if ok {
		return "🟢"
	}
	return "⚪"
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func connectionState(upCount int) (icon, label string, color ui.Color) {
	switch upCount {
	case 2:
		return "🟢", "Connected", ui.ColOK
	case 0:
		return "🔴", "Disconnected", ui.ColFail
	default:
		return "🟡", fmt.Sprintf("Partial (%d/2 up)", upCount), ui.ColWarn
	}
}

func pidValue(pid int) string {
	if pid <= 0 {
		return "not running"
	}
	return fmt.Sprintf("running (pid %d)", pid)
}

func vpnValue(pid int, ip string) string {
	if pid <= 0 {
		return "not running"
	}
	if !state.ProcessAlive(pid) {
		return fmt.Sprintf("dead (stale pid %d)", pid)
	}
	if ip == "" {
		return fmt.Sprintf("running (pid %d, %s not up)", pid, forti.Iface)
	}
	return fmt.Sprintf("%s %s (pid %d)", forti.Iface, ip, pid)
}

// =====================================================================
//  _watcher (internal, runs detached after `start`)
// =====================================================================

// runWatcher monitors the openfortivpn process and, when it exits (typically
// because the OTP got burned by a reconnect attempt after Mac sleep), notifies
// the user, pops a native macOS dialog asking for a fresh OTP, restarts
// openfortivpn, and validates that ppp0 came back up before declaring success.
//
// In addition to the main monitor loop, one parallel goroutine consumes
// macOS power-state events (`macnet.StreamSleepWake`):
//
//   - SleepEvent:  fired just before the kernel suspends. The watcher
//     proactively `pkill`s openfortivpn so the FortiGate session is released
//     cleanly and the PID-poll loop unblocks immediately on wake instead of
//     waiting for the LCP echo timeout (~60s).
//   - WakeEvent:   fired once the system has fully resumed. Sets a flag so
//     the next openfortivpn-exit reason is reported as ReasonWake (with the
//     corresponding user-facing OTP-dialog message).
//
// The watcher exits cleanly on SIGTERM (sent by `packxy stop`). If the user
// dismisses the OTP dialog, the routes/resolvers are torn down on a
// best-effort basis so traffic isn't silently black-holed.
func runWatcher(_ []string) int {
	defer state.ClearWatcherPID(os.Getpid())

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sigCh
		cancel()
	}()

	logf := func(format string, a ...any) {
		fmt.Fprintf(os.Stdout, "[%s] "+format+"\n",
			append([]any{time.Now().Format(time.RFC3339)}, a...)...)
	}

	logf("watcher armed (pid %d)", os.Getpid())
	if exe, err := os.Executable(); err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		bundled := strings.Contains(exe, ".app/Contents/MacOS/")
		logf("exe=%s (bundled=%v)", exe, bundled)
	}

	var wakeFlag atomic.Bool
	go watchPowerState(ctx, logf, &wakeFlag)

	for {
		pid, _ := state.ReadVPNPID()
		if pid <= 0 {
			logf("no VPN PID in state — exiting")
			return 0
		}

		// Wait for openfortivpn to die (poll, since the process is not our
		// child — runStart spawned it). 3s polling is fine: pre-sleep
		// teardown delivers death within milliseconds of wake, and other
		// drop causes (link silent, peer reset) tolerate a few seconds.
		for state.ProcessAlive(pid) {
			select {
			case <-ctx.Done():
				logf("watcher cancelled, exiting")
				return 0
			case <-time.After(3 * time.Second):
			}
		}

		if ctx.Err() != nil {
			logf("watcher cancelled, exiting")
			return 0
		}

		reason := forti.ClassifyFromLog(filepath.Join(state.Dir, "openfortivpn.log"))
		if wakeFlag.Swap(false) {
			reason = state.ReasonWake
		}
		logf("openfortivpn pid %d gone (%s) — notifying user", pid, reason)
		state.ClearVPNPID()
		_ = state.WriteLastDrop(time.Now(), reason)
		_ = macnet.Notify("Packxy — VPN disconnected", macnet.OTPHeadline(reason))

		if !reconnectLoop(ctx, logf, reason) {
			return 0
		}
	}
}

// watchPowerState consumes macOS sleep/wake notifications and reacts:
//
//   - On SleepEvent: pkill openfortivpn so the FortiGate session is released
//     before the kernel suspends. Sets wakeFlag so the next reconnect uses
//     the wake-flavoured Reason.
//   - On WakeEvent: just sets wakeFlag (the proactive pkill on sleep means
//     the PID-poll loop is already in reconnect path by the time we wake).
//
// IOKit notifications are precise (millisecond-level) and have no false
// positives from CPU stalls — a strict upgrade over the prior clock-jump
// heuristic.
func watchPowerState(ctx context.Context, logf func(string, ...any), wakeFlag *atomic.Bool) {
	events := macnet.StreamSleepWake()
	for {
		select {
		case <-ctx.Done():
			return
		case ev := <-events:
			switch ev {
			case macnet.SleepEvent:
				logf("sleep notification — releasing VPN session")
				wakeFlag.Store(true)
				stopVPN()
			case macnet.WakeEvent:
				logf("wake notification")
				wakeFlag.Store(true)
			}
		}
	}
}

// reconnectLoop drives the OTP prompt + openfortivpn restart sequence until
// the VPN is back up or the user cancels. Returns true on success (continue
// monitoring) and false on user cancel / fatal failure (watcher should exit).
//
// Two failure paths with distinct backoff:
//   - authFails: forti.Start returned an error after an OTP attempt.
//     Each attempt costs one auth try against FortiGate, so we cap at 4 (one
//     under the typical 5-attempt lockout threshold) and apply growing delays.
//   - infraFails: forti.Start failed before reaching auth (binary missing,
//     /dev/ppp permission denied). No auth was attempted; back off briefly.
func reconnectLoop(ctx context.Context, logf func(string, ...any), initialReason state.Reason) bool {
	const maxAuthFails = 4
	authBackoff := []time.Duration{
		0,
		30 * time.Second,
		2 * time.Minute,
		5 * time.Minute,
		10 * time.Minute,
	}
	authFails := 0
	infraFails := 0
	reason := initialReason

	for {
		if ctx.Err() != nil {
			return false
		}

		if authFails >= maxAuthFails {
			logf("auth failure ceiling reached (%d) — stopping to avoid lockout", authFails)
			_ = macnet.Notify("Packxy",
				"Multiple OTP failures — stopping to avoid FortiGate lockout. "+
					"Run `packxy stop && packxy start` when ready.")
			tearDownNetwork()
			return false
		}

		if delay := authBackoff[min(authFails, len(authBackoff)-1)]; delay > 0 {
			logf("waiting %s before next OTP prompt (auth fails=%d)", delay, authFails)
			select {
			case <-ctx.Done():
				return false
			case <-time.After(delay):
			}
		}

		otp, err := macnet.PromptOTPWithReason(reason)
		if errors.Is(err, macnet.ErrDialogCancelled) {
			logf("user cancelled OTP prompt — tearing down and exiting")
			tearDownNetwork()
			_ = macnet.Notify("Packxy — VPN disconnected",
				"Tunnel torn down. Run `packxy start` when you want to reconnect.")
			return false
		}
		if err != nil {
			logf("OTP dialog failed: %v — exiting", err)
			_ = macnet.Notify("Packxy", "VPN reconnect failed — run `packxy start`.")
			return false
		}

		_ = os.Setenv("FORTI_OTP", otp)
		logf("restarting openfortivpn with fresh OTP")

		fcfg := forti.Config{
			Host:        os.Getenv("FORTI_HOST"),
			Port:        os.Getenv("FORTI_PORT"),
			User:        os.Getenv("FORTI_USER"),
			Password:    os.Getenv("FORTI_PASS"),
			OTP:         otp,
			Realm:       os.Getenv("FORTI_REALM"),
			TrustedCert: os.Getenv("FORTI_TRUSTED_CERT"),
			OTPPrompt:   os.Getenv("FORTI_OTP_PROMPT"),
			NoFTMPush:   os.Getenv("FORTI_NO_FTM_PUSH") == "1",
		}

		p, err := forti.Start(ctx, fcfg)
		if err != nil {
			// Distinguish auth fail (log shows auth error) from infra fail.
			if forti.ClassifyFromLog(filepath.Join(state.Dir, "openfortivpn.log")) == state.ReasonAuthExpired {
				authFails++
				logf("OTP rejected (%d/%d): %v", authFails, maxAuthFails, err)
				_ = macnet.Notify("Packxy",
					fmt.Sprintf("OTP rejected (%d/%d) — try again.", authFails, maxAuthFails))
				reason = state.ReasonAuthExpired
				continue
			}
			infraFails++
			delay := infraBackoff(infraFails)
			logf("openfortivpn start failed: %v (infra fail %d, sleeping %s)", err, infraFails, delay)
			_ = macnet.Notify("Packxy", "VPN restart failed — will retry.")
			select {
			case <-ctx.Done():
				return false
			case <-time.After(delay):
			}
			reason = state.ReasonStartupFailure
			continue
		}

		_ = state.WriteVPNPID(p.PID)
		state.ClearLastDrop()
		// Kernel flushes routes pointing at the previous ppp0 when it
		// disappears, so re-add the configured CIDRs against the new
		// interface — otherwise the user's traffic to VPN_ROUTES would
		// silently leak through the host's default route.
		readded := readdVPNRoutes(forti.Iface)
		logf("VPN reconnected (ppp0 %s, pid %d) after %d auth fail(s), %d infra fail(s); routes restored: %s",
			p.IP, p.PID, authFails, infraFails, readded)
		_ = macnet.Notify("Packxy", "✓ VPN reconnected")
		return true
	}
}

// readdVPNRoutes re-runs `route add -net <cidr> -interface <dev>` for every
// CIDR recorded in state. Idempotent: a CIDR that's already in the table
// produces a "File exists" failure which we swallow. Returns the
// comma-separated list of CIDRs successfully re-installed (for logging).
func readdVPNRoutes(dev string) string {
	cidrs, err := state.ReadRoutes()
	if err != nil || len(cidrs) == 0 {
		return ""
	}
	var ok []string
	for _, c := range cidrs {
		if err := macnet.AddRoute(c, dev); err == nil {
			ok = append(ok, c)
		}
	}
	if len(ok) == 0 {
		return "(none)"
	}
	return strings.Join(ok, ", ")
}

// tearDownNetwork removes routes/resolvers and kills openfortivpn. Called when
// the watcher gives up (user cancel or auth lockout) so traffic isn't
// silently black-holed.
func tearDownNetwork() {
	if domains, err := state.ReadDomains(); err == nil {
		for _, d := range domains {
			_ = macnet.RemoveResolver(d)
		}
	}
	stopVPN()
}

// infraBackoff returns the delay to wait after a `forti.Start` failure that
// did NOT reach auth. The scale is short because no auth was attempted.
func infraBackoff(n int) time.Duration {
	switch {
	case n <= 1:
		return 5 * time.Second
	case n == 2:
		return 15 * time.Second
	default:
		return 60 * time.Second
	}
}

// =====================================================================
//  _tray (internal, menu-bar status item)
// =====================================================================

// runTray is the entry point of the menu-bar tray helper. Bootstraps an
// AppKit run loop (which a Setsid'd watcher can't do) and renders a
// status item that polls /tmp/packxy state every couple of seconds.
//
// Spawned by runStart alongside the watcher; killed by runStop.
func runTray(args []string) int {
	_ = args
	defer state.ClearTrayPID()
	return macnet.RunTray()
}

// spawnTray re-execs ourselves as `packxy _tray` in a detached session.
// Unlike the watcher, the tray needs to interact with WindowServer, so
// we don't Setsid — we want to inherit the user's Aqua session. Stdout
// and stderr go to the tray log.
//
// Any prior tray has already been reaped by silentTeardown at the top
// of runStart — no defensive kill needed here.
func spawnTray() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	if err := state.Ensure(); err != nil {
		return err
	}

	logF, err := os.OpenFile(state.TrayLogPath(), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	devNull, err := os.Open(os.DevNull)
	if err != nil {
		_ = logF.Close()
		return err
	}

	cmd := exec.Command(exe, "_tray")
	cmd.Env = os.Environ()
	cmd.Stdin = devNull
	cmd.Stdout = logF
	cmd.Stderr = logF
	// No Setsid: NSStatusItem needs to share the user's Aqua session and
	// WindowServer connection. The process still survives the parent
	// because launchd reparents it.
	if err := cmd.Start(); err != nil {
		_ = logF.Close()
		_ = devNull.Close()
		return err
	}
	_ = logF.Close()
	_ = devNull.Close()

	if err := state.WriteTrayPID(cmd.Process.Pid); err != nil {
		return err
	}
	go func() { _ = cmd.Wait() }()
	return nil
}

// stopTray signals the menu-bar tray to exit. Best-effort: a missing PID
// or dead process is fine.
func stopTray() bool {
	pid, err := state.ReadTrayPID()
	if err != nil || pid <= 0 {
		return false
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	_ = proc.Signal(syscall.SIGTERM)
	for i := 0; i < 10; i++ {
		if !state.ProcessAlive(pid) {
			return true
		}
		time.Sleep(150 * time.Millisecond)
	}
	return true
}

// =====================================================================
//  _otpdialog (internal, child of the watcher)
// =====================================================================

// runOTPDialog is invoked by the watcher as `packxy _otpdialog -message
// <msg>` whenever it needs a fresh OTP. Running the dialog in a separate
// short-lived process — instead of straight from the Setsid'd watcher —
// gives Cocoa's NSAlert a clean process to bootstrap into, which is what
// allows the modal window to actually appear on screen.
//
// Output contract:
//
//	exit 0  : OTP printed to stdout (one line, no trailing newline beyond
//	          fmt.Println's)
//	exit 2  : user clicked Cancel
//	exit 1  : internal error (also written to stderr)
func runOTPDialog(args []string) int {
	fs := flag.NewFlagSet("_otpdialog", flag.ExitOnError)
	headline := fs.String("headline", "", "alert headline (messageText)")
	action := fs.String("action", "", "call to action (informativeText)")
	_ = fs.Parse(args)

	if *headline == "" || *action == "" {
		fmt.Fprintln(os.Stderr, "_otpdialog: -headline and -action are required")
		return 1
	}

	out, cancelled := macnet.CocoaPromptOTP(*headline, *action)
	if cancelled {
		return 2
	}
	fmt.Println(strings.TrimSpace(out))
	return 0
}

