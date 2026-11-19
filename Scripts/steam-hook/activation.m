// Silo's in-Steam hook, focus hand-off. Since macOS 14 an app comes to the front only if the frontmost one lets it.
// A game started by Silo from macOS Steam runs as its own app (the Wine loader inside the game's .app), not launched
// by LaunchServices, so Steam keeps the front and the game opens behind it. Wine posts no activation request for it
// (measured on SOULCALIBUR VI), so Steam watches for a Silo game app turning regular and, once Steam is the active
// frontmost app, yields to it — once per process. Runs in steam_osx and in the CEF browser helper, which owns Steam's
// window. Same idea as NotProton PR #90's final focus fix (sn0wst0rm, commit 71b8965); this is Silo's own code.
#import <AppKit/AppKit.h>

void silo_hook_log(const char *fmt, ...);

// …/Application Support/Silo/GameApps/<id>/<name>.app/Contents/MacOS/wine, identifier io.github.dino0005.silo.game.*
static BOOL is_silo_game_app(NSRunningApplication *app) {
    NSArray<NSString *> *parts = app.executableURL.URLByResolvingSymlinksInPath.pathComponents;
    NSUInteger n = parts.count;
    if (n < 8 || ![parts[n - 1] isEqual:@"wine"] || ![parts[n - 2] isEqual:@"MacOS"] ||
        ![parts[n - 3] isEqual:@"Contents"] || ![parts[n - 4] hasSuffix:@".app"]) return NO;
    if (![parts[n - 6] isEqual:@"GameApps"] || ![parts[n - 7] isEqual:@"Silo"]) return NO;
    return [app.bundleIdentifier hasPrefix:@"io.github.dino0005.silo.game."];
}

// Hands the front to `game` once Steam is the active frontmost app. A game app usually turns regular before Steam
// has come back to the front after Play, so it stays pending (up to 60 s) instead of being given up at first sight.
static NSMutableDictionary<NSNumber *, NSDate *> *pending;

static BOOL hand_off(NSRunningApplication *game, const char *why) {
    NSRunningApplication *steam = NSRunningApplication.currentApplication;
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!NSApp.active || ![front isEqual:steam]) return NO;
    [NSApp yieldActivationToApplication:game];
    BOOL ok = [game activateFromApplication:steam options:0];
    silo_hook_log("focus (%s): yielded to %s (pid %d): %s", why, game.localizedName.UTF8String,
                  game.processIdentifier, ok ? "activated" : "declined");
    return YES;
}

void silo_activation_install(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        pending = [NSMutableDictionary dictionary];
        NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
        [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
                if (app.activationPolicy != NSApplicationActivationPolicyRegular || app.terminated) continue;
                NSNumber *pid = @(app.processIdentifier);
                if ([seen containsObject:pid] || !is_silo_game_app(app)) continue;
                [seen addObject:pid];   // one hand-off per game process, so it can't keep stealing focus
                pending[pid] = [NSDate dateWithTimeIntervalSinceNow:60];
                NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
                silo_hook_log("focus: game app pid %d is up; front = %s (pid %d), Steam active %d", pid.intValue,
                              front.bundleIdentifier.UTF8String ?: "?", front.processIdentifier, NSApp.active);
            }
            for (NSNumber *pid in pending.allKeys) {
                NSRunningApplication *game = [NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue];
                if (!game || game.terminated || game.active || [pending[pid] timeIntervalSinceNow] < 0 ||
                    hand_off(game, "game app")) [pending removeObjectForKey:pid];
            }
        }];
        silo_hook_log("focus hand-off ready");
    });
}

// Started directly, Steam's client shows its bundle's old round icon in the Dock; give it the one of
// /Applications/Steam.app (the bootstrapper the user normally opens), now and once Steam has finished starting.
void silo_dock_icon_install(void) {
    NSString *bootstrapper = @"/Applications/Steam.app";
    if (![NSFileManager.defaultManager fileExistsAtPath:bootstrapper]) return;
    void (^apply)(void) = ^{
        NSApp.applicationIconImage = [NSWorkspace.sharedWorkspace iconForFile:bootstrapper];
    };
    dispatch_async(dispatch_get_main_queue(), apply);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), apply);
}
