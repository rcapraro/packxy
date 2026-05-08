package state

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const Dir = "/tmp/packxy"

const (
	vpnPIDFile     = "openfortivpn.pid"
	routesFile     = "routes"
	domainsFile    = "domains"
	watcherPIDFile = "watcher.pid"
	watcherLogFile = "watcher.log"
	lastDropFile   = "last_drop"
)

// WatcherLogPath is the absolute path of the watcher's log file.
func WatcherLogPath() string { return filepath.Join(Dir, watcherLogFile) }

// WriteWatcherPID stores the watcher daemon's PID.
func WriteWatcherPID(pid int) error {
	if err := Ensure(); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(Dir, watcherPIDFile), []byte(strconv.Itoa(pid)), 0o644)
}

// ClearWatcherPID removes the watcher PID file only if it still records the
// given pid. This avoids a race where the defer of an exiting watcher would
// erase the PID of a freshly spawned successor.
func ClearWatcherPID(pid int) {
	path := filepath.Join(Dir, watcherPIDFile)
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	current, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || current != pid {
		return
	}
	_ = os.Remove(path)
}

// ReadWatcherPID returns the watcher PID, or 0 if no watcher is registered or
// the recorded PID no longer corresponds to a live process. In the latter case
// the stale PID file is removed so subsequent reads see a clean slate.
func ReadWatcherPID() (int, error) {
	path := filepath.Join(Dir, watcherPIDFile)
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		return 0, err
	}
	if pid <= 0 {
		_ = os.Remove(path)
		return 0, nil
	}
	if !ProcessAlive(pid) {
		_ = os.Remove(path)
		return 0, nil
	}
	return pid, nil
}

// ProcessAlive reports whether a process with the given pid currently exists.
// EPERM (process exists but is owned by another user) counts as alive; only
// ESRCH means the process is gone.
func ProcessAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	if err == nil {
		return true
	}
	return errors.Is(err, syscall.EPERM)
}

func Ensure() error {
	return os.MkdirAll(Dir, 0o755)
}

// WriteVPNPID stores the openfortivpn process's PID. The watcher writes it so
// `packxy stop` and `packxy status` can locate the live VPN process.
func WriteVPNPID(pid int) error {
	if err := Ensure(); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(Dir, vpnPIDFile), []byte(strconv.Itoa(pid)), 0o644)
}

// ReadVPNPID returns the openfortivpn PID, or 0 if no PID is recorded or the
// recorded PID no longer exists.
func ReadVPNPID() (int, error) {
	b, err := os.ReadFile(filepath.Join(Dir, vpnPIDFile))
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		return 0, err
	}
	if pid <= 0 {
		_ = os.Remove(filepath.Join(Dir, vpnPIDFile))
		return 0, nil
	}
	if !ProcessAlive(pid) {
		_ = os.Remove(filepath.Join(Dir, vpnPIDFile))
		return 0, nil
	}
	return pid, nil
}

// ClearVPNPID removes the openfortivpn PID file.
func ClearVPNPID() {
	_ = os.Remove(filepath.Join(Dir, vpnPIDFile))
}

func AppendRoute(cidr string) error {
	return appendLineUnique(routesFile, cidr)
}

func ReadRoutes() ([]string, error) {
	return readLines(routesFile)
}

func AppendDomain(domain string) error {
	return appendLineUnique(domainsFile, domain)
}

func ReadDomains() ([]string, error) {
	return readLines(domainsFile)
}

func Clear() error {
	return os.RemoveAll(Dir)
}

// Reason classifies why the VPN process exited so callers can present a
// meaningful message to the user.
type Reason string

const (
	ReasonAuthExpired    Reason = "auth-expired"
	ReasonNetworkDrop    Reason = "network-drop"
	ReasonStartupFailure Reason = "startup-failure"
	ReasonTunnelDied     Reason = "tunnel-died"
	ReasonWake           Reason = "wake"
	ReasonUnknown        Reason = "unknown"
)

// LastDrop captures the moment and cause of the last VPN drop the watcher saw.
type LastDrop struct {
	At     time.Time
	Reason Reason
}

// WriteLastDrop persists the last-drop record (RFC3339 timestamp + reason).
func WriteLastDrop(at time.Time, reason Reason) error {
	if err := Ensure(); err != nil {
		return err
	}
	body := at.UTC().Format(time.RFC3339) + "\n" + string(reason) + "\n"
	return os.WriteFile(filepath.Join(Dir, lastDropFile), []byte(body), 0o644)
}

// ReadLastDrop returns the last recorded drop, or ok=false if none.
func ReadLastDrop() (LastDrop, bool, error) {
	b, err := os.ReadFile(filepath.Join(Dir, lastDropFile))
	if err != nil {
		if os.IsNotExist(err) {
			return LastDrop{}, false, nil
		}
		return LastDrop{}, false, err
	}
	parts := strings.SplitN(strings.TrimRight(string(b), "\n"), "\n", 2)
	if len(parts) != 2 {
		return LastDrop{}, false, nil
	}
	at, err := time.Parse(time.RFC3339, strings.TrimSpace(parts[0]))
	if err != nil {
		return LastDrop{}, false, err
	}
	return LastDrop{At: at, Reason: Reason(strings.TrimSpace(parts[1]))}, true, nil
}

func appendLine(name, line string) error {
	if err := Ensure(); err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(Dir, name), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(line + "\n")
	return err
}

// appendLineUnique appends line to the named state file only if it is not
// already present. Used by AppendRoute / AppendDomain so re-running `start`
// without a prior `stop` doesn't accumulate duplicates.
func appendLineUnique(name, line string) error {
	existing, err := readLines(name)
	if err != nil {
		return err
	}
	for _, e := range existing {
		if e == line {
			return nil
		}
	}
	return appendLine(name, line)
}

func readLines(name string) ([]string, error) {
	b, err := os.ReadFile(filepath.Join(Dir, name))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		if v := strings.TrimSpace(l); v != "" {
			out = append(out, v)
		}
	}
	return out, nil
}
