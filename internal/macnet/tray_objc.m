// Objective-C implementation of the menu-bar tray. Lives in its own .m
// file (rather than inside tray.go's cgo preamble) so the
// @interface / @implementation pair is compiled exactly once instead of
// being duplicated by every Go file that imports the package — the
// cause of "duplicate symbol _OBJC_CLASS_$_PackxyTrayDelegate" link
// errors when the preamble is inlined.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <stdlib.h>

// Forward declarations of Go callbacks (see exports in tray.go).
extern char* packxy_tray_state_json(void);
extern void  packxy_tray_quit_action(void);

@interface PackxyTrayDelegate : NSObject
- (void)tick:(NSTimer*)t;
- (void)quit:(id)sender;
@end

static NSStatusItem*     g_item;
static NSMenu*           g_menu;
static NSMenuItem*       g_connection;
static NSMenuItem*       g_ip;
static NSMenuItem*       g_routes;
static NSMenuItem*       g_dns;
static NSMenuItem*       g_lastDrop;
static NSMenuItem*       g_lastDropSep;
static NSMenuItem*       g_quit;
static PackxyTrayDelegate* g_delegate;

// applyState parses the line-oriented blob produced by Go's
// buildTrayState() and rewrites the menu items in place.
static void applyState(const char* blob) {
    if (blob == NULL) return;
    NSString* s = [NSString stringWithUTF8String:blob];
    NSArray<NSString*>* lines = [s componentsSeparatedByString:@"\n"];
    NSMutableDictionary* kv = [NSMutableDictionary dictionary];
    for (NSString* line in lines) {
        NSRange r = [line rangeOfString:@":"];
        if (r.location == NSNotFound) continue;
        NSString* k = [line substringToIndex:r.location];
        NSString* v = [line substringFromIndex:r.location + 1];
        kv[k] = v;
    }
    NSString* state  = kv[@"STATE"]  ?: @"disconnected";
    NSString* ip     = kv[@"IP"]     ?: @"";
    NSString* routes = kv[@"ROUTES"] ?: @"";
    NSString* dns    = kv[@"DNS"]    ?: @"";
    NSString* drop   = kv[@"DROP"]   ?: @"";

    NSImage* img = nil;
    NSString* tip = nil;
    if ([state isEqualToString:@"connected"]) {
        img = [NSImage imageNamed:NSImageNameLockLockedTemplate];
        tip = @"Packxy: connected";
        g_connection.title = @"🟢  Connected";
        g_quit.title = @"Disconnect & Quit";
    } else if ([state isEqualToString:@"partial"]) {
        img = [NSImage imageNamed:NSImageNameLockUnlockedTemplate];
        tip = @"Packxy: partial";
        g_connection.title = @"🟡  Partial — see status";
        g_quit.title = @"Disconnect & Quit";
    } else {
        img = [NSImage imageNamed:NSImageNameLockUnlockedTemplate];
        tip = @"Packxy: disconnected";
        g_connection.title = @"🔴  Disconnected";
        g_quit.title = @"Quit";
    }
    [img setTemplate:YES];
    g_item.button.image = img;
    g_item.button.toolTip = tip;

    g_ip.title     = ip.length     ? [@"IP: " stringByAppendingString:ip]    : @"IP: —";
    g_routes.title = routes.length ? [@"Routes: " stringByAppendingString:routes] : @"Routes: —";
    g_dns.title    = dns.length    ? [@"DNS: " stringByAppendingString:dns]    : @"DNS: —";

    if (drop.length) {
        g_lastDrop.hidden    = NO;
        g_lastDropSep.hidden = NO;
        g_lastDrop.title     = [@"Last drop: " stringByAppendingString:drop];
    } else {
        g_lastDrop.hidden    = YES;
        g_lastDropSep.hidden = YES;
    }
}

@implementation PackxyTrayDelegate
- (void)tick:(NSTimer*)t {
    char* blob = packxy_tray_state_json();
    if (blob != NULL) {
        applyState(blob);
        free(blob);
    }
}
- (void)quit:(id)sender {
    // Hand off to Go so we can spawn `packxy stop` cleanly with the
    // bundle-resolved exe path. After it returns, terminate NSApp so the
    // tray itself dies even if `packxy stop` couldn't reach the watcher.
    packxy_tray_quit_action();
    [NSApp terminate:nil];
}
@end

// run_tray bootstraps NSApp, creates the status item + menu, schedules
// the polling timer, and runs forever. Returns 0 on clean termination
// (Quit menu / NSApp terminate).
int run_tray(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];

        g_delegate = [[PackxyTrayDelegate alloc] init];

        g_item = [[NSStatusBar systemStatusBar]
                    statusItemWithLength:NSVariableStatusItemLength];
        g_item.button.image = [NSImage imageNamed:NSImageNameLockUnlockedTemplate];
        [g_item.button.image setTemplate:YES];
        g_item.button.toolTip = @"Packxy: starting";

        g_menu = [[NSMenu alloc] init];
        g_connection = [g_menu addItemWithTitle:@"Connecting…" action:nil keyEquivalent:@""];
        [g_menu addItem:[NSMenuItem separatorItem]];
        g_ip      = [g_menu addItemWithTitle:@"IP: —"     action:nil keyEquivalent:@""];
        g_routes  = [g_menu addItemWithTitle:@"Routes: —" action:nil keyEquivalent:@""];
        g_dns     = [g_menu addItemWithTitle:@"DNS: —"    action:nil keyEquivalent:@""];

        g_lastDropSep = [NSMenuItem separatorItem];
        g_lastDropSep.hidden = YES;
        [g_menu addItem:g_lastDropSep];
        g_lastDrop = [g_menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
        g_lastDrop.hidden = YES;

        [g_menu addItem:[NSMenuItem separatorItem]];

        g_quit = [[NSMenuItem alloc]
            initWithTitle:@"Disconnect & Quit"
                   action:@selector(quit:)
            keyEquivalent:@"q"];
        [g_quit setTarget:g_delegate];
        [g_menu addItem:g_quit];

        g_item.menu = g_menu;

        // Initial fill so the menu isn't all dashes for the first tick.
        [g_delegate tick:nil];

        [NSTimer scheduledTimerWithTimeInterval:2.0
                                         target:g_delegate
                                       selector:@selector(tick:)
                                       userInfo:nil
                                        repeats:YES];

        [NSApp run];
        return 0;
    }
}
