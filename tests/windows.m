// Opt-in AppKit/live integration test, isolated in a separate application bundle.
#define main CryptoPulseApplicationMain
#import "../source/main.m"
#undef main
static void Require(BOOL ok, NSString *message) { if(!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
static BOOL Until(BOOL (^condition)(void), double timeout) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:timeout];
    // Drain temporary snapshots each iteration so the weak-reference probe does not retain them.
    while(YES) { @autoreleasepool {
        if(condition()) return YES;
        if(deadline.timeIntervalSinceNow<=0) return NO;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    } }
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
    Require([sol.panel.title containsString:@"15分"] && [duplicate.panel.title containsString:@"4小时"],@"same-coin windows identify their different periods in the title");
    if(root.panel.screen.visibleFrame.size.width>=1300 && root.panel.screen.visibleFrame.size.height>=500) {
        NSArray *panels=@[root.panel,sol.panel,tiny.panel,duplicate.panel];
        for(NSUInteger i=0;i<panels.count;i++) for(NSUInteger j=i+1;j<panels.count;j++)
            Require(!NSIntersectsRect([panels[i] frame],[panels[j] frame]),@"new windows use free screen space instead of covering existing prices");
    }
    Require(Until(^BOOL {
        if(![root quotesFresh]) return NO;
        for(Controller *child in root.singleWindows) if(![child quotesFresh] || child.charts.firstObject.candles.count!=60) return NO;
        return YES;
    },30),@"main plus three single windows get real quotes and 60 candles");
    double firstFetch=sol.charts.firstObject.chartFetched;
    Require(Until(^BOOL { return sol.charts.firstObject.chartFetched>firstFetch; },12),@"single chart continues refreshing");
    [tiny layoutPanel:1.2];
    Require(fabs(sol.panel.frame.size.width-tiny.panel.frame.size.width)>10,@"one window resizes without resizing the other");
    NSRect smallScreen=NSMakeRect(-1280,0,1280,700);
    [tiny layoutPanel:2 inVisibleFrame:smallScreen];
    Require(NSContainsRect(smallScreen,tiny.panel.frame),@"large restored window is resized to its destination display");
    [tiny screenConfigurationChanged:[NSNotification notificationWithName:NSApplicationDidChangeScreenParametersNotification object:app]];
    Require(NSContainsRect((tiny.panel.screen?:NSScreen.mainScreen).visibleFrame,tiny.panel.frame),@"screen change returns windows to an accessible display");
    [tiny layoutPanel:1.2];
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
    [root newCoinWindow:nil];
    Require([[root.coinInput itemObjectValueAtIndex:0] isEqual:@"SOL"],@"recently opened coin is first in suggestions");
    [root cancelPicker:nil];
    Dispose(root);
    Controller *restored=[Controller new]; [restored applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:app]];
    Require(restored.singleWindows.count==3,@"launch restores saved windows rather than overwriting them");
    Require([restored.singleWindows[0].symbols.firstObject isEqual:@"SOLUSDT"] && [restored.singleWindows[1] digitsForSymbol:@"SHIBUSDT"]==8 && [restored.singleWindows[2].charts.firstObject.interval isEqual:@"4h"],@"symbol, tiny-price precision and duplicate-coin interval survive relaunch");
    Controller *closed=restored.singleWindows.firstObject;
    [closed closeWindow:nil];
    Require(restored.singleWindows.count==2 && closed.closed && !closed.timer && !closed.session,@"closing window releases timers and sessions");
    records=[NSUserDefaults.standardUserDefaults arrayForKey:@"SingleCoinWindows"];
    Require(records.count==2,@"closed window is removed from restoration list");
    NSHashTable *released=[NSHashTable weakObjectsHashTable];
    for(int i=0;i<12;i++) { @autoreleasepool {
        Controller *temporary=[restored createSingleWindow:@"BTCUSDT" digits:2 record:nil];
        [released addObject:temporary]; [temporary closeWindow:nil];
    } }
    Require(Until(^BOOL { return released.allObjects.count==0; },15),@"rapidly opened and closed windows release controllers after request cancellation");
    Require(restored.singleWindows.count==2,@"rapid open/close leaves the existing windows intact");
    NSLog(@"PASS: 12 rapid open/close cycles released all controllers");
    Dispose(restored);
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    puts("PASS: live main + 3 single windows, picker validation/cancel, independent sizing/closing, continued Kline refresh and relaunch restoration");
    return 0;
} }
