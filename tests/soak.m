// Real public market soak; network faults affect only this isolated test application.
#define main CryptoPulseApplicationMain
#import "../source/main.m"
#undef main
#import <mach/mach.h>
static void Require(BOOL ok, NSString *message) { if(!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
@interface OfflineProtocol : NSURLProtocol @end
@implementation OfflineProtocol
+(BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+(NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
-(void)startLoading { [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]]; }
-(void)stopLoading {}
@end
@interface SoakController : Controller
@property BOOL offline;
@end
@implementation SoakController
-(Controller *)newWindowController { return [SoakController new]; }
-(NSURLSession *)newSession {
    if(!self.offline) return [super newSession];
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.protocolClasses=@[OfflineProtocol.class];
    return [NSURLSession sessionWithConfiguration:config];
}
-(void)connect {
    if(!self.offline) { [super connect]; return; }
    self.generation++; [self.socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil]; self.socket=nil;
    self.lastConnect=Now(); self.retryAt=Now()+5;
}
@end
static BOOL Fresh(NSArray<SoakController *> *windows, double since) {
    for(SoakController *c in windows) {
        if(![c quotesFresh]) return NO;
        for(ChartState *chart in c.charts) if(chart.expanded && (chart.candles.count!=60 || chart.chartFetched<=since || Now()-chart.chartFetched>15)) return NO;
    }
    return YES;
}
static double RSS(void) {
    struct mach_task_basic_info info; mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;
    return task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&info,&count)==KERN_SUCCESS?info.resident_size/1048576.0:0;
}
int main(void) { @autoreleasepool {
    NSString *domain=NSBundle.mainBundle.bundleIdentifier;
    Require([domain isEqual:@"local.bai.cryptopulsemini.soak-tests"],@"isolated preferences required");
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    NSApplication *app=NSApplication.sharedApplication; [app finishLaunching];
    SoakController *root=[SoakController new];
    [root applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:app]];
    for(NSUInteger i=0;i<root.charts.count;i++) [root toggleChart:i];
    SoakController *sol=(id)[root createSingleWindow:@"SOLUSDT" digits:2 record:nil];
    SoakController *shib=(id)[root createSingleWindow:@"SHIBUSDT" digits:8 record:nil];
    SoakController *duplicate=(id)[root createSingleWindow:@"SOLUSDT" digits:2 record:@{@"interval":@"4h"}];
    NSArray<SoakController *> *windows=@[root,sol,shib,duplicate];
    // UI behavior is covered in windows.m; keep this sustained run out of the user's way.
    for(Controller *c in windows) [c.panel orderOut:nil];
    double duration=MAX(600,[NSProcessInfo.processInfo.environment[@"PULSE_SOAK_SECONDS"] doubleValue]);
    double start=Now(), recovery=0, streamRestart=0, switched=0, staleSince=0, rssStart=RSS();
    BOOL warmed=NO, cut=NO, outageChecked=NO, online=NO, recovered=NO, streamCut=NO, streamRecovered=NO, changed=NO, changeRecovered=NO;
    int sample=0;
    while(Now()-start<duration) { @autoreleasepool {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.25]];
        double elapsed=Now()-start;
        if(!warmed && Fresh(windows,start)) { warmed=YES; NSLog(@"WARMUP passed: six charts and all quotes"); }
        if(elapsed>45) Require(warmed,@"initial real quotes and six charts arrive within 45 seconds");
        if(!cut && elapsed>=60) {
            cut=YES; for(SoakController *c in windows) { c.offline=YES; [c reconnect:nil]; }
            NSLog(@"FAULT: app-only network outage begins");
        }
        if(!outageChecked && elapsed>=80) {
            outageChecked=YES;
            for(SoakController *c in windows) Require(![c quotesFresh],@"outage must not display cached quotes as fresh");
            NSLog(@"PASS: outage correctly marks every window stale");
        }
        if(!online && elapsed>=90) {
            online=YES; recovery=Now();
            for(SoakController *c in windows) { c.offline=NO; c.routeIndex=0; [c wake:nil]; }
            NSLog(@"RESTORE: connection restored; invoking each window's wake handler (no physical OS sleep)");
        }
        if(online && !recovered && Fresh(windows,recovery)) { recovered=YES; NSLog(@"PASS: all windows recovered in %.1fs",Now()-recovery); }
        if(elapsed>=135) Require(recovered,@"all windows recover after outage and wake handling within 45 seconds");
        if(!streamCut && elapsed>=180) {
            streamCut=YES; streamRestart=Now();
            for(SoakController *c in windows) [c.socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
            NSLog(@"FAULT: cancelling each live stream");
        }
        if(streamCut && !streamRecovered) {
            BOOL ok=Fresh(windows,streamRestart);
            for(SoakController *c in windows) ok=ok && c.lastWS>streamRestart;
            if(ok) { streamRecovered=YES; NSLog(@"PASS: every live stream and chart recovered in %.1fs",Now()-streamRestart); }
        }
        if(elapsed>=240) Require(streamRecovered,@"all real streams recover without app restart within 60 seconds");
        if(!changed && elapsed>=300) {
            changed=YES; switched=Now(); [sol replaceSymbol:@"DOGEUSDT" digits:5];
            Require(root.singleWindows.count==3,@"coin switch preserves window count");
            NSLog(@"ACTION: same-window SOL -> DOGE");
        }
        if(changed && !changeRecovered && Fresh(windows,switched)) { changeRecovered=YES; NSLog(@"PASS: continued data after coin switch in %.1fs",Now()-switched); }
        if(elapsed>=345) Require(changeRecovered,@"new coin gets fresh data within 45 seconds");
        // A short transient is allowed, but outside fault/recovery windows no silent prolonged freeze is allowed.
        BOOL settling=(elapsed<45 || (elapsed>=60 && elapsed<135) || (elapsed>=180 && elapsed<240) || (elapsed>=300 && elapsed<345));
        if(settling || Fresh(windows,0)) staleSince=0;
        else if(!staleSince) staleSince=Now();
        Require(!staleSince || Now()-staleSince<30,@"no unexplained stale-data streak longer than 30 seconds");
        if((int)(elapsed/30)>sample) {
            sample=(int)(elapsed/30); NSMutableArray *states=[NSMutableArray new];
            for(SoakController *c in windows) for(ChartState *ch in c.charts) {
                [states addObject:[NSString stringWithFormat:@"%@/%@ q=%.1f c=%.1f%@",ch.symbol,ch.interval,Now()-c.quotes[ch.symbol].timestamp,Now()-ch.chartFetched,ch.chartError?[@" ERROR:" stringByAppendingString:ch.chartError]:@""]];
            }
            NSLog(@"SAMPLE %.0fs RSS=%.1fMB %@",elapsed,RSS(),[states componentsJoinedByString:@" | "]);
        }
    } }
    Require(Fresh(windows,switched),@"all quotes and six charts are current at completion");
    NSLog(@"PASS: %.0fs sustained run, main + 3 single windows, six charts; outage/wake handler, stream recovery, same-window switch. RSS %.1f -> %.1fMB (observation, not leak proof)",Now()-start,rssStart,RSS());
    [root applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:app]];
    for(Controller *c in windows) { c.panel.delegate=nil; [c.panel close]; }
    [NSStatusBar.systemStatusBar removeStatusItem:root.status];
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    return 0;
} }
