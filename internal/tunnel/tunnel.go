// Package tunnel embeds xjasonlyu/tun2socks as a library.
//
// Two entry points exist:
//
//   - Run starts the engine in the current process and blocks until the given
//     context is cancelled. It must be called by a process running as root,
//     because creating a utun device on macOS requires it. The chosen utun
//     device name (e.g. "utun8") is printed to stdout once it appears so a
//     non-root parent can read it back.
//
//   - DiffUtun is a helper that returns the new utun interface that appeared
//     between two snapshots of `ifconfig -l`.
package tunnel

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/rcapraro/packxy/internal/macnet"
	"github.com/xjasonlyu/tun2socks/v2/engine"
)

// RunOptions describes how to bring up the embedded engine.
type RunOptions struct {
	Proxy    string        // socks5://127.0.0.1:1080
	MTU      int           // 1300
	UDPTO    time.Duration // 60s
	LogLevel string        // warn
}

// DefaultOptions returns the defaults that mirror the original split.sh CLI flags.
func DefaultOptions(proxy string) RunOptions {
	return RunOptions{
		Proxy:    proxy,
		MTU:      1300,
		UDPTO:    60 * time.Second,
		LogLevel: "warn",
	}
}

// Run blocks until ctx is cancelled, running the embedded engine. It announces
// the chosen utun device on stdout in the form "TUNDEV=utunN\n" once it
// appears so the parent process can pick it up and add routes.
//
// Must be invoked from a process with EUID 0 — utun creation needs root.
func Run(ctx context.Context, opts RunOptions) error {
	before, err := macnet.ListUtunInterfaces()
	if err != nil {
		return fmt.Errorf("snapshot utun interfaces: %w", err)
	}

	key := &engine.Key{
		Device:                   "utun",
		Proxy:                    opts.Proxy,
		MTU:                      opts.MTU,
		UDPTimeout:               opts.UDPTO,
		LogLevel:                 opts.LogLevel,
		TCPModerateReceiveBuffer: true,
		TCPSendBufferSize:        "512k",
		TCPReceiveBufferSize:     "512k",
	}

	engine.Insert(key)
	engine.Start()

	// Wait briefly for the new utun to appear so we can announce it.
	dev, err := waitForNewUtun(before, 5*time.Second)
	if err != nil {
		engine.Stop()
		return err
	}
	fmt.Printf("TUNDEV=%s\n", dev)
	_ = os.Stdout.Sync()

	<-ctx.Done()
	engine.Stop()
	return nil
}

func waitForNewUtun(before map[string]struct{}, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		now, err := macnet.ListUtunInterfaces()
		if err != nil {
			return "", err
		}
		for name := range now {
			if _, was := before[name]; !was {
				return name, nil
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return "", fmt.Errorf("no new utun interface appeared within %s", timeout)
}
