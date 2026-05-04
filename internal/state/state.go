package state

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const Dir = "/tmp/forti-socks"

const (
	pidFile     = "tun2socks.pid"
	devFile     = "tun_dev"
	routesFile  = "routes"
	domainsFile = "domains"
)

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
