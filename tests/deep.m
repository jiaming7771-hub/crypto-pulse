#define main CryptoPulseApplicationMain
#import "../source/main.m"
#undef main
static int failures=0, checks=0;
static void Check(BOOL ok, NSString *message) { checks++; if(!ok) { failures++; NSLog(@"FAIL: %@",message); } }
@interface LocalController : Controller @end
@implementation LocalController
-(Controller *)newWindowController { return [LocalController new]; }
-(void)connect {}
-(void)poll {}
-(void)fetchChart:(ChartState *)chart {}
@end
static void Dispose(Controller *root) {
    [root applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
    for(Controller *c in [@[root] arrayByAddingObjectsFromArray:root.singleWindows]) { c.panel.delegate=nil; [c.panel close]; }
    [NSStatusBar.systemStatusBar removeStatusItem:root.status];
}
int main(void) { @autoreleasepool {
    NSString *domain=NSBundle.mainBundle.bundleIdentifier;
    if(![domain isEqual:@"local.bai.cryptopulsemini.deep-tests"]) return 2;
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    NSApplication *app=NSApplication.sharedApplication; [app finishLaunching];
    LocalController *root=[LocalController new]; [root applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:app]];
    for(NSUInteger i=0;i<3;i++) [root toggleChart:i];
    [root reset:nil];
    Check(NSContainsRect(NSScreen.mainScreen.visibleFrame,root.panel.frame),@"reset fully-expanded main window stays within usable display");
    Controller *small=[root createSingleWindow:@"SOLUSDT" digits:2 record:nil];
    NSRect region=NSMakeRect(100,100,140,200);
    [small layoutPanel:1 inVisibleFrame:region]; NSRect original=small.panel.frame;
    Check(original.size.width<248,@"narrow arrangement reproduces scale below the normal manual minimum");
    [small replaceSymbol:@"DOGEUSDT" digits:5];
    Check(NSEqualRects(original,small.panel.frame),@"coin switch keeps a window shrunk by arrangement exactly the same size and position");
    NSButton *zoom=[NSButton new]; zoom.tag=-1; [small zoom:zoom];
    Check(small.panel.frame.size.width<=original.size.width+.01,@"minus never enlarges an arranged small window");
    zoom.tag=1; double oldWidth=small.panel.frame.size.width; [small zoom:zoom];
    Check(small.panel.frame.size.width>oldWidth && small.panel.frame.size.width<=oldWidth+31.01,@"plus grows an arranged small window by one step");
    [small layoutPanel:1 inVisibleFrame:region]; original=small.panel.frame;
    root.charts[0].interval=@"1h"; root.charts[2].interval=@"4h"; [root toggleChart:1];
    [root saveSingleWindows]; Dispose(root);
    LocalController *restored=[LocalController new]; [restored applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:app]];
    Check(restored.singleWindows.count==1,@"one saved single window restored");
    Check(NSEqualRects(original,restored.singleWindows.firstObject.panel.frame),@"restart keeps the arranged small window geometry");
    Check(restored.charts[0].expanded && !restored.charts[1].expanded && restored.charts[2].expanded && [restored.charts[0].interval isEqual:@"1h"] && [restored.charts[2].interval isEqual:@"4h"],@"main-window chart expansion and periods survive restart too");
    NSRect screen=NSMakeRect(-1280,-100,1280,720);
    for(NSUInteger count=1;count<=30;count++) {
        NSMutableArray *heights=[NSMutableArray new],*scales=[NSMutableArray new];
        for(NSUInteger i=0;i<count;i++) { [heights addObject:@(i%3==0?1085:(i%3==1?415:155))]; [scales addObject:@(.8+(i%7)*.2)]; }
        NSArray *cells=TileCells(heights,scales,screen);
        for(NSUInteger i=0;i<count;i++) {
            NSRect a=[cells[i] rectValue]; Check(a.size.width>0 && a.size.height>0 && NSContainsRect(screen,a),@"tiling property: all cells finite, positive and visible");
            for(NSUInteger j=i+1;j<count;j++) Check(!NSIntersectsRect(a,[cells[j] rectValue]),@"tiling property: no pair overlaps");
        }
    }
    for(int edge=0;edge<4;edge++) {
        NSRect f=NSMakeRect(-900,100,310,415);
        if(edge==0) f.origin.x=NSMinX(screen)+24;
        if(edge==1) f.origin.x=NSMaxX(screen)-f.size.width-24;
        if(edge==2) f.origin.y=NSMinY(screen)+24;
        if(edge==3) f.origin.y=NSMaxY(screen)-f.size.height-24;
        NSRect snapped=SnapFrame(f,screen,24);
        Check(!NSEqualRects(f,snapped),@"snap activates at the threshold on all four edges");
    }
    // Exercise hover at both plot corners, at minimum/maximum normal zoom and across main rows.
    double opening=floor(Now()/900)*900*1000;
    NSMutableArray *rows=[NSMutableArray new];
    for(NSUInteger i=0;i<60;i++) [rows addObject:@[@(opening-(59-i)*900000),@"100",@"120",@"90",@"110",@"999",@(opening-(59-i)*900000+899999),@"123456789.12"]];
    for(ChartState *chart in restored.charts) { chart.candles=rows; chart.chartFetched=Now(); }
    for(NSNumber *scale in @[@.8,@2]) {
        [restored layoutPanel:scale.doubleValue];
        for(NSUInteger row=0;row<restored.charts.count;row++) if(restored.charts[row].expanded) {
            NSRect plot=[restored plotRectAtIndex:row];
            for(NSValue *point in @[[NSValue valueWithPoint:NSMakePoint(NSMinX(plot)+.01,NSMinY(plot)+.01)],[NSValue valueWithPoint:NSMakePoint(NSMaxX(plot)-.01,NSMaxY(plot)-.01)]]) {
                Check([restored.view updateHoverAt:point.pointValue],@"scaled hover accepts both plot corners");
                NSUInteger hovered=0; for(ChartState *chart in restored.charts) hovered+=chart.hovered;
                Check(hovered==1 && restored.charts[row].hovered,@"hover belongs to exactly one expanded chart");
            }
        }
        [restored.view displayIfNeeded];
        NSBitmapImageRep *bitmap=[restored.view bitmapImageRepForCachingDisplayInRect:restored.view.bounds];
        [restored.view cacheDisplayInRect:restored.view.bounds toBitmapImageRep:bitmap];
        NSString *path=[NSString stringWithFormat:@".build/deep-main-%.1f.png",scale.doubleValue];
        Check([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES],@"main chart edge-hover screenshot saved");
    }
    [restored.view updateHoverAt:NSMakePoint(-1,-1)];
    for(ChartState *chart in restored.charts) Check(!chart.hovered,@"all hover states clear outside charts");
    Controller *victim=restored.singleWindows.firstObject;
    [victim switchCoin:nil]; [victim closeWindow:nil];
    Check(!restored.switchTarget && !restored.picker.visible && !restored.replacingCoin,@"closing a switch target cancels its picker");
    [NSUserDefaults.standardUserDefaults setObject:@[@"junk",@{},@{@"symbol":@123},@{@"symbol":@"BAD!"}] forKey:@"SingleCoinWindows"];
    [restored restoreSingleWindows]; Check(restored.singleWindows.count==0,@"malformed restore entries are ignored");
    Dispose(restored); [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    NSLog(@"DEEP: %d checks, %d failures",checks,failures);
    return failures?1:0;
} }
