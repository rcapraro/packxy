// Command packxy is a self-contained macOS split-tunneling launcher for FortiGate VPN.
//
// It pilots a Docker container running openfortivpn + dante (SOCKS5 proxy on
// :1080) and embeds tun2socks (xjasonlyu/tun2socks/v2/engine) to route traffic
// for the configured CIDRs through the proxy at the network layer.
//
// Three subcommands:
//
//	packxy start     — launch the VPN container, embedded tunnel, routes and DNS
//	packxy stop      — tear everything down
//	packxy _tunnel   — internal: runs the embedded engine as root (re-exec target)
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/rcapraro/packxy/internal/dockerd"
	"github.com/rcapraro/packxy/internal/envcfg"
	"github.com/rcapraro/packxy/internal/macnet"
	"github.com/rcapraro/packxy/internal/state"
	"github.com/rcapraro/packxy/internal/tunnel"
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
	case "_tunnel":
		os.Exit(runTunnel(os.Args[2:]))
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
	ui.KeyValue("start", "Connect to VPN and enable split tunneling")
	ui.KeyValue("stop", "Disconnect VPN and remove split tunneling")

	ui.Section("Options")
	ui.KeyValue("-h, --help", "Show this message")
	fmt.Println()
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

	ui.StepInfo("sudo is needed for the tunnel interface and DNS entries.")
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

	dur, err := ui.Spin("Starting container...", func() error {
		return dockerd.ComposeUp(workdir)
	})
	if err != nil {
		ui.StepFail("Container failed to start")
		fmt.Println()
		ui.MutedHint("     Run docker compose up -d to see the error.")
		return 1
	}
	ui.StepOK("Container started", dur)

	container := dockerd.ResolveContainerName(workdir)

	dur, err = ui.Spin("Connecting to VPN...", func() error {
		return dockerd.WaitForVPN(container)
	})
	if err != nil {
		ui.Page()
		ui.Header()
		ui.Banner(ui.ColFail, "✖ Connection Failed", "")
		ui.Tagline(ui.ColFail, "Can't Pack today... check credentials and try again 🔧")
		ui.ErrorCard(dockerd.ExtractError(container))
		fmt.Println()
		ui.MutedHint("     📋  Full logs: docker compose logs")
		fmt.Println()
		ui.PressEnter("Press Enter to exit...")
		return 1
	}
	ui.StepOK("VPN connected", dur)

	dev, err := startEmbeddedTunnel("socks5://127.0.0.1:1080")
	if err != nil {
		ui.StepFail("Tunnel setup failed: " + err.Error())
		return 1
	}
	ui.StepOK("Tunnel interface " + dev)

	routes := addRoutes(dev, cfg.VPNRoutes)
	if routes != "" {
		ui.StepOK("Routes  " + routes)
	}

	domains := configureDNS(cfg)
	if domains != "" {
		ui.StepOK("DNS     " + domains)
	}

	ui.Page()
	ui.Header()
	ui.Banner(ui.ColOK, "🔒 Connected", "All traffic to VPN networks is routed")
	ui.Tagline(ui.ColOK, "All Packed up and ready to tunnel! 🚀")
	ui.Section("Connection")

	card := []ui.CardLine{
		{Icon: "🌐", Label: "Proxy", Value: "127.0.0.1:1080"},
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

// startEmbeddedTunnel re-execs ourselves under sudo to run the engine as root,
// reads back the chosen utun device on the child's stdout, and stores its PID
// in the state directory.
func startEmbeddedTunnel(proxy string) (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if err := state.Ensure(); err != nil {
		return "", err
	}

	cmd := exec.Command("sudo", "-n", exe, "_tunnel",
		"-proxy", proxy,
		"-mtu", "1300",
		"-udp-timeout", "60s",
		"-loglevel", "warn",
	)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	logF, err := os.Create(filepath.Join(state.Dir, "tunnel.log"))
	if err != nil {
		return "", err
	}
	cmd.Stderr = logF
	if err := cmd.Start(); err != nil {
		_ = logF.Close()
		return "", err
	}
	if err := state.WritePID(cmd.Process.Pid); err != nil {
		_ = cmd.Process.Kill()
		return "", err
	}

	dev, err := readDeviceLine(stdout, 8*time.Second)
	if err != nil {
		_ = macnet.SudoKill(cmd.Process.Pid)
		return "", err
	}
	if err := state.WriteDevice(dev); err != nil {
		return "", err
	}

	go func() {
		_ = cmd.Wait()
	}()

	if err := macnet.IfconfigUp(dev, "198.18.0.1"); err != nil {
		return "", err
	}
	return dev, nil
}

func readDeviceLine(r io.Reader, timeout time.Duration) (string, error) {
	type result struct {
		dev string
		err error
	}
	ch := make(chan result, 1)
	go func() {
		scanner := bufio.NewScanner(r)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if strings.HasPrefix(line, "TUNDEV=") {
				ch <- result{dev: strings.TrimPrefix(line, "TUNDEV=")}
				return
			}
		}
		ch <- result{err: errors.New("tunnel ended without announcing device")}
	}()
	select {
	case r := <-ch:
		return r.dev, r.err
	case <-time.After(timeout):
		return "", fmt.Errorf("timed out waiting for tunnel device after %s", timeout)
	}
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
	workdir, err := projectDir()
	if err != nil {
		ui.PrintErr("could not locate project directory: %v", err)
		return 1
	}

	ui.Page()
	ui.Header()
	ui.Section("Teardown")

	stopTunnel()
	ui.StepOK("Tunnel removed")

	dur, err := ui.Spin("Stopping container...", func() error {
		return dockerd.ComposeDown(workdir)
	})
	if err != nil {
		ui.StepWarn("Container down failed: " + err.Error())
	} else {
		ui.StepOK("Container stopped", dur)
	}

	ui.Page()
	ui.Header()
	ui.Banner(ui.ColOK, "🔓 Disconnected", "")
	ui.Tagline(ui.ColMuted, "Packed up. See you next time! 👋")
	fmt.Println()
	return 0
}

