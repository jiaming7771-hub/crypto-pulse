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
-(Controller *)newWindowController { return [TestController new]; }
-(void)saveSingleWindows {}
-(void)layoutPanel:(double)scale {}
-(void)startWindow {
    self.quotes=[NSMutableDictionary new]; self.session=[self newSession];
    self.started=Now(); self.lastRecovery=Now(); self.delay=2;
    [self connect]; [self poll];
    for(ChartState *chart in self.charts) if(chart.expanded) [self fetchChart:chart];
}
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

    c=Fixture(); for(ChartState *chart in c.charts) chart.expanded=NO;
    [c poll]; oldPoll=(id)c.pollTask; [oldPoll finish:nil error:YES];
    Check(c.apiIndex==1 && c.networkError!=nil,@"failed endpoint selects another official API host");
    [c poll]; newPoll=(id)c.pollTask;
    Check([newPoll.request.URL.host isEqual:@"api.binance.com"],@"next request actually uses fallback host");
    [newPoll finish:@{} error:NO]; Check(c.apiIndex==2,@"malformed response cannot be treated as a connection success");
    old=(id)c.session; c.started=Now()-60; c.lastRecovery=Now()-31; c.lastWS=0;
    [c tick:nil];
    Check(old.invalidated && c.connections==1 && c.polling && c.routeIndex==1,@"fast failures with all charts collapsed renew session and try direct route");
    Check(!c.charts[0].chartTask && !c.charts[1].chartTask && !c.charts[2].chartTask,@"recovery does not open collapsed charts");
    NSUInteger selected=c.apiIndex;
    [oldPoll finish:nil error:YES];
    Check(c.apiIndex==selected && c.polling,@"late failed request cannot change newly selected route");
    puts("PASS: collapsed-window outage, alternate hosts/routes, malformed data and late-failure isolation");

    c=Fixture(); for(ChartState *chart in c.charts) chart.expanded=NO;
    for(NSString *symbol in @[@"BTCUSDT",@"ETHUSDT"]) [c accept:@{@"s":symbol,@"c":@"100",@"P":@"1",@"E":@(Now()*1000)} live:YES];
    c.lastWS=Now(); c.lastPoll=Now()-6; [c tick:nil];
    Check(c.polling,@"healthy BTC and ETH stream cannot suppress a missing PENDLE fallback");
    NSMutableArray *complete=[NSMutableArray new];
    for(NSString *symbol in Symbols()) [complete addObject:@{@"symbol":symbol,@"lastPrice":@"100",@"priceChangePercent":@"1",@"closeTime":@(Now()*1000+1)}];
    [(FakeTask *)(id)c.pollTask finish:complete error:NO];
    Check([c quotesFresh] && !c.networkError,@"complete response restores all three coins");
    c.lastPoll=Now()-6; c.lastWS=Now(); [c tick:nil];
    Check(!c.polling && c.connections==0,@"healthy streams avoid needless fallback and reconnection");
    puts("PASS: per-coin freshness and REST fallback without disrupting healthy streams");

    c=Fixture();
    NSHTTPURLResponse *limited=[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:APIHosts()[0]] statusCode:429 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Retry-After":@"60"}];
    [c requestFailed:nil response:limited endpoint:0]; [c poll]; [c fetchChart:c.charts[0]];
    Check(c.restRetryAt>Now()+59 && !c.polling && !c.charts[0].chartTask && c.apiIndex==0,@"rate limiting pauses REST instead of hammering alternate hosts");
    c.restRetryAt=Now()-1; [c poll]; Check(c.polling,@"REST resumes when rate-limit cooldown ends");
    limited=[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:APIHosts()[0]] statusCode:418 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Retry-After":@"3600"}];
    [c requestFailed:nil response:limited endpoint:0];
    Check(c.restRetryAt>Now()+3599,@"long server cooldown is not shortened by the client");
    puts("PASS: server cooldown respected and polling resumes");

    c=Fixture(); for(ChartState *chart in c.charts) chart.expanded=NO;
    c.started=Now()-60; c.lastRecovery=Now()-5;
    [c poll]; c.lastPoll=Now()-13; [c tick:nil];
    Check(c.routeIndex==1,@"repeated hung-task resets cannot indefinitely postpone route switching");
    c.lastPoll=Now()-13; [c tick:nil];
    Check(c.routeIndex==1,@"route switching is bounded during repeated timeouts");
    Controller *real=[Controller new]; NSURLSession *normal=[real newSession];
    Check(normal.configuration.timeoutIntervalForResource==RequestDeadline,@"REST retains bounded resource timeout");
    real.routeIndex=1; NSURLSession *direct=[real newSession];
    Check(direct.configuration.connectionProxyDictionary.count==0 && direct.configuration.connectionProxyDictionary!=nil,@"direct fallback overrides proxy for this session only");
    [normal invalidateAndCancel]; [direct invalidateAndCancel];
    puts("PASS: bounded route switching and per-session proxy fallback");

    c=Fixture(); for(ChartState *chart in c.charts) chart.expanded=NO;
    c.lastWS=Now()-25; c.lastConnect=Now()-25;
    [c tick:nil];
    Check(c.streamIndex==1 && c.connections==1,@"silent stream switches endpoint even without an error callback");
    puts("PASS: silent stream fallback");

    Check([NormalizeSymbol(@" sol/usdt ") isEqual:@"SOLUSDT"] && [NormalizeSymbol(@"doge") isEqual:@"DOGEUSDT"],@"coin input accepts short names and pairs");
    Check(!NormalizeSymbol(@"USDT") && !NormalizeSymbol(@"../../BTC") && !NormalizeSymbol(@"") && !NormalizeSymbol(@"BTC?x=1"),@"invalid coin input is rejected");
    NSDictionary *(^market)(NSString *,NSString *,NSString *)=^NSDictionary *(NSString *symbol,NSString *status,NSString *tick) { return @{@"symbols":@[@{@"symbol":symbol,@"quoteAsset":@"USDT",@"status":status,@"isSpotTradingAllowed":@YES,@"filters":@[@{@"filterType":@"PRICE_FILTER",@"tickSize":tick}]}]}; };
    Check([MarketDigits(market(@"SOLUSDT",@"TRADING",@"0.01000000"),@"SOLUSDT") isEqual:@2],@"SOL precision comes from tick size");
    Check([MarketDigits(market(@"SHIBUSDT",@"TRADING",@"0.00000001"),@"SHIBUSDT") isEqual:@8],@"small-price tokens retain eight decimals");
    Check(!MarketDigits(market(@"SOLUSDT",@"BREAK",@"0.01"),@"SOLUSDT") && !MarketDigits(@{},@"SOLUSDT"),@"paused or malformed markets cannot open");
    Check([MarketDigits(market(@"PENDLEUSDT",@"TRADING",@"0.00100000"),@"PENDLEUSDT") isEqual:@4],@"PENDLE preserves existing four-digit display");
    puts("PASS: coin input validation, tradable spot pairs and price precision");

    TestController *root=Fixture(); root.singleWindows=[NSMutableArray new];
    Controller *single=[root createSingleWindow:@"SOLUSDT" digits:2 record:nil];
    Controller *duplicate=[root createSingleWindow:@"SOLUSDT" digits:2 record:@{@"interval":@"4h",@"expanded":@NO}];
    Controller *tiny=[root createSingleWindow:@"SHIBUSDT" digits:8 record:nil];
    Check(root.singleWindows.count==3 && [root.symbols isEqual:Symbols()],@"main keeps three original coins beside three independent windows");
    Check(![single.windowID isEqual:duplicate.windowID] && single.charts.firstObject.expanded && !duplicate.charts.firstObject.expanded,@"duplicate coins have independent chart state and identity");
    Check([duplicate.charts.firstObject.interval isEqual:@"4h"] && [tiny digitsForSymbol:@"SHIBUSDT"]==8,@"restored interval and precision are preserved");
    poll=(id)single.pollTask; components=[NSURLComponents componentsWithURL:poll.request.URL resolvingAgainstBaseURL:NO];
    requested=[NSJSONSerialization JSONObjectWithData:[components.queryItems.firstObject.value dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    Check([requested isEqual:@[@"SOLUSDT"]],@"single window subscribes only to its selected coin");
    Check(([single accept:@{@"s":@"SOLUSDT",@"c":@"150",@"P":@"1",@"E":@(Now()*1000)} live:YES]),@"single window accepts selected market");
    Check(([single quotesFresh] && ![single accept:@{@"s":@"BTCUSDT",@"c":@"100",@"P":@"1",@"E":@(Now()*1000)} live:YES]),@"single-coin freshness and isolation");
    FakeSession *otherSession=(id)duplicate.session; oldBTC=(id)single.charts.firstObject.chartTask; oldPoll=(id)single.pollTask;
    NSInteger mainConnections=root.connections;
    [single closeWindow:nil];
    Check(root.singleWindows.count==2 && single.closed && !single.polling && oldBTC.cancelled && oldPoll.cancelled,@"closing one window cancels only its requests");
    Check(!otherSession.invalidated && root.connections==mainConnections && duplicate.polling,@"other windows keep their sessions and data");
    [oldBTC finish:Candles() error:NO]; [oldPoll finish:nil error:YES]; [single tick:nil]; [single reconnect:nil];
    Check(!single.session && !single.charts.firstObject.candles.count && !single.polling,@"late callbacks cannot resurrect a closed window");
    for(int i=0;i<5;i++) [root createSingleWindow:@"BTCUSDT" digits:2 record:nil];
    Check(root.singleWindows.count==7,@"window count is not capped at three");
    for(Controller *child in root.singleWindows.copy) [child closeWindow:nil];
    Check(!root.singleWindows.count && [root.symbols isEqual:Symbols()],@"closing all single windows leaves the main configuration intact");
    puts("PASS: independent single windows, duplicate coins, restored state, closure races and no three-window cap");
    return 0;
} }
