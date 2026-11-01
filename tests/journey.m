// User journeys through actual AppKit controls; isolated settings and live public data.
#define main CryptoPulseApplicationMain
#import "../source/main.m"
#undef main
static void Require(BOOL ok, NSString *message) { if(!ok) { NSLog(@"FAIL: %@",message); exit(1); } NSLog(@"PASS: %@",message); }
static BOOL Until(BOOL (^condition)(void), double seconds) {
    double deadline=Now()+seconds;
    while(Now()<deadline) { @autoreleasepool { if(condition()) return YES; [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]]; } }
    return condition();
}
static NSButton *Button(NSView *view, NSString *title) {
    for(NSView *child in view.subviews) {
        if([child isKindOfClass:NSButton.class] && [[(NSButton *)child title] isEqual:title]) return (NSButton *)child;
        NSButton *found=Button(child,title); if(found) return found;
    }
    return nil;
}
static void Click(NSButton *button) {
    Require(button && !button.hidden && button.enabled,@"visible enabled control available");
    NSPoint center=[button convertPoint:NSMakePoint(NSMidX(button.bounds),NSMidY(button.bounds)) toView:button.window.contentView.superview];
    NSView *hit=[button.window.contentView hitTest:center];
    Require(hit==button || [hit isDescendantOf:button],@"control center receives clicks without an overlay intercepting it");
    [button performClick:nil];
}
static void Snapshot(NSWindow *window, NSString *name) {
    if(![NSProcessInfo.processInfo.environment[@"PULSE_JOURNEY_CAPTURE"] boolValue]) return;
    [window makeKeyAndOrderFront:nil]; [window displayIfNeeded]; Until(^BOOL{return NO;},.2);
    NSTask *task=[NSTask new]; task.executableURL=[NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
    task.arguments=@[@"-x",@"-l",[NSString stringWithFormat:@"%ld",(long)window.windowNumber],[@".build/journey-" stringByAppendingFormat:@"%@.png",name]];
    NSError *error=nil; Require([task launchAndReturnError:&error],@"capture command launches"); [task waitUntilExit]; Require(task.terminationStatus==0,@"actual window screenshot captured");
}
static void Period(BTCScreener *screen,NSInteger segment) {
    screen.periodControl.selectedSegment=segment;
    [screen.periodControl sendAction:screen.periodControl.action to:screen.periodControl.target];
}
int main(int argc,const char **argv) { @autoreleasepool {
    NSString *domain=NSBundle.mainBundle.bundleIdentifier;
    Require([domain isEqual:@"local.bai.cryptopulsemini.journey-tests"],@"isolated preferences required");
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    NSApplication *app=NSApplication.sharedApplication; [app finishLaunching];
    // A complete failed scan must explain missing data, not claim no coin is correlated.
    BTCScreener *failed=[BTCScreener new]; [failed show];
    failed.candidates=@[@{},@{}]; failed.completed=2; failed.failed=2; failed.matches=[NSMutableArray new]; failed.cutoff=floor(Now()/900)*900;
    [failed finish]; NSLog(@"ALL-FAILED MESSAGE: %@",failed.statusLabel.stringValue);
    Snapshot(failed.panel,@"all-failed");
    Require([failed.statusLabel.stringValue containsString:@"暂无结果"] && ![failed.statusLabel.stringValue containsString:@"没有达到"] && !failed.strictButton.enabled && failed.searchButton.enabled,@"all failed data shows a retryable no-data state, not a no-correlation claim");
    [failed.panel performClose:nil]; [failed show];
    Require(!failed.strictButton.enabled && failed.searchButton.enabled,@"reopening the failed scan keeps retry available without offering an empty filter");
    failed.panel.delegate=nil; [failed.panel close];
    if(argc>1 && strcmp(argv[1],"--failure-only")==0) return 0;

    Controller *root=[Controller new]; [root applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:app]];
    Require(Until(^BOOL{return [root quotesFresh];},30),@"main BTC/ETH/PENDLE prices arrive");
    Click(Button(root.view,@"新建"));
    Require(root.picker.visible && root.picker.firstResponder!=nil,@"new-window control opens a focused picker");
    root.coinInput.stringValue=@""; Click(root.openCoinButton);
    Require([root.pickerMessage.stringValue containsString:@"请输入"] && root.singleWindows.count==0,@"empty input offers a correction without creating a window");
    root.coinInput.stringValue=@"THISCOINDOESNOTEXIST"; Click(root.openCoinButton);
    Require(Until(^BOOL{return root.openCoinButton.enabled;},30) && [root.pickerMessage.stringValue containsString:@"未找到"],@"wrong coin produces a recoverable inline error");
    Snapshot(root.picker,@"invalid-coin");
    root.coinInput.stringValue=@"  sol/usdt  "; Click(root.openCoinButton);
    Require(Until(^BOOL{return root.singleWindows.count==1;},30),@"correcting to a lower-case pair with spaces opens SOL");
    Controller *single=root.singleWindows.firstObject;
    Require(Until(^BOOL{return [single quotesFresh] && single.charts.firstObject.candles.count==60;},30),@"new single window gets real prices and candles");
    Click(single.charts.firstObject.buttons[2]);
    Require(Until(^BOOL{return [single.charts.firstObject.interval isEqual:@"1h"] && single.charts.firstObject.candles.count==60;},20),@"visible hourly chart control loads hourly candles");
    NSRect plot=[single plotRectAtIndex:0]; [single.view updateHoverAt:NSMakePoint(NSMidX(plot),NSMidY(plot))];
    Require(single.charts.firstObject.hovered && ![CandleTurnover(single.charts.firstObject.candles[HoverIndex(60,.5)]) isEqual:@"—"],@"hover has real selected-candle turnover");
    Snapshot(single.panel,@"hourly-hover");
    [single.view updateHoverAt:NSMakePoint(-1,-1)];
    Click(single.charts.firstObject.buttons[0]); Require(!single.charts.firstObject.expanded,@"collapse control hides the chart");
    Click(single.charts.firstObject.rowButton); Require(single.charts.firstObject.expanded,@"coin card reopens the chart");
    NSMenu *menu=[single windowOptions]; NSInteger entry=[menu indexOfItemWithTitle:@"BTC 同步榜…"];
    Require(entry>=0,@"screener is reachable from a single-window menu"); [menu performActionForItemAtIndex:entry];
    BTCScreener *screen=root.screener;
    Require(screen.running && !screen.searchButton.enabled && screen.cancelButton.enabled,@"search immediately shows work in progress and prevents duplicate search");
    Click(screen.cancelButton); Require(!screen.running && screen.progress.hidden && [screen.statusLabel.stringValue containsString:@"已取消"],@"cancel stops busy state with clear feedback");
    [screen.panel performClose:nil]; [menu performActionForItemAtIndex:entry];
    Require(screen.panel.visible && !screen.running && screen.searchButton.enabled,@"reopening cancelled search offers retry");
    Click(screen.searchButton);
    Period(screen,1); Period(screen,0); Period(screen,1);
    Require(Until(^BOOL{return !screen.running;},185),@"rapid period switching settles");
    Require(screen.matches.count>0 && screen.btcReturns.count==24 && [screen.interval isEqual:@"1h"],@"rapid switches finish with only the final hourly request");
    Require([root quotesFresh] && [single quotesFresh],@"search leaves existing quotes current");
    if(screen.strictButton.state==NSControlStateValueOn) Click(screen.strictButton);
    Require(screen.results.count>0 && screen.results.count<=10,@"closest mode displays up to ten real scores");
    Snapshot(screen.panel,@"hourly-results");
    NSArray *saved=[screen.results copy]; [screen.panel performClose:nil]; [menu performActionForItemAtIndex:entry];
    Require(!screen.running && [saved isEqual:screen.results],@"closing and reopening completed search retains its results");
    NSView *cell=[screen.table viewAtColumn:3 row:0 makeIfNecessary:YES]; Click(Button(cell,@"打开"));
    Require(root.singleWindows.count==2 && !screen.panel.visible && [root.singleWindows.lastObject.charts.firstObject.interval isEqual:@"1h"],@"actual result button creates an hourly window and dismisses the list");
    [menu performActionForItemAtIndex:entry]; Period(screen,0);
    Require(Until(^BOOL{return !screen.running;},185) && screen.btcReturns.count==96 && screen.matches.count>0,@"switching back recomputes the 15-minute results");
    for(NSDictionary *coin in screen.results) Require([coin[@"interval"] isEqual:@"15m"],@"no hourly rows remain in the 15-minute list");
    Snapshot(screen.panel,@"15m-results");
    Click(screen.searchButton); [screen.panel performClose:nil]; Until(^BOOL{return NO;},1);
    Require(!screen.running && !screen.panel.visible && screen.results.count==0,@"closing an active search cancels requests without leaving old results");
    Click(Button(root.view,@"×")); Require(!root.panel.visible && single.panel.visible,@"main close hides only the main window");
    NSMenu *dock=[root applicationDockMenu:app]; [dock performActionForItemAtIndex:[dock indexOfItemWithTitle:@"显示主窗口"]];
    Require(root.panel.visible,@"Dock menu restores hidden main window");
    Click(Button(single.view,@"×")); Require(root.singleWindows.count==1,@"single close removes only that window");
    [root applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:app]];
    root.panel.delegate=nil; [root.panel close]; for(Controller *child in root.singleWindows) { child.panel.delegate=nil; [child.panel close]; }
    [NSStatusBar.systemStatusBar removeStatusItem:root.status];
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    NSLog(@"PASS: complete ordinary-user journey"); return 0;
} }