func stopTunnel() {
	if pid, err := state.ReadPID(); err == nil && pid > 0 {
		_ = macnet.SudoKill(pid)
	}
	if domains, err := state.ReadDomains(); err == nil {
		for _, d := range domains {
			_ = macnet.RemoveResolver(d)
		}
	}
	_ = state.Clear()
}

// =====================================================================
//  _tunnel (internal, runs as root via sudo)
// =====================================================================

func runTunnel(args []string) int {
	fs := flag.NewFlagSet("_tunnel", flag.ExitOnError)
	proxy := fs.String("proxy", "socks5://127.0.0.1:1080", "SOCKS5 proxy")
	mtu := fs.Int("mtu", 1300, "TUN MTU")
	udpTO := fs.Duration("udp-timeout", 60*time.Second, "UDP session timeout")
	logLevel := fs.String("loglevel", "warn", "log level")
	_ = fs.Parse(args)

	if os.Geteuid() != 0 {
		ui.PrintErr("_tunnel must run as root (re-exec via sudo)")
		return 1
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sigCh
		cancel()
	}()

	opts := tunnel.RunOptions{
		Proxy:    *proxy,
		MTU:      *mtu,
		UDPTO:    *udpTO,
		LogLevel: *logLevel,
	}
	if err := tunnel.Run(ctx, opts); err != nil {
		ui.PrintErr("tunnel: %v", err)
		return 1
	}
	return 0
}

// =====================================================================
//  helpers
// =====================================================================

// projectDir returns the directory packxy should treat as the project root.
//
// Precedence: $PACKXY_DIR > current working directory if it contains
// docker-compose.yml > directory containing the running executable.
func projectDir() (string, error) {
	if v := os.Getenv("PACKXY_DIR"); v != "" {
		return v, nil
	}
	cwd, err := os.Getwd()
	if err == nil {
		if _, err := os.Stat(filepath.Join(cwd, "docker-compose.yml")); err == nil {
			return cwd, nil
		}
	}
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.Dir(exe), nil
}
