// Opt-in AppKit/live integration test, isolated in a separate application bundle.
#define main CryptoPulseApplicationMain
#import "../source/main.m"
#undef main
static void Require(BOOL ok, NSString *message) { if(!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
static BOOL Until(BOOL (^condition)(void), double timeout) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:timeout];
    while(!condition() && deadline.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    return condition();
}
static void Snapshot(NSView *view, NSString *path) {
    [view displayIfNeeded]; NSBitmapImageRep *bitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    Require([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES],@"snapshot saved");
}
static void Dispose(Controller *root) {
    [root applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
    root.panel.delegate=nil; [root.panel close];
    for(Controller *child in root.singleWindows) { child.panel.delegate=nil; [child.panel close]; }
    [NSStatusBar.systemStatusBar removeStatusItem:root.status];
}
int main(void) { @autoreleasepool {
    NSString *domain=NSBundle.mainBundle.bundleIdentifier;
    Require([domain isEqual:@"local.bai.cryptopulsemini.window-tests"],@"tests must use isolated preferences");
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    NSApplication *app=NSApplication.sharedApplication; [app finishLaunching];
    Controller *root=[Controller new]; [root applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:app]];
    NSString *out=NSProcessInfo.processInfo.environment[@"PULSE_TEST_OUTPUT"]?:@".build";
    [root applicationShouldHandleReopen:app hasVisibleWindows:YES];
    Require(root.picker.visible && root.coinInput.enabled,@"reopening app offers the coin picker");
    Snapshot(root.picker.contentView,[out stringByAppendingPathComponent:@"picker.png"]);
    root.coinInput.stringValue=@"THISCOINDOESNOTEXIST"; [root confirmCoin:nil];
    Require(Until(^BOOL { return root.openCoinButton.enabled; },30),@"invalid market request completes");
    Require(!root.singleWindows.count && [root.pickerMessage.stringValue containsString:@"未找到"],@"invalid symbol shows inline error without creating a window");
    root.coinInput.stringValue=@"sol/usdt"; [root confirmCoin:nil];
    Require(Until(^BOOL { return root.singleWindows.count==1; },30),@"picker opens validated SOL market");
    Controller *sol=root.singleWindows.firstObject;
    Controller *tiny=[root createSingleWindow:@"SHIBUSDT" digits:8 record:nil];
    Controller *duplicate=[root createSingleWindow:@"SOLUSDT" digits:2 record:@{@"interval":@"4h"}];
    Require(Until(^BOOL {
        if(![root quotesFresh]) return NO;
        for(Controller *child in root.singleWindows) if(![child quotesFresh] || child.charts.firstObject.candles.count!=60) return NO;
        return YES;
    },30),@"main plus three single windows get real quotes and 60 candles");
    double firstFetch=sol.charts.firstObject.chartFetched;
    Require(Until(^BOOL { return sol.charts.firstObject.chartFetched>firstFetch; },12),@"single chart continues refreshing");
    [tiny layoutPanel:1.2];
    Require(fabs(sol.panel.frame.size.width-tiny.panel.frame.size.width)>10,@"one window resizes without resizing the other");
    Snapshot(root.view,[out stringByAppendingPathComponent:@"main.png"]);
    Snapshot(sol.view,[out stringByAppendingPathComponent:@"sol.png"]);
    Snapshot(tiny.view,[out stringByAppendingPathComponent:@"shib.png"]);
    [root saveSingleWindows];
    NSArray *records=[NSUserDefaults.standardUserDefaults arrayForKey:@"SingleCoinWindows"];
    Require(records.count==3 && [records[2][@"interval"] isEqual:@"4h"],@"all window settings persisted independently");
    [root closeWindow:nil];
    Require(!root.panel.visible && sol.panel.visible && tiny.panel.visible,@"closing main hides only main");
    [root show:nil];
    [root newCoinWindow:nil]; root.coinInput.stringValue=@"BTC"; [root confirmCoin:nil]; [root cancelPicker:nil];
    Until(^BOOL { return NO; },1);
    Require(root.singleWindows.count==3,@"cancelled picker request cannot create a late window");
    Dispose(root);
    Controller *restored=[Controller new]; [restored applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:app]];
    Require(restored.singleWindows.count==3,@"launch restores saved windows rather than overwriting them");
    Require([restored.singleWindows[0].symbols.firstObject isEqual:@"SOLUSDT"] && [restored.singleWindows[1] digitsForSymbol:@"SHIBUSDT"]==8 && [restored.singleWindows[2].charts.firstObject.interval isEqual:@"4h"],@"symbol, tiny-price precision and duplicate-coin interval survive relaunch");
    Controller *closed=restored.singleWindows.firstObject;
    [closed closeWindow:nil];
    Require(restored.singleWindows.count==2 && closed.closed && !closed.timer && !closed.session,@"closing window releases timers and sessions");
    records=[NSUserDefaults.standardUserDefaults arrayForKey:@"SingleCoinWindows"];
    Require(records.count==2,@"closed window is removed from restoration list");
    Dispose(restored);
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    puts("PASS: live main + 3 single windows, picker validation/cancel, independent sizing/closing, continued Kline refresh and relaunch restoration");
    return 0;
} }
