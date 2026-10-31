// Opt-in integration check against public Binance endpoints. No app window or account access.
#define main CryptoPulseApplicationMain
#import "../source/main.m"
#undef main
static void Require(BOOL ok, NSString *message) { if(!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
int main(void) { @autoreleasepool {
    Controller *c=[Controller new]; c.quotes=[NSMutableDictionary new];
    c.session=[c newSession]; c.started=Now(); c.lastRecovery=Now(); c.delay=2;
    NSMutableArray *charts=[NSMutableArray new];
    for(NSString *symbol in Symbols()) { ChartState *ch=[ChartState new]; ch.symbol=symbol; ch.expanded=YES; [charts addObject:ch]; }
    c.charts=charts; [c connect]; [c poll];
    for(ChartState *ch in charts) [c fetchChart:ch];
    double disconnected=0, restarted=0;
    NSInteger initialGeneration=c.generation;
    for(int second=1;second<=50;second++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
        [c tick:nil];
        if(second==10) {
            Require([c quotesFresh],@"all three initial quotes must arrive");
            for(ChartState *ch in charts) Require(ch.candles.count==60,@"initial chart has 60 candles");
            disconnected=Now();
            [c.socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
        }
        if(second==25) {
            Require(c.generation>initialGeneration && c.lastWS>disconnected,@"cancelled stream reconnects without app restart");
            Require([c quotesFresh],@"all three quotes remain current after stream interruption");
            restarted=Now(); [c reconnect:nil];
        }
        if(second%10==0) {
            NSMutableArray *states=[NSMutableArray new];
            for(ChartState *ch in charts) [states addObject:[NSString stringWithFormat:@"%@ quote=%.1fs chart=%.1fs",ch.symbol,Now()-c.quotes[ch.symbol].timestamp,Now()-ch.chartFetched]];
            NSLog(@"%ds %@",second,[states componentsJoinedByString:@" | "]);
        }
    }
    Require([c quotesFresh] && c.lastWS>restarted,@"stream and all prices recover after full reconnect");
    for(ChartState *ch in charts) Require(ch.candles.count==60 && ch.chartFetched>restarted && Now()-ch.chartFetched<10,@"each chart keeps refreshing after full reconnect");
    Require(c.streamSession!=c.session && c.streamSession.configuration.timeoutIntervalForResource>RequestDeadline,@"stream has an independent long-lived session");
    [c.session invalidateAndCancel]; [c.streamSession invalidateAndCancel];
    puts("PASS: live BTC/ETH/PENDLE, all charts, stream interruption, full reconnect and continued refresh");
    return 0;
} }
