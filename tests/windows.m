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
// Model the documented native drag handoff: returns immediately, consumes mouse-up.
@interface DragProbePanel : NSPanel
@property NSUInteger dragCalls;
@end
@implementation DragProbePanel
-(void)performWindowDragWithEvent:(NSEvent *)event { self.dragCalls++; }
@end
@interface DragProbeController : Controller
@property BOOL held;
@end
@implementation DragProbeController
-(BOOL)leftMouseIsDown { return self.held; }
-(void)saveSingleWindows {}
@end
static void CheckDragLifecycle(void) {
    DragProbeController *c=[DragProbeController new];
    ChartState *chart=[ChartState new]; chart.symbol=@"BTCUSDT"; chart.expanded=YES; c.charts=@[chart];
    NSRect screen=NSScreen.mainScreen.visibleFrame;
    DragProbePanel *panel=[[DragProbePanel alloc] initWithContentRect:NSMakeRect(NSMinX(screen)+20,NSMinY(screen)+20,310,415) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed=NO; panel.delegate=c; c.panel=panel;
    c.view=[[PanelView alloc] initWithFrame:NSMakeRect(0,0,310,415)]; c.view.owner=c; panel.contentView=c.view;
    [c.view setBoundsSize:NSMakeSize(310,415)]; [panel orderFront:nil];
    NSEvent *down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(100,395) modifierFlags:0 timestamp:0 windowNumber:panel.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
    c.held=YES; NSRect initial=panel.frame; [c.view mouseDown:down];
    Require(panel.dragCalls==1 && c.dragEndTimer && NSEqualRects(initial,panel.frame),@"native drag returns immediately without prematurely snapping");
    [panel setFrameOrigin:NSMakePoint(NSMaxX(screen)-panel.frame.size.width-20,NSMinY(screen)+20)];
    Until(^BOOL { return NO; },.2);
    Require(fabs(NSMaxX(panel.frame)-(NSMaxX(screen)-20))<.1 && c.dragEndTimer,@"holding the pointer leaves dragging free");
    // No mouse-up is sent to the view. The native button-state watcher must finish it.
    c.held=NO;
    Require(Until(^BOOL { return c.dragEndTimer==nil; },1),@"release is detected even without a delivered mouse-up event");
    Require(fabs(NSMaxX(panel.frame)-NSMaxX(screen))<.1 && fabs(NSMinY(panel.frame)-NSMinY(screen))<.1,@"final position snaps after native drag completes");
    c.snapEnabled=NO; [panel setFrameOrigin:initial.origin]; [c.view mouseDown:down];
    Require(!c.dragEndTimer && NSEqualRects(initial,panel.frame),@"disabled snapping leaves final position unchanged");
    c.snapEnabled=YES; c.held=YES; [c beginWindowDrag]; [c stop];
    Require(!c.dragEndTimer,@"closing a window cancels drag watching");
    panel.delegate=nil; [panel close];
    NSLog(@"PASS: native asynchronous drag lifecycle, held/released state, missing mouse-up, disabled snap and cleanup");
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
    CheckDragLifecycle();
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
    NSRect savedFrame=sol.panel.frame;
    [sol togglePinned:nil]; [sol toggleSnap:nil];
    NSMenuItem *alpha=[NSMenuItem new]; alpha.tag=70; [sol setOpacityFromMenu:alpha];
    Require(sol.panel.level==NSNormalWindowLevel && fabs(sol.panel.alphaValue-.7)<.001 && tiny.panel.level==NSFloatingWindowLevel,@"pin and opacity apply independently to each window");
    [sol switchCoin:nil]; root.coinInput.stringValue=@"THISCOINDOESNOTEXIST"; [root confirmCoin:nil];
    Require(Until(^BOOL { return root.openCoinButton.enabled; },30),@"invalid switch finishes");
    Require([sol.symbols.firstObject isEqual:@"SOLUSDT"] && root.singleWindows.count==3 && [root.openCoinButton.title isEqual:@"确认切换"],@"invalid switch leaves old market and window intact");
    root.coinInput.stringValue=@"DOGE"; [root confirmCoin:nil];
    Require(Until(^BOOL { return [sol.symbols.firstObject isEqual:@"DOGEUSDT"] && [sol quotesFresh] && sol.charts.firstObject.candles.count==60; },30),@"switch validates and loads real DOGE in the original window");
    Require(NSEqualRects(savedFrame,sol.panel.frame) && root.singleWindows.count==3 && !sol.pinned && !sol.snapEnabled && fabs(sol.opacity-.7)<.001,@"switch preserves position, size and window settings");
    NSRect plot=[sol plotRectAtIndex:0];
    Require([sol.view updateHoverAt:NSMakePoint(NSMinX(plot)+plot.size.width*.25,NSMinY(plot)+plot.size.height*.37)],@"mouse hovering plot activates crosshair");
    Require(fabs(sol.charts.firstObject.hoverFraction.y-.37)<.0001,@"hover tracks pointer height after scaling");
    Require(![CandleTurnover(sol.charts.firstObject.candles[HoverIndex(60,.25)]) isEqual:@"—"],@"live selected candle includes quote turnover");
    Snapshot(sol.view,[out stringByAppendingPathComponent:@"crosshair-doge.png"]);
    plot=[tiny plotRectAtIndex:0]; [tiny.view updateHoverAt:NSMakePoint(NSMinX(plot)+plot.size.width*.83,NSMinY(plot)+plot.size.height*.72)];
    Snapshot(tiny.view,[out stringByAppendingPathComponent:@"crosshair-shib.png"]);
    [sol.view mouseExited:[NSEvent enterExitEventWithType:NSEventTypeMouseExited location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:sol.panel.windowNumber context:nil eventNumber:0 trackingNumber:0 userData:NULL]]; Require(!sol.charts.firstObject.hovered,@"crosshair disappears when pointer exits");
    for(NSUInteger i=0;i<root.charts.count;i++) [root toggleChart:i];
    plot=[root plotRectAtIndex:2]; [root.view updateHoverAt:NSMakePoint(NSMidX(plot),NSMidY(plot))];
    Require(Until(^BOOL { return root.charts[2].candles.count>0; },20),@"third main chart loads for hover test");
    [root.view updateHoverAt:NSMakePoint(NSMidX(plot),NSMidY(plot))];
    Require(root.charts[2].hovered && !root.charts[0].hovered && !root.charts[1].hovered,@"hover maps only to the third chart, not the others");
    [root arrangeWindows:nil];
    NSArray *arranged=@[root,sol,tiny,duplicate];
    for(NSUInteger i=0;i<arranged.count;i++) {
        Controller *a=arranged[i]; Require(NSContainsRect(a.panel.screen.visibleFrame,a.panel.frame),@"arranged window stays visible");
        for(NSUInteger j=i+1;j<arranged.count;j++) Require(!NSIntersectsRect(a.panel.frame,[(Controller *)arranged[j] panel].frame),@"one-click arrangement removes all overlaps");
    }
    for(NSUInteger i=0;i<root.charts.count;i++) [root toggleChart:i];
    [root layoutPanel:1];
    NSRect display=tiny.panel.screen.visibleFrame;
    [tiny.panel setFrameOrigin:NSMakePoint(NSMinX(display)+8,NSMinY(display)+9)]; [tiny snapToEdges];
    Require(fabs(tiny.panel.frame.origin.x-NSMinX(display))<.1 && fabs(tiny.panel.frame.origin.y-NSMinY(display))<.1,@"drag-end snapping reaches visible screen edges");
    [root togglePinned:nil]; alpha.tag=80; [root setOpacityFromMenu:alpha];
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
    Require([[root.coinInput itemObjectValueAtIndex:0] isEqual:@"DOGE"],@"recently switched coin is first in suggestions");
    [root cancelPicker:nil];
    Dispose(root);
    Controller *restored=[Controller new]; [restored applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:app]];
    Require(restored.singleWindows.count==3,@"launch restores saved windows rather than overwriting them");
    Require([restored.singleWindows[0].symbols.firstObject isEqual:@"DOGEUSDT"] && [restored.singleWindows[1] digitsForSymbol:@"SHIBUSDT"]==8 && [restored.singleWindows[2].charts.firstObject.interval isEqual:@"4h"],@"switched symbol, tiny-price precision and duplicate-coin interval survive relaunch");
    Require(!restored.pinned && fabs(restored.opacity-.8)<.001 && !restored.singleWindows[0].pinned && fabs(restored.singleWindows[0].opacity-.7)<.001 && !restored.singleWindows[0].snapEnabled,@"per-window pin, opacity and snap settings survive relaunch");
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
    Controller *periodProbe=restored.singleWindows.firstObject;
    for(NSInteger period=0;period<4;period++) {
        NSButton *button=[NSButton new]; button.tag=period;
        [periodProbe selectInterval:button];
        Require(Until(^BOOL { return periodProbe.charts.firstObject.candles.count==60 && CandlesCurrent(periodProbe.charts.firstObject.candles,periodProbe.charts.firstObject.interval,Now()); },20),@"every supported timeframe loads current real candles");
        Require(![CandleTurnover(periodProbe.charts.firstObject.candles.lastObject) isEqual:@"—"],@"real turnover available on every supported timeframe");
    }
    NSLog(@"PASS: real 15m / 1h / 4h / 1d candles and turnover");
    Dispose(restored);
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    puts("PASS: live main + 3 single windows, picker validation/cancel, independent sizing/closing, continued Kline refresh and relaunch restoration");
    return 0;
} }
