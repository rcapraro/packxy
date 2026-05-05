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

const Dir = "/tmp/forti-socks"

const (
	pidFile        = "tun2socks.pid"
	devFile        = "tun_dev"
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

func WritePID(pid int) error {
	if err := Ensure(); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(Dir, pidFile), []byte(strconv.Itoa(pid)), 0o644)
}

func ReadPID() (int, error) {
	b, err := os.ReadFile(filepath.Join(Dir, pidFile))
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(string(b)))
}

func WriteDevice(name string) error {
	if err := Ensure(); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(Dir, devFile), []byte(name), 0o644)
}

func AppendRoute(cidr string) error {
	return appendLine(routesFile, cidr)
}

func ReadRoutes() ([]string, error) {
	return readLines(routesFile)
}

func AppendDomain(domain string) error {
	return appendLine(domainsFile, domain)
}

func ReadDomains() ([]string, error) {
	return readLines(domainsFile)
}

func Clear() error {
	return os.RemoveAll(Dir)
}

// Reason classifies why the VPN container exited so callers can present a
// meaningful message to the user.
type Reason string

const (
	ReasonAuthExpired Reason = "auth-expired"
	ReasonNetworkDrop Reason = "network-drop"
	ReasonUnknown     Reason = "unknown"
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
