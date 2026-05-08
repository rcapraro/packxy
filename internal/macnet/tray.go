// macOS menu-bar (NSStatusItem) tray indicator — Go side.
//
// The actual AppKit code lives in tray_objc.m; this file only carries the
// cgo bindings, the Go-exported callbacks the .m file invokes, and the
// state-blob assembly logic (`buildTrayState`).
//
// Architecture: the tray runs as its own process (`packxy _tray`) — never
// embedded in the watcher — because NSStatusItem requires a continuous
// NSApp run loop to receive menu / mouse events. The watcher is a
// Setsid'd daemon with no run loop; doing both jobs in one process is
// asking for trouble.
//
// The tray polls /tmp/packxy state files every couple of seconds and
// rewrites the menu items in place. No bidirectional IPC needed: the
// state files are the source of truth, the tray is a passive viewer
// (with one active path: the Quit item, which spawns `packxy stop`).

package macnet

/*
#cgo CFLAGS: -fobjc-arc
#cgo LDFLAGS: -framework Foundation -framework AppKit

extern int run_tray(void);
*/
import "C"

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/rcapraro/packxy/internal/state"
	"github.com/rcapraro/packxy/internal/ui"
)

// RunTray bootstraps the menu-bar status item and runs the AppKit event
// loop until the user picks Quit (or the process is killed). Returns when
// NSApp.terminate fires.
//
// Locks the OS thread because the AppKit run loop is thread-bound — the
// thread that calls `[NSApp run]` is the one that has to receive every
// menu/event callback for the lifetime of the process.
func RunTray() int {
	runtime.LockOSThread()
	return int(C.run_tray())
}

//export packxy_tray_state_json
func packxy_tray_state_json() *C.char {
	return C.CString(buildTrayState())
}

//export packxy_tray_quit_action
func packxy_tray_quit_action() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	// `packxy stop` tears down the watcher, VPN and resolvers. The tray's
	// NSApp.terminate fires immediately after this returns.
	cmd := exec.Command(exe, "stop")
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	_ = cmd.Run()
}

// buildTrayState reads the state files written by runStart / the watcher
// and turns them into the line-oriented blob the tray's C side parses.
// The format is "KEY:VALUE\n" with a fixed set of keys (STATE, IP,
// ROUTES, DNS, DROP) — simpler than pulling in encoding/json for what's
// essentially five strings.
func buildTrayState() string {
	watcherPID, _ := state.ReadWatcherPID()
	vpnPID, _ := state.ReadVPNPID()
	routes, _ := state.ReadRoutes()
	domains, _ := state.ReadDomains()
	last, hasDrop, _ := state.ReadLastDrop()

	watcherUp := watcherPID > 0
	vpnUp := vpnPID > 0 && state.ProcessAlive(vpnPID)

	connState := "disconnected"
	switch {
	case watcherUp && vpnUp:
		connState = "connected"
	case watcherUp || vpnUp:
		connState = "partial"
	}

	// Hardcoded "ppp0" rather than importing forti.Iface to keep macnet
	// independent of forti (forti depends on macnet, not the other way
	// around).
	ip := ""
	if vpnUp {
		ip = IfaceIPv4("ppp0")
	}

	dropLine := ""
	if hasDrop {
		dropLine = fmt.Sprintf("%s (%s)", last.Reason, ui.HumanizeAge(last.At))
	}

	var b strings.Builder
	fmt.Fprintf(&b, "STATE:%s\n", connState)
	fmt.Fprintf(&b, "IP:%s\n", ip)
	fmt.Fprintf(&b, "ROUTES:%s\n", strings.Join(routes, ", "))
	fmt.Fprintf(&b, "DNS:%s\n", strings.Join(domains, ", "))
	fmt.Fprintf(&b, "DROP:%s\n", dropLine)
	return b.String()
}
