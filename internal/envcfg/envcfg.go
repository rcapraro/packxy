package envcfg

import (
	_ "embed"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/joho/godotenv"
)

//go:embed packxy.conf.sample
var sampleTemplate []byte

// SampleTemplate returns the bytes that `packxy install` writes to
// ~/.config/packxy.conf when seeding a fresh config.
func SampleTemplate() []byte { return sampleTemplate }

// DefaultPath is the canonical location for the user's Packxy config.
// Lives under XDG-style ~/.config so `packxy start` works from any cwd
// — not just the project source dir.
func DefaultPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".config", "packxy.conf"), nil
}

// Resolve picks the config path to load. Precedence:
//
//  1. $PACKXY_CONFIG (explicit override — useful for multiple profiles)
//  2. ~/.config/packxy.conf (canonical user location, created by
//     `packxy install`)
//
// Returns the first path that exists, or an error listing what was tried
// if none do.
func Resolve() (string, error) {
	var tried []string

	if v := os.Getenv("PACKXY_CONFIG"); v != "" {
		if _, err := os.Stat(v); err == nil {
			return v, nil
		}
		tried = append(tried, v+" (from $PACKXY_CONFIG)")
	}

	if p, err := DefaultPath(); err == nil {
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
		tried = append(tried, p)
	}

	return "", fmt.Errorf("no config file found (tried: %s)", strings.Join(tried, ", "))
}

// SeedDefault writes the embedded sample template to ~/.config/packxy.conf
// if no file exists there. Returns the path, whether the file was just
// created, and any error. Permissions are 0600 because the file holds the
// VPN password.
//
// Idempotent: an existing file is left untouched (created=false). The
// parent ~/.config directory is created if missing.
func SeedDefault() (path string, created bool, err error) {
	path, err = DefaultPath()
	if err != nil {
		return "", false, err
	}
	if _, err := os.Stat(path); err == nil {
		return path, false, nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return path, false, err
	}
	if err := os.WriteFile(path, sampleTemplate, 0o600); err != nil {
		return path, false, err
	}
	return path, true, nil
}

type Config struct {
	Host        string
	Port        string
	User        string
	Password    string
	TrustedCert string
	Realm       string
	OTP         string
	NoFTMPush   string
	OTPPrompt   string
	VPNRoutes   []string
	VPNDNS      string
	VPNDomains  []string
}

func Load(path string) (*Config, error) {
	if _, err := os.Stat(path); err == nil {
		if err := godotenv.Overload(path); err != nil {
			return nil, fmt.Errorf("read %s: %w", path, err)
		}
	}

	cfg := &Config{
		Host:        os.Getenv("FORTI_HOST"),
		Port:        defaultStr(os.Getenv("FORTI_PORT"), "443"),
		User:        os.Getenv("FORTI_USER"),
		Password:    os.Getenv("FORTI_PASS"),
		TrustedCert: os.Getenv("FORTI_TRUSTED_CERT"),
		Realm:       os.Getenv("FORTI_REALM"),
		OTP:         os.Getenv("FORTI_OTP"),
		NoFTMPush:   os.Getenv("FORTI_NO_FTM_PUSH"),
		OTPPrompt:   os.Getenv("FORTI_OTP_PROMPT"),
		VPNRoutes:   splitCSV(os.Getenv("VPN_ROUTES")),
		VPNDNS:      os.Getenv("VPN_DNS"),
		VPNDomains:  splitCSV(os.Getenv("VPN_DOMAINS")),
	}
	return cfg, nil
}

func (c *Config) HasSplitTunneling() bool {
	return len(c.VPNRoutes) > 0
}

func (c *Config) HasSplitDNS() bool {
	return c.VPNDNS != "" && len(c.VPNDomains) > 0
}

func splitCSV(s string) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if v := strings.TrimSpace(p); v != "" {
			out = append(out, v)
		}
	}
	return out
}

func defaultStr(v, def string) string {
	if v == "" {
		return def
	}
	return v
}
