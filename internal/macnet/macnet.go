package macnet

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ListUtunInterfaces returns the set of currently-existing utun devices.
func ListUtunInterfaces() (map[string]struct{}, error) {
	out, err := exec.Command("ifconfig", "-l").Output()
	if err != nil {
		return nil, err
	}
	set := make(map[string]struct{})
	for _, name := range strings.Fields(string(out)) {
		if strings.HasPrefix(name, "utun") {
			set[name] = struct{}{}
		}
	}
	return set, nil
}

// IfconfigUp configures the device with a point-to-point address and brings it up.
func IfconfigUp(dev, addr string) error {
	cmd := exec.Command("sudo", "-n", "ifconfig", dev, addr, addr, "up")
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("ifconfig %s: %v: %s", dev, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// AddRoute adds a network route through the given interface.
func AddRoute(cidr, dev string) error {
	cmd := exec.Command("sudo", "-n", "route", "-q", "add", "-net", cidr, "-interface", dev)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("route add %s -> %s: %v: %s", cidr, dev, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// WriteResolver creates /etc/resolver/<domain> with `nameserver <dns>`.
func WriteResolver(domain, dns string) error {
	if err := exec.Command("sudo", "-n", "mkdir", "-p", "/etc/resolver").Run(); err != nil {
		return fmt.Errorf("mkdir /etc/resolver: %w", err)
	}
	target := filepath.Join("/etc/resolver", domain)
	body := "nameserver " + dns + "\n"
	cmd := exec.Command("sudo", "-n", "tee", target)
	cmd.Stdin = strings.NewReader(body)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("write %s: %v: %s", target, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// RemoveResolver deletes /etc/resolver/<domain> if present.
func RemoveResolver(domain string) error {
	target := filepath.Join("/etc/resolver", domain)
	if _, err := os.Stat(target); os.IsNotExist(err) {
		return nil
	}
	cmd := exec.Command("sudo", "-n", "rm", "-f", target)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("rm %s: %v: %s", target, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// SudoValidate primes the sudo credential cache so subsequent sudo -n commands don't prompt.
// Inherits stdin/stdout/stderr so the user can type their password if needed.
func SudoValidate() error {
	cmd := exec.Command("sudo", "-v")
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// SudoKill sends SIGTERM to a pid via sudo.
func SudoKill(pid int) error {
	return exec.Command("sudo", "-n", "kill", fmt.Sprintf("%d", pid)).Run()
}
