package macnet

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// IfaceIPv4 returns the first IPv4 address assigned to the given network
// interface, or "" when the interface is absent / has no inet entry. Wraps
// `ifconfig <name>` and parses the textual output rather than going
// through getifaddrs(3) — keeps the package free of cgo for callers that
// don't already need it (the watcher's status path).
func IfaceIPv4(name string) string {
	out, err := exec.Command("ifconfig", name).Output()
	if err != nil {
		return ""
	}
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "inet ") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 2 {
			// "inet 10.212.134.220 --> 10.212.134.1 ..." → "10.212.134.220"
			return fields[1]
		}
	}
	return ""
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

// SudoValidate primes the sudo credential cache so subsequent sudo -n
// commands don't prompt. Inherits stdin/stdout/stderr so the user can type
// their password if needed.
func SudoValidate() error {
	cmd := exec.Command("sudo", "-v")
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
