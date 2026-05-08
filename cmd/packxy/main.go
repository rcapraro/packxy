// Command packxy is a self-contained macOS split-tunneling launcher for FortiGate VPN.
//
// It runs openfortivpn natively as a subprocess, creating a ppp0
// interface on the host. macOS routes for the configured CIDRs are pointed at
// ppp0, and /etc/resolver entries are written for the configured internal
// domains. The default route and /etc/resolv.conf are left untouched —
// openfortivpn is configured with set-routes=0 / set-dns=0 and pppd with
// nodefaultroute to preserve split tunneling.
//
// Subcommands:
//
//	packxy install   — one-time: install sudoers drop-in + /etc/ppp/peers/packxy
//	packxy uninstall — remove the install artifacts
//	packxy start     — launch openfortivpn, add routes/DNS, arm the watcher
//	packxy stop      — tear everything down
//	packxy status    — show watcher / VPN / routes state
//	packxy _watcher  — internal: monitors openfortivpn and re-prompts OTP on drop
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

	ui.Page()
	ui.Header()
	ui.Section("Install")
	ui.StepInfo("This will write:")
	ui.Line(fmt.Sprintf("  • %s (sudoers drop-in)", forti.SudoersPath))
	ui.Line(fmt.Sprintf("  • /etc/ppp/peers/%s (pppd options)", forti.PeerName))
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
	fmt.Println()
	return 0
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
	fmt.Println()
	return 0
}

// =====================================================================
//  start
// =====================================================================

func runStart() int {
	workdir, err := projectDir()
	if err != nil {
		ui.PrintErr("could not locate project directory: %v", err)
		return 1
	}

	cfg, err := envcfg.Load(filepath.Join(workdir, ".env"))
	if err != nil {
		ui.PrintErr("error loading .env: %v", err)
		return 1
	}

	if !cfg.HasSplitTunneling() {
		ui.PrintErr("VPN_ROUTES is not configured in .env — split tunneling cannot start.")
		ui.PrintErr("Set VPN_ROUTES (and ideally VPN_DNS, VPN_DOMAINS) and try again.")
		return 1
	}

	if !forti.IsInstalled() {
		ui.PrintErr("packxy is not installed — run `packxy install` first.")
		return 1
	}

	if _, err := forti.FindBinary(); err != nil {
		ui.PrintErr("%v", err)
		return 1
	}

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

	// Defensive: a previous crashed run might leave an orphan openfortivpn or
	// stale ppp0. Best-effort cleanup before we try a fresh start.
	cleanupOrphans()

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

	if err := spawnWatcher(workdir); err != nil {
		ui.StepWarn("Watcher not started: " + err.Error())
	} else {
		ui.StepOK("Watcher armed (re-prompts OTP if VPN drops)")
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

func promptCredentials(cfg *envcfg.Config) error {
	v, err := ui.Input("  VPN Hostname", "vpn.company.com", cfg.Host)
	if err != nil {
		return err
	}
	cfg.Host = v

	v, err = ui.Input("  VPN Port", "443", cfg.Port)
	if err != nil {
		return err
	}
	cfg.Port = v

	v, err = ui.Input("  Username", "john.doe", cfg.User)
	if err != nil {
		return err
	}
	cfg.User = v

	v, err = ui.Password("  Password", "••••••••", cfg.Password)
	if err != nil {
		return err
	}
	cfg.Password = v

	v, err = ui.SixDigitOTP(cfg.OTP)
	if err != nil {
		return err
	}
	cfg.OTP = v

	if cfg.TrustedCert == "" {
		v, err = ui.Input("  Trusted Certificate (optional)", "sha256 fingerprint...", "")
		if err != nil {
			return err
		}
		cfg.TrustedCert = v
	}

	if cfg.Realm != "" {
		v, err = ui.Input("  Realm", "", cfg.Realm)
		if err != nil {
			return err
		}
		cfg.Realm = v
	}
	return nil
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
		NoFTMPush:   cfg.NoFTMPush == "1",
	}
}

// cleanupOrphans best-effort kills any leftover openfortivpn process from a
// previous crashed run and tears down ppp0 if it survived. Called before
// `forti.Start` so the next openfortivpn invocation isn't denied by /dev/ppp
// already being in use.
func cleanupOrphans() {
	_ = exec.Command("sudo", "-n", "pkill", "-x", "openfortivpn").Run()
	// Give it a moment so the kernel releases ppp0.
	time.Sleep(200 * time.Millisecond)
}

// spawnWatcher re-execs ourselves as `packxy _watcher` in a new session so the
// daemon survives the parent's exit. Stdout and stderr are redirected to
// state/watcher.log. Env (incl. FORTI_*) is inherited so the watcher can
// rebuild a forti.Config and prompt fresh OTPs on reconnect.
func spawnWatcher(workdir string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
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

	cmd := exec.Command(exe, "_watcher", "-workdir", workdir)
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
	routes, _ := state.ReadRoutes()
	domains, _ := state.ReadDomains()
	lastDrop, hasDrop, _ := state.ReadLastDrop()

	watcherUp := watcherPID > 0
	vpnUp := vpnPID > 0 && state.ProcessAlive(vpnPID)
	ip := ""
	if vpnUp {
		ip = readPPP0IP()
	}
	upCount := boolToInt(watcherUp) + boolToInt(vpnUp)

	connIcon, connLabel, connColor := connectionState(upCount)

	card := []ui.CardLine{
		{Icon: connIcon, Label: "Connection", Value: connLabel},
		{Icon: statusIcon(watcherUp), Label: "Watcher", Value: pidValue(watcherPID)},
		{Icon: statusIcon(vpnUp), Label: "VPN", Value: vpnValue(vpnPID, ip)},
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
			Value: fmt.Sprintf("%s (%s)", humanizeAge(lastDrop.At), lastDrop.Reason),
		})
	}

	ui.SummaryCard(connColor, card)
	fmt.Println()
	return 0
}

