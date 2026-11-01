#define main CryptoPulseApplicationMain
#import "../source/main.m"
#undef main
static void Require(BOOL ok,NSString *message) { if(!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
static BOOL Until(BOOL (^condition)(void),double seconds) { double deadline=Now()+seconds; while(Now()<deadline) { @autoreleasepool { if(condition()) return YES; [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]]; } } return condition(); }
static NSArray *Bars(double cutoff, NSString *interval) {
    NSUInteger count=ScreenSamples(interval)+1,seconds=ScreenSeconds(interval);
    NSMutableArray *bars=[NSMutableArray new];
    for(NSUInteger i=0;i<count;i++) { double t=(cutoff-(count-i)*seconds)*1000; NSString *price=[NSString stringWithFormat:@"%.8f",100+i+(i%3)*.5]; [bars addObject:@[@(t),price,price,price,price,@"1",@(t+seconds*1000-1),@"100"]]; }
    return bars;
}
static NSArray *Markets(void) {
    NSISO8601DateFormatter *dates=[NSISO8601DateFormatter new]; dates.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds;
    NSMutableArray *coins=[NSMutableArray new];
    for(NSUInteger i=1;i<=200;i++) [coins addObject:@{@"id":[NSString stringWithFormat:@"coin-%lu",i],@"symbol":[NSString stringWithFormat:@"C%lu",i],@"name":@"Test coin",@"market_cap_rank":@(i),@"market_cap":@(1000000-i),@"last_updated":[dates stringFromDate:NSDate.date]}];
    return coins;
}
@interface ScanProtocol : NSURLProtocol @end
@implementation ScanProtocol
+(BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+(NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
-(void)startLoading {
    NSInteger status=[self.request.URL.path isEqual:@"/limited"]?429:200;
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{@"Retry-After":@"60"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[@"[]" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
}
-(void)stopLoading {}
@end
@interface StubScreener : BTCScreener
@property NSUInteger requests, maximumActive;
@end
@implementation StubScreener
-(void)fetchBinance:(NSString *)path endpoint:(NSUInteger)endpoint token:(NSInteger)token completion:(void (^)(id,NSString *))completion {
    self.requests++; self.maximumActive=MAX(self.maximumActive,self.active);
    dispatch_async(dispatch_get_main_queue(),^{ if(token==self.generation && self.running) completion(Bars(self.cutoff,self.interval),nil); });
}
@end
int main(int argc,const char **argv) { @autoreleasepool {
    NSString *domain=NSBundle.mainBundle.bundleIdentifier;
    Require([domain isEqual:@"local.bai.cryptopulsemini.screener-tests"],@"isolated test preferences");
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    NSApplication *app=NSApplication.sharedApplication; [app finishLaunching];
    double cutoff=floor(Now()/900)*900;
    NSArray *returns=AlignedReturns(Bars(cutoff,@"15m"),cutoff,@"15m");
    Require(returns.count==96,@"97 aligned closes produce 96 closed-period returns");
    Require(fabs(ReturnCorrelation(returns,returns)-1)<1e-12,@"identical return patterns correlate +1");
    NSMutableArray *negative=[NSMutableArray new],*scaled=[NSMutableArray new],*flat=[NSMutableArray new];
    for(NSNumber *value in returns) { [negative addObject:@(-value.doubleValue)]; [scaled addObject:@(value.doubleValue*3+.2)]; [flat addObject:@(.01)]; }
    Require(fabs(ReturnCorrelation(returns,negative)+1)<1e-12 && fabs(ReturnCorrelation(returns,scaled)-1)<1e-12,@"signed correlation, scaling and centering");
    Require(!isfinite(ReturnCorrelation(returns,flat)) && !isfinite(ReturnCorrelation(@[],returns)),@"flat or missing data cannot create a score");
    Require(!AlignedReturns(Bars(cutoff+900,@"15m"),cutoff,@"15m") && !AlignedReturns([Bars(cutoff,@"15m") subarrayWithRange:NSMakeRange(1,96)],cutoff,@"15m"),@"future, unfinished or missing bars are rejected, never misaligned");
    double hourCut=floor(Now()/3600)*3600;
    NSArray *hours=AlignedReturns(Bars(hourCut,@"1h"),hourCut,@"1h");
    Require(hours.count==24 && fabs(ReturnCorrelation(hours,hours)-1)<1e-12,@"hourly mode uses 25 closes and 24 returns within 24 hours");
    Require(!AlignedReturns(Bars(hourCut,@"15m"),hourCut,@"1h") && !isfinite(ReturnCorrelation(hours,returns)),@"different periods and sample counts cannot be mixed");
    Require([ScreenKlines(@"BTCUSDT",hourCut,@"1h") containsString:@"interval=1h&limit=25"],@"hourly request uses correct interval and anchor count");
    NSArray *markets=Markets(); Require(ScreenMarkets(markets,Now())!=nil,@"fresh complete top-200 ranking accepted");
    Require(!ScreenMarkets(markets,Now()+3601),@"stale rankings rejected");
    NSMutableArray *oneStale=[markets mutableCopy]; NSMutableDictionary *staleRecord=[oneStale[150] mutableCopy]; staleRecord[@"last_updated"]=@"2020-01-01T00:00:00.000Z"; oneStale[150]=staleRecord;
    NSArray *validated=ScreenMarkets(oneStale,Now()); Require(validated.count==200 && [validated[150][@"staleMarket"] boolValue],@"one illiquid stale asset is flagged without blocking the current complete ranking");
    NSMutableArray *duplicate=[markets mutableCopy]; duplicate[199]=duplicate[0]; Require(!ScreenMarkets(duplicate,Now()),@"duplicate ranks/IDs cannot stand for top 200");
    NSArray *sample=@[@{@"id":@"bitcoin",@"symbol":@"BTC"},@{@"id":@"stable",@"symbol":@"USDT"},@{@"id":@"wrapped",@"symbol":@"WBTC"},@{@"id":@"solana",@"symbol":@"SOL"},@{@"id":@"missing",@"symbol":@"MISS"}];
    NSDictionary *exchange=@{@"symbols":@[@{@"symbol":@"SOLUSDT",@"baseAsset":@"SOL",@"quoteAsset":@"USDT",@"status":@"TRADING",@"isSpotTradingAllowed":@YES,@"filters":@[@{@"filterType":@"PRICE_FILTER",@"tickSize":@"0.01000000"}]}]};
    NSUInteger excluded=0,unsupported=0; NSArray *eligible=ScreenCandidates(sample,[NSSet setWithArray:@[@"stable",@"wrapped"]],exchange,&excluded,&unsupported);
    Require(eligible.count==1 && excluded==3 && unsupported==1 && [eligible[0][@"pair"] isEqual:@"SOLUSDT"],@"BTC/stables/wrapped BTC and unavailable pairs excluded before scanning");
    NSDictionary *staleSol=@{@"id":@"solana",@"symbol":@"SOL",@"staleMarket":@YES};
    Require(ScreenCandidates(@[staleSol],NSSet.set,exchange,&excluded,&unsupported).count==0 && unsupported==1,@"stale market entries cannot enter the candidates even with a valid exchange pair");
    NSMutableArray *ranks=[NSMutableArray new];
    for(NSUInteger i=0;i<20;i++) [ranks addObject:@{@"market_cap_rank":@(i+1),@"correlation":@(.99-i*.02)}];
    NSArray *top=TopMatches(ranks); Require(top.count==10 && [top[0][@"correlation"] doubleValue]==.99,@"only ten strongest scores at or above threshold");
    Require(TopMatches(@[@{@"correlation":@.799,@"market_cap_rank":@1},@{@"correlation":@(-.99),@"market_cap_rank":@2}]).count==0,@"weak and inverse matches do not pad the result");
    StubScreener *stub=[StubScreener new]; stub.running=YES; stub.cutoff=cutoff; stub.btcReturns=returns; stub.matches=[NSMutableArray new];
    NSMutableArray *candidates=[NSMutableArray new]; for(NSUInteger i=0;i<20;i++) [candidates addObject:@{@"pair":@"SOLUSDT",@"market_cap_rank":@(i+1)}]; stub.candidates=candidates;
    [stub pump:stub.generation]; Require(stub.requests==4,@"initial batch bounded at four concurrent candidates");
    Require(Until(^BOOL{return !stub.running;},3) && stub.completed==20 && stub.maximumActive==4 && stub.results.count==10,@"bounded scan completes with sorted results");
    stub.running=YES; stub.nextIndex=0; stub.completed=0; stub.active=0; stub.matches=[NSMutableArray new];
    [stub pump:stub.generation]; [stub cancel:nil]; NSUInteger completed=stub.completed;
    Until(^BOOL{return NO;},.1); Require(stub.completed==completed && !stub.running,@"late scan callbacks ignored after cancellation");
    BTCScreener *network=[BTCScreener new]; network.running=YES;
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration; configuration.protocolClasses=@[ScanProtocol.class];
    network.session=[NSURLSession sessionWithConfiguration:configuration];
    __block BOOL called=NO;
    [network fetchJSON:@"https://scan.test/limited" token:network.generation completion:^(id data,NSString *error) { called=YES; }];
    Require(Until(^BOOL{return !network.running;},2) && network.cooldownUntil>Now()+58 && !called,@"429 aborts all work and respects server cooldown");
    [network start:nil]; Require(!network.running,@"rescan cannot bypass cooldown");
    network.cooldownUntil=0; network.running=YES; network.session=[NSURLSession sessionWithConfiguration:configuration];
    [network fetchJSON:@"https://scan.test/ok" token:network.generation completion:^(id data,NSString *error) { called=YES; }];
    [network stop]; Until(^BOOL{return NO;},.15); Require(!called,@"actual URL session callbacks cannot update a cancelled scan");
    StubScreener *switching=[StubScreener new]; [switching show]; switching.running=YES; switching.cutoff=cutoff; switching.btcReturns=returns;
    switching.candidates=candidates; switching.matches=[NSMutableArray new]; [switching pump:switching.generation];
    switching.cooldownUntil=Now()+60; // Avoid live I/O while checking the in-flight period switch.
    switching.periodControl.selectedSegment=1; NSInteger oldGeneration=switching.generation; [switching selectPeriod:nil];
    Until(^BOOL{return NO;},.1);
    Require([switching.interval isEqual:@"1h"] && switching.generation>oldGeneration && switching.results.count==0 && switching.matches.count==0 && switching.completed==0,@"switching period invalidates pending work and cannot relabel old results, even during cooldown");
    switching.panel.delegate=nil; [switching.panel close];
    NSLog(@"PASS: ranking freshness, exclusions, exact time alignment, return correlation, threshold, bounded concurrency and cancellation");
    if(argc>1 && strcmp(argv[1],"--live")==0) {
        Controller *root=[Controller new]; root.singleWindows=[NSMutableArray new];
        [root showScreening:nil]; BTCScreener *live=root.screener;
        NSInteger generation=live.generation; Controller *child=[Controller new]; child.rootController=root; [child showScreening:nil];
        Require(root.screener==live && live.generation==generation,@"all window menu entries share one scan without starting duplicate work");
        Require(Until(^BOOL{return !live.running;},185),@"live scan terminates");
        NSLog(@"LIVE: %@ | %@",live.statusLabel.stringValue,live.detailLabel.stringValue);
        Require(live.candidates.count>0 && live.completed==live.candidates.count && live.matches.count>0,@"real top-200 eligible universe scanned");
        Require(live.results.count<=10 && live.progress.hidden,@"at most ten high-correlation matches; no busy indicator after completion");
        for(NSDictionary *coin in live.results) NSLog(@"RESULT %@ rank=%@ r=%.6f",coin[@"pair"],coin[@"market_cap_rank"],[coin[@"correlation"] doubleValue]);
        [live.panel.contentView displayIfNeeded]; NSBitmapImageRep *bitmap=[live.panel.contentView bitmapImageRepForCachingDisplayInRect:live.panel.contentView.bounds];
        [live.panel.contentView cacheDisplayInRect:live.panel.contentView.bounds toBitmapImageRep:bitmap];
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@".build/screener-live.png" atomically:YES];
        NSUInteger strictCount=live.results.count;
        live.strictButton.state=NSControlStateValueOff; [live displayResults:nil];
        Require(live.results.count==MIN(10,live.matches.count),@"optional closest-ten view shows honest weaker matches without changing strict threshold");
        NSLog(@"CLOSEST TEN (%lu strict matches):",(unsigned long)strictCount);
        for(NSDictionary *coin in live.results) NSLog(@"RESULT %@ rank=%@ r=%.6f",coin[@"pair"],coin[@"market_cap_rank"],[coin[@"correlation"] doubleValue]);
        [live.panel.contentView displayIfNeeded];
        [live.panel.contentView cacheDisplayInRect:live.panel.contentView.bounds toBitmapImageRep:bitmap];
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@".build/screener-closest.png" atomically:YES];
        double hold=[NSProcessInfo.processInfo.environment[@"PULSE_SCREEN_HOLD"] doubleValue];
        if(hold>0) { NSLog(@"SCREEN WINDOW %ld",(long)live.panel.windowNumber); Until(^BOOL{return NO;},MIN(hold,60)); }
        if(live.results.count) {
            NSButton *button=[NSButton new]; button.tag=0; [live openCoin:button];
            Require(root.singleWindows.count==1 && [root.singleWindows[0].symbols.firstObject isEqual:live.results[0][@"pair"]] && [root.singleWindows[0].charts.firstObject.interval isEqual:live.interval],@"result opens the selected single-coin window and matching period");
            [root.singleWindows.firstObject closeWindow:nil];
        }
        live.periodControl.selectedSegment=1; [live selectPeriod:nil];
        Require(Until(^BOOL{return !live.running;},185),@"hourly live scan terminates");
        Require(live.cachedMarkets.count==200 && live.btcReturns.count==24 && live.completed==live.candidates.count && live.matches.count>0,@"top-200 hourly scan uses 24 aligned closed returns");
        Require([live.statusLabel.stringValue containsString:@"1小时"] && [live.statusLabel.stringValue containsString:@"24个"],@"hourly results visibly identify their interval and sample count");
        NSLog(@"HOURLY: %@ | %@",live.statusLabel.stringValue,live.detailLabel.stringValue);
        for(NSDictionary *coin in live.results) Require([coin[@"interval"] isEqual:@"1h"],@"hourly results cannot contain old 15m records");
        [live.panel makeKeyAndOrderFront:nil];
        if(live.results.count) {
            NSButton *button=[NSButton new]; button.tag=0; [live openCoin:button];
            Require([root.singleWindows.firstObject.charts.firstObject.interval isEqual:@"1h"],@"hourly result opens hourly chart");
            [root.singleWindows.firstObject closeWindow:nil];
        }
        [live.panel makeKeyAndOrderFront:nil];
        [live.panel.contentView displayIfNeeded]; [live.panel.contentView cacheDisplayInRect:live.panel.contentView.bounds toBitmapImageRep:bitmap];
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@".build/screener-hourly.png" atomically:YES];
        if(hold>0) { NSLog(@"HOURLY SCREEN WINDOW %ld",(long)live.panel.windowNumber); Until(^BOOL{return NO;},MIN(hold,60)); }
        [live stop]; live.panel.delegate=nil; [live.panel close];
        NSLog(@"PASS: live market-cap universe, closed bars, ranking UI and opening results");
    }
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain]; return 0;
} }
