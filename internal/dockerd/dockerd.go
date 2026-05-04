package dockerd

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

const ContainerName = "forti-socks"

var (
	errPattern = regexp.MustCompile(`(?i)Could not authenticate to gateway|Authentication failed|Invalid OTP|OTP required|Connection failed|check the password, client certificate|Invalid password|Certificate error|Gateway unreachable|VPN process terminated unexpectedly|VPN did not create ppp0`)
	fatalPat   = regexp.MustCompile(`(?i)ERROR:|error:|fatal`)
)

// ComposeUp brings the container up in detached mode.
// Environment must already be set in the current process (passed through to docker compose).
func ComposeUp(workdir string) error {
	cmd := exec.Command("docker", "compose", "up", "-d")
	cmd.Dir = workdir
	cmd.Env = os.Environ()
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("docker compose up failed: %v: %s", err, string(out))
	}
	return nil
}

// ComposeDown tears the container down.
func ComposeDown(workdir string) error {
	cmd := exec.Command("docker", "compose", "down")
	cmd.Dir = workdir
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("docker compose down failed: %v: %s", err, string(out))
	}
	return nil
}

// ResolveContainerName returns the actual compose-managed container name for the
// forti-socks service. Falls back to ContainerName if it can't be inferred.
func ResolveContainerName(workdir string) string {
	cmd := exec.Command("docker", "compose", "ps", "--format", "{{.Name}}", ContainerName)
	cmd.Dir = workdir
	out, err := cmd.Output()
	if err != nil {
		return ContainerName
	}
	name := strings.TrimSpace(string(out))
	if name == "" {
		return ContainerName
	}
	return strings.SplitN(name, "\n", 2)[0]
}

// WaitForVPN polls the container for ppp0 readiness or a recognised auth/connection error.
// Returns when ppp0 is up, an error otherwise. Times out after roughly 40 attempts at ~1s each.
func WaitForVPN(container string) error {
	const attempts = 40
	for i := 0; i < attempts; i++ {
		status := containerStatus(container)
		if status == "exited" {
			return errors.New("container exited")
		}
		if hasPPP0(container) {
			return nil
		}
		if logsContainError(container) {
			return errors.New("vpn error detected in logs")
		}
		time.Sleep(time.Second)
	}
	return errors.New("timed out waiting for ppp0")
}

func containerStatus(container string) string {
	cmd := exec.Command("docker", "inspect", "-f", "{{.State.Status}}", container)
	out, err := cmd.Output()
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(out))
}

func hasPPP0(container string) bool {
	cmd := exec.Command("docker", "exec", container, "ip", "link", "show", "ppp0")
	return cmd.Run() == nil
}

func logsContainError(container string) bool {
	cmd := exec.Command("docker", "logs", container)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	_ = cmd.Run()
	return errPattern.MatchString(buf.String())
}

// ExtractError pulls the last few error-like lines out of recent container logs,
// ready to be displayed to the user.
func ExtractError(container string) string {
	cmd := exec.Command("docker", "logs", "--tail", "50", container)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	_ = cmd.Run()
	logs := buf.String()

	lines := strings.Split(logs, "\n")
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
