package envcfg

import (
	"fmt"
	"os"
	"strings"

	"github.com/joho/godotenv"
)

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