func readPPP0IP() string {
	out, err := exec.Command("ifconfig", forti.Iface).Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(strings.TrimSpace(line))
		if len(f) >= 2 && f[0] == "inet" {
			return f[1]
		}
	}
	return ""
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

func humanizeAge(at time.Time) string {
	d := time.Since(at)
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds ago", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return at.Local().Format("2006-01-02 15:04")
	}
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
func runWatcher(args []string) int {
	fs := flag.NewFlagSet("_watcher", flag.ExitOnError)
	workdir := fs.String("workdir", "", "project directory")
	_ = fs.Parse(args)

	if *workdir == "" {
		fmt.Fprintln(os.Stderr, "_watcher: -workdir is required")
		return 1
	}

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

	logf("watcher armed (pid %d), workdir=%s", os.Getpid(), *workdir)

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
		_ = macnet.Notify("packxy — VPN disconnected", macnet.OTPDropMessage(reason))

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
			_ = macnet.Notify("packxy",
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
			_ = macnet.Notify("packxy — VPN disconnected",
				"Tunnel torn down. Run `packxy start` when you want to reconnect.")
			return false
		}
		if err != nil {
			logf("OTP dialog failed: %v — exiting", err)
			_ = macnet.Notify("packxy", "VPN reconnect failed — run `packxy start`.")
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
			NoFTMPush:   os.Getenv("FORTI_NO_FTM_PUSH") == "1",
		}

		p, err := forti.Start(ctx, fcfg)
		if err != nil {
			// Distinguish auth fail (log shows auth error) from infra fail.
			if forti.ClassifyFromLog(filepath.Join(state.Dir, "openfortivpn.log")) == state.ReasonAuthExpired {
				authFails++
				logf("OTP rejected (%d/%d): %v", authFails, maxAuthFails, err)
				_ = macnet.Notify("packxy",
					fmt.Sprintf("OTP rejected (%d/%d) — try again.", authFails, maxAuthFails))
				reason = state.ReasonAuthExpired
				continue
			}
			infraFails++
			delay := infraBackoff(infraFails)
			logf("openfortivpn start failed: %v (infra fail %d, sleeping %s)", err, infraFails, delay)
			_ = macnet.Notify("packxy", "VPN restart failed — will retry.")
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
		logf("VPN reconnected (ppp0 %s, pid %d) after %d auth fail(s), %d infra fail(s)",
			p.IP, p.PID, authFails, infraFails)
		_ = macnet.Notify("packxy", "✓ VPN reconnected")
		return true
	}
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
//  helpers
// =====================================================================

// projectDir returns the directory packxy should treat as the project root.
//
// Precedence: $PACKXY_DIR > current working directory if it contains .env >
// directory containing the running executable.
func projectDir() (string, error) {
	if v := os.Getenv("PACKXY_DIR"); v != "" {
		return v, nil
	}
	cwd, err := os.Getwd()
	if err == nil {
		if _, err := os.Stat(filepath.Join(cwd, ".env")); err == nil {
			return cwd, nil
		}
	}
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.Dir(exe), nil
}
