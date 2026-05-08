// Package macnet — sleep/wake notifications via IOKit.
//
// Subscribes to macOS power-management events (`IORegisterForSystemPower`)
// and surfaces them as Go channel events. Replaces the previous heuristic
// based on wall-clock jumps: IOKit notifications fire within milliseconds of
// the actual sleep/wake transition and never produce false positives from
// CPU stalls.
//
// Sleep events are delivered just before the kernel suspends, while the
// process is still alive — that's the moment to gracefully release the VPN
// session so FortiGate doesn't see a half-dead connection on wake.

package macnet

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
#include <CoreFoundation/CoreFoundation.h>

extern void goSleepEvent(void);
extern void goWakeEvent(void);

static io_connect_t s_rootPort;
static IONotificationPortRef s_notifyPort;
static io_object_t s_notifier;

static void powerCallback(void *refCon, io_service_t service,
                          natural_t messageType, void *messageArgument) {
    (void)refCon;
    (void)service;
    switch (messageType) {
    case kIOMessageCanSystemSleep:
        // We never veto sleep — approve immediately so the kernel doesn't
        // wait on us for the 30s timeout.
        IOAllowPowerChange(s_rootPort, (long)messageArgument);
        break;
    case kIOMessageSystemWillSleep:
        // Synchronous: we run on the IOKit run-loop thread. Notify Go and
        // approve so sleep can proceed. goSleepEvent must return quickly.
        goSleepEvent();
        IOAllowPowerChange(s_rootPort, (long)messageArgument);
        break;
    case kIOMessageSystemHasPoweredOn:
        goWakeEvent();
        break;
    default:
        break;
    }
}

// runSleepWakeLoop registers the power-state subscription and runs the
// CFRunLoop until the calling thread exits (typically: until process exit).
// Caller must invoke this on a goroutine that has runtime.LockOSThread()'d.
//
// Returns 0 if registration failed.
static int runSleepWakeLoop(void) {
    s_rootPort = IORegisterForSystemPower(NULL, &s_notifyPort,
                                          powerCallback, &s_notifier);
    if (s_rootPort == 0) {
        return 0;
    }
    CFRunLoopAddSource(
        CFRunLoopGetCurrent(),
        IONotificationPortGetRunLoopSource(s_notifyPort),
        kCFRunLoopDefaultMode);
    CFRunLoopRun();
    return 1;
}
*/
import "C"

import (
	"runtime"
	"sync"
)

// SleepWakeEvent classifies the macOS power-state event observed.
type SleepWakeEvent int

const (
	// SleepEvent fires just before the kernel suspends the system. The
	// process is still alive and able to do quick work (release VPN
	// session, persist state) before the actual sleep.
	SleepEvent SleepWakeEvent = iota
	// WakeEvent fires once the system has fully resumed.
	WakeEvent
)

var (
	swMu      sync.RWMutex
	swCh      chan<- SleepWakeEvent
	swStarted bool
)

//export goSleepEvent
func goSleepEvent() {
	swMu.RLock()
	ch := swCh
	swMu.RUnlock()
	if ch == nil {
		return
	}
	// Non-blocking: if the consumer is slow, we'd rather drop than stall
	// the IOKit run-loop thread (which is also approving the sleep).
	select {
	case ch <- SleepEvent:
	default:
	}
}

//export goWakeEvent
func goWakeEvent() {
	swMu.RLock()
	ch := swCh
	swMu.RUnlock()
	if ch == nil {
		return
	}
	select {
	case ch <- WakeEvent:
	default:
	}
}

// StreamSleepWake registers an IOKit power-state subscription and returns a
// channel that emits SleepEvent and WakeEvent. The channel is buffered (8)
// so brief consumer stalls don't drop events.
//
// Must be called at most once per process. The CFRunLoop runs on a locked
// OS thread until the process exits — there is no graceful deregistration
// API, but that's acceptable since we want the subscription for the
// watcher's entire lifetime.
//
// If IOKit registration fails (rare on macOS), the returned channel never
// emits anything; callers should still treat it as a valid channel and let
// other parts of the watcher (PID polling, OTP prompt) carry on.
func StreamSleepWake() <-chan SleepWakeEvent {
	ch := make(chan SleepWakeEvent, 8)
	swMu.Lock()
	if swStarted {
		swMu.Unlock()
		// Already running: just rewire to the new channel. The previous
		// one is orphaned. (Should never happen — single-call contract.)
		swMu.Lock()
		swCh = ch
		swMu.Unlock()
		return ch
	}
	swCh = ch
	swStarted = true
	swMu.Unlock()

	go func() {
		runtime.LockOSThread()
		// Returns 0 if registration failed. CFRunLoopRun otherwise blocks
		// for the lifetime of the process.
		_ = C.runSleepWakeLoop()
	}()

	return ch
}
