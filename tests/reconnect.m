#define main CryptoPulseApplicationMain
#import "../source/main.m"
#undef main

typedef void (^Completion)(NSData *, NSURLResponse *, NSError *);
@interface FakeTask : NSObject
@property BOOL cancelled, resumed;
@property NSURLRequest *request;
@property(copy) Completion completion;
-(void)resume;
-(void)cancel;
-(void)cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason;
-(void)finish:(id)json error:(BOOL)error;
@end
@implementation FakeTask
-(void)resume { self.resumed=YES; }
-(void)cancel { self.cancelled=YES; }
-(void)cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason { [self cancel]; }
-(void)finish:(id)json error:(BOOL)error {
    NSData *data=json?[NSJSONSerialization dataWithJSONObject:json options:0 error:nil]:nil;
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    self.completion(data,response,error?[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]:nil);
    // Completion is intentionally delivered even after cancel, to model the race.
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,.01,false);
}
@end
@interface FakeSession : NSObject
@property NSMutableArray<FakeTask *> *tasks;
@property BOOL invalidated;
-(NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(Completion)completion;
-(void)invalidateAndCancel;
@end
@implementation FakeSession
-(instancetype)init { if((self=[super init])) self.tasks=[NSMutableArray new]; return self; }
-(NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(Completion)completion {
    FakeTask *task=[FakeTask new]; task.request=request; task.completion=completion; [self.tasks addObject:task]; return (id)task;
}
-(void)invalidateAndCancel { self.invalidated=YES; for(FakeTask *task in self.tasks) [task cancel]; }
@end
@interface TestController : Controller
@property NSInteger connections;
@end
@implementation TestController
-(NSURLSession *)newSession { return (id)[FakeSession new]; }
-(void)connect { self.connections++; self.generation++; self.lastConnect=Now(); self.socket=(id)[FakeTask new]; }
-(void)show:(id)sender {}
@end
static TestController *Fixture(void) {
    TestController *c=[TestController new];
    c.quotes=[NSMutableDictionary new]; c.session=[c newSession]; c.started=Now(); c.lastRecovery=Now(); c.lastWS=Now(); c.socket=(id)[FakeTask new];
    ChartState *btc=[ChartState new]; btc.symbol=@"BTCUSDT"; btc.expanded=YES;
    ChartState *eth=[ChartState new]; eth.symbol=@"ETHUSDT"; eth.expanded=YES;
    ChartState *pendle=[ChartState new]; pendle.symbol=@"PENDLEUSDT"; pendle.expanded=YES;
    c.charts=@[btc,eth,pendle]; return c;
}
static NSArray *Candles(void) { return @[@[@1000,@"10",@"12",@"9",@"11",@"1",@2000]]; }
static void Check(BOOL success, NSString *message) { if(!success) { NSLog(@"FAIL: %@",message); exit(1); } }
int main(void) { @autoreleasepool {
    TestController *c=Fixture(); ChartState *btc=c.charts[0], *eth=c.charts[1];
    btc.interval=@"4h"; eth.interval=@"1d";
    btc.candles=Candles(); btc.chartFetched=Now()-20;
    [c fetchChart:btc]; [c fetchChart:eth]; [c poll];
    FakeSession *old=(id)c.session; FakeTask *oldBTC=(id)btc.chartTask, *oldETH=(id)eth.chartTask, *oldPoll=(id)c.pollTask;
    btc.chartAttempt=Now()-13;
    [c tick:nil];
    FakeTask *newBTC=(id)btc.chartTask, *newETH=(id)eth.chartTask, *newPoll=(id)c.pollTask;
    Check(old.invalidated && oldBTC.cancelled && oldETH.cancelled && oldPoll.cancelled,@"hung request cancels all old work");
    Check(c.connections==1 && (id)c.session!=old,@"hung chart rebuilds session and reconnects stream");
    Check(newBTC.resumed && newETH.resumed && newPoll.resumed,@"both charts and price poll restart immediately");
    Check(btc.expanded && eth.expanded && [btc.interval isEqual:@"4h"] && [eth.interval isEqual:@"1d"] && btc.candles.count==1,@"recovery retains charts, intervals and last candles");
    [oldBTC finish:nil error:YES]; [oldETH finish:Candles() error:NO]; [oldPoll finish:nil error:YES];
    Check((id)btc.chartTask==newBTC && (id)eth.chartTask==newETH && (id)c.pollTask==newPoll && c.polling && !btc.chartError,@"late callbacks cannot clear new requests or overwrite state");
    [newBTC finish:Candles() error:NO]; [newETH finish:Candles() error:NO];
    Check(!btc.chartTask && !eth.chartTask && Now()-btc.chartFetched<1 && Now()-eth.chartFetched<1,@"new session successfully restores fresh candles");
    [newPoll finish:@[@{@"symbol":@"BTCUSDT",@"lastPrice":@"100",@"priceChangePercent":@"1",@"closeTime":@(Now()*1000)}] error:NO];
    Check(!c.polling && !c.pollTask && c.quotes.count==1,@"new price request completes normally");
    c.lastWS=Now(); NSInteger before=c.connections; [c tick:nil];
    Check(c.connections==before && !btc.chartTask,@"healthy request cadence does not reset connections");
    btc.chartAttempt=Now()-6; [c tick:nil];
    Check(btc.chartTask!=nil,@"normal five-second chart polling continues after recovery");
    puts("PASS: hung chart recovery, both symbols, settings preserved, late-callback races, fresh data and continued refresh");

    c=Fixture(); [c poll]; c.lastPoll=Now()-13; [c tick:nil];
    Check(c.connections==1 && c.polling && c.pollTask && c.charts[0].chartTask,@"hung price poll cannot permanently block subsequent polls");
    puts("PASS: hung quote polling recovery");

    c=Fixture(); btc=c.charts[0]; eth=c.charts[1]; eth.expanded=NO;
    [c fetchChart:btc]; oldBTC=(id)btc.chartTask; [oldBTC finish:nil error:YES];
    Check(!btc.chartTask && btc.chartError!=nil,@"failed chart clears pending flag");
    btc.chartAttempt=Now()-6; [c tick:nil];
    Check(btc.chartTask && c.connections==0,@"fast failures retry at normal cadence");
    [(FakeTask *)(id)btc.chartTask finish:nil error:YES];
    c.lastRecovery=Now()-31; [c tick:nil];
    Check(c.connections==1 && btc.chartTask && !eth.chartTask,@"sustained outage renews connection pool without loading collapsed charts");
    puts("PASS: quick failures retry; prolonged failure renews session");

    c=Fixture(); btc=c.charts[0]; [c fetchChart:btc]; oldBTC=(id)btc.chartTask;
    [c wake:nil]; newBTC=(id)btc.chartTask;
    Check(oldBTC.cancelled && newBTC!=oldBTC && c.connections==1 && c.polling,@"wake resets charts, quotes and stream together");
    [oldBTC finish:Candles() error:NO]; Check((id)btc.chartTask==newBTC && !btc.candles.count,@"late pre-wake data ignored");
    [newBTC finish:Candles() error:NO]; Check(btc.candles.count==1 && !btc.chartTask,@"post-wake data succeeds");
    [c reconnect:nil]; Check(c.connections==2 && btc.chartTask,@"manual reconnect works without restarting app");
    puts("PASS: wake recovery and manual reconnect");

    c=Fixture(); btc=c.charts[0]; [c fetchChart:btc]; oldBTC=(id)btc.chartTask;
    btc.chartGeneration++; [btc.chartTask cancel]; btc.chartTask=nil; btc.interval=@"1h"; [c fetchChart:btc]; newBTC=(id)btc.chartTask;
    [oldBTC finish:Candles() error:NO]; Check((id)btc.chartTask==newBTC && !btc.candles.count,@"old interval response cannot overwrite new interval");
    [newBTC finish:Candles() error:NO]; Check(!btc.chartTask && btc.candles.count==1,@"new interval succeeds");
    puts("PASS: interval change cancellation race");

    c=Fixture(); ChartState *pendle=c.charts[2];
    Check(([c accept:@{@"s":@"PENDLEUSDT",@"c":@"1.9381",@"P":@"-1.524",@"E":@(Now()*1000)} live:YES]),@"PENDLE live ticker accepted");
    Check(([c accept:@{@"symbol":@"PENDLEUSDT",@"lastPrice":@"1.9382",@"priceChangePercent":@"-1.5",@"closeTime":@(Now()*1000+1)} live:NO]),@"PENDLE fallback quote accepted");
    Check(fabs(c.quotes[@"PENDLEUSDT"].price-1.9382)<.00001 && PriceDigits(pendle.symbol)==4,@"PENDLE sub-cent precision retained");
    Check((![c accept:@{@"s":@"OTHERUSDT",@"c":@"1",@"P":@"1",@"E":@(Now()*1000)} live:YES]),@"unsupported symbol rejected");
    [c fetchChart:pendle]; FakeTask *oldPendle=(id)pendle.chartTask;
    Check([oldPendle.request.URL.absoluteString containsString:@"symbol=PENDLEUSDT"],@"PENDLE chart uses its own trading pair");
    pendle.chartAttempt=Now()-13; [c tick:nil]; FakeTask *newPendle=(id)pendle.chartTask;
    Check(oldPendle.cancelled && newPendle.resumed && c.charts[0].chartTask && c.charts[1].chartTask,@"third chart timeout reconnects all three charts");
    [oldPendle finish:nil error:YES]; Check((id)pendle.chartTask==newPendle,@"late PENDLE callback cannot clear new request");
    [newPendle finish:Candles() error:NO]; Check(!pendle.chartTask && pendle.candles.count==1,@"PENDLE chart recovers");
    FakeTask *poll=(id)c.pollTask;
    NSURLComponents *components=[NSURLComponents componentsWithURL:poll.request.URL resolvingAgainstBaseURL:NO];
    NSArray *requested=[NSJSONSerialization JSONObjectWithData:[components.queryItems.firstObject.value dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    Check([requested isEqual:Symbols()],@"fallback poll requests all three symbols");
    for(ChartState *chart in c.charts) chart.expanded=NO;
    Check([c baseHeight]==305 && [c rowY:2]==193,@"collapsed three-row layout");
    c.charts[0].expanded=YES; c.charts[1].expanded=YES;
    Check([c rowY:2]==713 && [c baseHeight]==825,@"PENDLE follows both expanded charts without overlap");
    pendle.expanded=YES; Check([c baseHeight]==1085,@"all three charts contribute to window height");
    puts("PASS: PENDLE live/fallback prices, precision, Kline, three-symbol recovery and layout");
    return 0;
} }
