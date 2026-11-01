// BTC co-movement: a fresh global top-200 universe and an identical closed-bar window.
static NSString *MarketURL(NSString *category) {
    NSString *base=@"https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&order=market_cap_desc&per_page=200&page=1&sparkline=false";
    return category?[base stringByAppendingFormat:@"&category=%@",category]:base;
}
static NSArray *ScreenMarkets(id json, double now) {
    if(![json isKindOfClass:NSArray.class] || [json count]!=200) return nil;
    NSMutableSet *ranks=[NSMutableSet new],*ids=[NSMutableSet new];
    NSMutableArray *validated=[NSMutableArray new]; NSUInteger fresh=0; BOOL leaderFresh=NO;
    NSISO8601DateFormatter *dates=[NSISO8601DateFormatter new]; dates.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds;
    for(id coin in json) {
        if(![coin isKindOfClass:NSDictionary.class]) return nil;
        for(NSString *key in @[@"id",@"symbol",@"name",@"last_updated"]) if(![coin[key] isKindOfClass:NSString.class] || ![coin[key] length]) return nil;
        if(![coin[@"market_cap_rank"] isKindOfClass:NSNumber.class] || ![coin[@"market_cap"] isKindOfClass:NSNumber.class]) return nil;
        double rank=[coin[@"market_cap_rank"] doubleValue],cap=[coin[@"market_cap"] doubleValue];
        NSDate *date=[dates dateFromString:coin[@"last_updated"]];
        if(!date || date.timeIntervalSince1970>now+60 || !isfinite(cap) || cap<=0 || rank<1 || rank>200 || floor(rank)!=rank) return nil;
        [ranks addObject:coin[@"market_cap_rank"]]; [ids addObject:coin[@"id"]];
        BOOL stale=now-date.timeIntervalSince1970>3600;
        if(!stale) { fresh++; if(rank==1) leaderFresh=YES; }
        NSMutableDictionary *record=[coin mutableCopy]; record[@"staleMarket"]=@(stale); [validated addObject:record];
    }
    return ranks.count==200 && ids.count==200 && leaderFresh && fresh>=180?validated:nil;
}
static NSSet *CategoryIDs(id json) {
    if(![json isKindOfClass:NSArray.class] || ![json count]) return nil;
    NSMutableSet *ids=[NSMutableSet new];
    for(id coin in json) { if(![coin isKindOfClass:NSDictionary.class] || ![coin[@"id"] isKindOfClass:NSString.class]) return nil; [ids addObject:coin[@"id"]]; }
    return ids;
}
static NSArray *ScreenCandidates(NSArray *markets, NSSet *excluded, id exchange, NSUInteger *removed, NSUInteger *unsupported) {
    if(![exchange isKindOfClass:NSDictionary.class] || ![exchange[@"symbols"] isKindOfClass:NSArray.class]) return nil;
    NSMutableDictionary *spot=[NSMutableDictionary new], *counts=[NSMutableDictionary new];
    for(NSDictionary *coin in markets) { NSString *code=[coin[@"symbol"] uppercaseString]; counts[code]=@([counts[code] unsignedIntegerValue]+1); }
    for(id item in exchange[@"symbols"]) {
        if(![item isKindOfClass:NSDictionary.class] || ![item[@"symbol"] isKindOfClass:NSString.class] || ![item[@"baseAsset"] isKindOfClass:NSString.class]) continue;
        NSString *symbol=item[@"symbol"];
        if(![symbol isEqual:[item[@"baseAsset"] stringByAppendingString:@"USDT"]]) continue;
        NSNumber *digits=MarketDigits(@{@"symbols":@[item]},symbol); if(digits) spot[item[@"baseAsset"]]=digits;
    }
    NSMutableArray *out=[NSMutableArray new]; *removed=0; *unsupported=0;
    for(NSDictionary *coin in markets) {
        NSString *code=[coin[@"symbol"] uppercaseString];
        if([coin[@"id"] isEqual:@"bitcoin"] || [code isEqual:@"BTC"] || [excluded containsObject:coin[@"id"]]) { (*removed)++; continue; }
        // Ambiguous tickers are skipped rather than assigning a different asset's price series.
        if([coin[@"staleMarket"] boolValue] || !spot[code] || [counts[code] unsignedIntegerValue]!=1) { (*unsupported)++; continue; }
        NSMutableDictionary *candidate=[coin mutableCopy]; candidate[@"pair"]=[code stringByAppendingString:@"USDT"]; candidate[@"digits"]=spot[code]; [out addObject:candidate];
    }
    return out;
}
static NSUInteger ScreenSeconds(NSString *interval) { return [@{@"15m":@900,@"1h":@3600}[interval] unsignedIntegerValue]; }
static NSUInteger ScreenSamples(NSString *interval) { NSUInteger seconds=ScreenSeconds(interval); return seconds?86400/seconds:0; }
static NSArray *AlignedReturns(id json, double cutoff, NSString *interval) {
    NSUInteger seconds=ScreenSeconds(interval), count=ScreenSamples(interval)+1;
    NSArray *rows=ParseCandles(json); if(!seconds || rows.count!=count) return nil;
    NSMutableArray *returns=[NSMutableArray new]; double previous=0;
    for(NSUInteger i=0;i<rows.count;i++) {
        NSArray *row=rows[i]; double open=[row[0] doubleValue]/1000,close=[row[6] doubleValue]/1000,price=[row[4] doubleValue];
        if(fabs(open-(cutoff-(count-i)*seconds))>.001 || fabs(close-(open+seconds-.001))>.01 || close>=cutoff) return nil;
        if(i) { double value=price/previous-1; if(!isfinite(value)) return nil; [returns addObject:@(value)]; }
        previous=price;
    }
    return returns;
}
static double ReturnCorrelation(NSArray *a, NSArray *b) {
    if((a.count!=96 && a.count!=24) || b.count!=a.count) return NAN;
    double ma=0,mb=0;
    for(NSUInteger i=0;i<a.count;i++) { double x=[a[i] doubleValue],y=[b[i] doubleValue]; if(!isfinite(x)||!isfinite(y)) return NAN; ma+=x/a.count; mb+=y/a.count; }
    double xx=0,yy=0,xy=0;
    for(NSUInteger i=0;i<a.count;i++) { double x=[a[i] doubleValue]-ma,y=[b[i] doubleValue]-mb; xx+=x*x; yy+=y*y; xy+=x*y; }
    if(xx<=1e-24 || yy<=1e-24) return NAN;
    double r=xy/sqrt(xx*yy); return isfinite(r)?MAX(-1,MIN(1,r)):NAN;
}
static NSArray *RankedMatches(NSArray *matches,BOOL strict) {
    NSPredicate *high=[NSPredicate predicateWithBlock:^BOOL(NSDictionary *coin,NSDictionary *bindings) { double r=[coin[@"correlation"] doubleValue]; return isfinite(r) && (!strict || r>=.8); }];
    NSArray *sorted=[[matches filteredArrayUsingPredicate:high] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        NSComparisonResult order=[b[@"correlation"] compare:a[@"correlation"]]; return order==NSOrderedSame?[a[@"market_cap_rank"] compare:b[@"market_cap_rank"]]:order;
    }]; return [sorted subarrayWithRange:NSMakeRange(0,MIN(10,sorted.count))];
}
static NSArray *TopMatches(NSArray *matches) { return RankedMatches(matches,YES); }
static NSString *ScreenKlines(NSString *symbol,double cutoff,NSString *interval) {
    NSUInteger seconds=ScreenSeconds(interval),count=ScreenSamples(interval)+1;
    return [NSString stringWithFormat:@"/api/v3/klines?symbol=%@&interval=%@&limit=%lu&startTime=%.0f&endTime=%.0f",symbol,interval,(unsigned long)count,(cutoff-count*seconds)*1000,cutoff*1000-1];
}
@implementation BTCScreener
-(instancetype)init { if((self=[super init])) _interval=@"15m"; return self; }
-(void)show {
    if(!self.panel) {
        self.panel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,640,640) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.panel.title=@"BTC 同步榜"; self.panel.delegate=self; self.panel.releasedWhenClosed=NO;
        self.panel.level=NSFloatingWindowLevel+1; self.panel.hidesOnDeactivate=NO;
        self.panel.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        NSView *view=self.panel.contentView;
        NSTextField *heading=PickerLabel(@"寻找与 BTC 涨跌同步的币",NSMakeRect(24,580,590,30),22); [view addSubview:heading];
        [view addSubview:PickerLabel(@"市值前 200 · 最近 24 小时",NSMakeRect(24,550,300,24),13)];
        self.periodControl=[NSSegmentedControl segmentedControlWithLabels:@[@"15分钟",@"1小时"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(selectPeriod:)];
        self.periodControl.frame=NSMakeRect(366,548,250,28); self.periodControl.selectedSegment=[self.interval isEqual:@"1h"]?1:0;
        self.periodControl.toolTip=@"切换K线周期后重新比较最近24小时"; [view addSubview:self.periodControl];
        [view addSubview:PickerLabel(@"相关性越接近 1，涨跌越同步。默认仅显示高度同步，最多 10 个。",NSMakeRect(24,526,590,22),12)];
        self.strictButton=[NSButton checkboxWithTitle:@"仅显示高度同步（≥ 0.80）；取消勾选可看最接近的 10 个" target:self action:@selector(displayResults:)];
        self.strictButton.state=NSControlStateValueOn; self.strictButton.frame=NSMakeRect(24,503,592,20); [view addSubview:self.strictButton];
        self.searchButton=[NSButton buttonWithTitle:@"开始搜索" target:self action:@selector(start:)]; self.searchButton.frame=NSMakeRect(24,476,112,32); [view addSubview:self.searchButton];
        self.cancelButton=[NSButton buttonWithTitle:@"取消" target:self action:@selector(cancel:)]; self.cancelButton.frame=NSMakeRect(142,476,72,32); self.cancelButton.enabled=NO; [view addSubview:self.cancelButton];
        self.progress=[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(232,488,380,12)]; self.progress.style=NSProgressIndicatorStyleBar; self.progress.indeterminate=YES; self.progress.minValue=0; self.progress.maxValue=100; [view addSubview:self.progress];
        self.statusLabel=PickerLabel(@"点击搜索获取当前榜单。",NSMakeRect(24,430,592,40),12); [view addSubview:self.statusLabel];
        NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(24,82,592,340)]; scroll.hasVerticalScroller=YES; scroll.borderType=NSBezelBorder;
        self.table=[[NSTableView alloc] initWithFrame:scroll.bounds]; self.table.rowHeight=30; self.table.intercellSpacing=NSMakeSize(3,1); self.table.columnAutoresizingStyle=NSTableViewNoColumnAutoresizing; self.table.dataSource=self; self.table.delegate=self; self.table.usesAlternatingRowBackgroundColors=YES;
        for(NSArray *col in @[@[@"rank",@"市值排名",@70],@[@"coin",@"币种",@278],@[@"score",@"相关性",@110],@[@"open",@"行情",@88]]) {
            NSTableColumn *column=[[NSTableColumn alloc] initWithIdentifier:col[0]]; column.title=col[1]; column.width=[col[2] doubleValue]; column.resizingMask=NSTableColumnNoResizing; [self.table addTableColumn:column];
        }
        scroll.documentView=self.table; [view addSubview:scroll];
        self.detailLabel=PickerLabel(@"排除 BTC、稳定币、BTC 锚定币；只比较币安可交易的 USDT 现货。\n市值及分类：CoinGecko · K 线：Binance",NSMakeRect(24,10,592,64),11); self.detailLabel.textColor=NSColor.secondaryLabelColor; self.detailLabel.toolTip=@"不可用/过期包括：没有币安USDT现货、简称重复，或市值记录超过1小时未更新。"; [view addSubview:self.detailLabel];
        [self.panel center];
    }
    [NSApp activateIgnoringOtherApps:YES]; [self.panel makeKeyAndOrderFront:nil];
}
-(NSInteger)numberOfRowsInTableView:(NSTableView *)table { return self.results.count; }
-(NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSDictionary *coin=self.results[row]; NSString *key=column.identifier;
    NSView *cell=[[NSView alloc] initWithFrame:NSMakeRect(0,0,column.width,30)];
    if([key isEqual:@"open"]) { NSButton *b=[NSButton buttonWithTitle:@"打开" target:self action:@selector(openCoin:)]; b.tag=row; b.frame=NSMakeRect(4,4,MIN(72,column.width-8),22); b.font=[NSFont systemFontOfSize:11]; [cell addSubview:b]; return cell; }
    NSString *value=[key isEqual:@"rank"]?[NSString stringWithFormat:@"#%@",coin[@"market_cap_rank"]]:([key isEqual:@"score"]?[NSString stringWithFormat:@"%.4f%@",[coin[@"correlation"] doubleValue],[coin[@"correlation"] doubleValue]<.8?@" · 未达标":@""]:[NSString stringWithFormat:@"%@  ·  %@",[coin[@"symbol"] uppercaseString],coin[@"name"]]);
    NSTextField *label=[NSTextField labelWithString:value]; label.frame=NSMakeRect(6,6,column.width-12,18); label.font=[NSFont systemFontOfSize:12 weight:[key isEqual:@"score"]?NSFontWeightSemibold:NSFontWeightRegular]; label.lineBreakMode=NSLineBreakByTruncatingTail; label.toolTip=value;
    if([key isEqual:@"score"]) label.textColor=[coin[@"correlation"] doubleValue]>=.8?Up():NSColor.secondaryLabelColor;
    [cell addSubview:label]; return cell;
}
-(void)openCoin:(NSButton *)sender {
    if(sender.tag<0 || sender.tag>=self.results.count) return;
    NSDictionary *coin=self.results[sender.tag]; [self.owner createSingleWindow:coin[@"pair"] digits:[coin[@"digits"] integerValue] record:@{@"interval":coin[@"interval"]?:self.interval}]; [self.panel orderOut:nil];
}
-(BOOL)windowShouldClose:(NSWindow *)window { [self cancel:nil]; [self.panel orderOut:nil]; return NO; }
-(void)stop { [self.deadlineTimer invalidate]; self.deadlineTimer=nil; self.generation++; self.running=NO; [self.session invalidateAndCancel]; self.session=nil; [self.progress stopAnimation:nil]; self.progress.hidden=YES; self.cancelButton.enabled=NO; self.searchButton.enabled=YES; self.strictButton.enabled=YES; }
-(void)cancel:(id)sender { BOOL wasRunning=self.running; [self stop]; if(wasRunning) self.statusLabel.stringValue=@"已取消，本次未完成的结果不作为榜单。点击重新搜索。"; }
-(void)fail:(NSString *)message { [self stop]; self.statusLabel.stringValue=message; self.searchButton.title=@"重新搜索"; }
-(void)fetchJSON:(NSString *)url token:(NSInteger)token completion:(void (^)(id,NSString *))completion {
    NSURLRequest *request=[NSURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if(token!=self.generation || !self.running) return;
            NSInteger status=[(NSHTTPURLResponse *)response statusCode];
            if(status==429 || status==418) { self.cooldownUntil=Now()+MAX(30,[[(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Retry-After"] doubleValue]); [self fail:@"数据源暂时限流，请稍后再搜索；当前行情窗口继续运行。"]; return; }
            id json=!error && status==200 && data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
            completion(json,json?nil:@"数据源暂时不可用，请稍后重新搜索。");
        });
    }] resume];
}
-(void)fetchBinance:(NSString *)path endpoint:(NSUInteger)endpoint token:(NSInteger)token completion:(void (^)(id,NSString *))completion {
    [self fetchJSON:[APIHosts()[endpoint] stringByAppendingString:path] token:token completion:^(id json,NSString *error) {
        if(error && endpoint+1<APIHosts().count) [self fetchBinance:path endpoint:endpoint+1 token:token completion:completion]; else completion(json,error);
    }];
}
-(void)selectPeriod:(id)sender {
    NSString *next=self.periodControl.selectedSegment==1?@"1h":@"15m";
    if([next isEqual:self.interval]) return;
    [self stop]; self.interval=next;
    self.results=@[]; self.matches=[NSMutableArray new]; self.candidates=@[]; self.completed=0;
    self.detailLabel.stringValue=@"排除 BTC、稳定币、BTC 锚定币；只比较币安可交易的 USDT 现货。\n市值及分类：CoinGecko · K 线：Binance";
    [self.table reloadData]; [self start:nil];
}
-(void)start:(id)sender {
    if(self.running) return;
    if(Now()<self.cooldownUntil) { self.statusLabel.stringValue=[NSString stringWithFormat:@"数据源限流，还需等待 %.0f 秒。",ceil(self.cooldownUntil-Now())]; return; }
    [self stop]; self.running=YES; NSInteger token=self.generation;
    // Freeze a shared time grid for the whole scan, excluding the currently forming candle.
    NSUInteger seconds=ScreenSeconds(self.interval); self.cutoff=floor(Now()/seconds)*seconds;
    self.results=@[]; self.matches=[NSMutableArray new]; self.candidates=@[]; self.btcReturns=nil;
    self.nextIndex=0; self.active=0; self.completed=0; self.failed=0;
    [self.table reloadData]; self.strictButton.enabled=NO; self.searchButton.enabled=NO; self.searchButton.title=@"重新搜索"; self.cancelButton.enabled=YES;
    self.progress.hidden=NO; self.progress.indeterminate=YES; [self.progress startAnimation:nil]; self.statusLabel.stringValue=@"正在获取市值前 200 和币种分类…";
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration; config.timeoutIntervalForRequest=10; config.timeoutIntervalForResource=15; config.HTTPMaximumConnectionsPerHost=4; config.waitsForConnectivity=NO;
    self.session=[NSURLSession sessionWithConfiguration:config];
    self.detailLabel.stringValue=@"排除 BTC、稳定币、BTC 锚定币；只比较币安可交易的 USDT 现货。\n市值及分类：CoinGecko · K 线：Binance";
    __weak BTCScreener *weakSelf=self;
    self.deadlineTimer=[NSTimer timerWithTimeInterval:180 repeats:NO block:^(NSTimer *timer) { [weakSelf fail:@"搜索超过3分钟，已停止。请检查网络后重新搜索。"]; }];
    [NSRunLoop.mainRunLoop addTimer:self.deadlineTimer forMode:NSRunLoopCommonModes];
    [self loadUniverse:token];
}
-(void)loadUniverse:(NSInteger)token {
    if(Now()-self.cacheTime<300 && self.cachedMarkets.count==200 && self.cachedExcluded) { [self loadExchange:token]; return; }
    [self fetchJSON:MarketURL(nil) token:token completion:^(id json,NSString *error) {
        NSArray *markets=ScreenMarkets(json,Now()); if(!markets) { [self fail:error?:@"市值榜不完整或已过期，本次未生成结果。请稍后重试。"]; return; }
        [self fetchJSON:MarketURL(@"stablecoins") token:token completion:^(id stable,NSString *stableError) {
            NSSet *stableIDs=CategoryIDs(stable); if(!stableIDs) { [self fail:stableError?:@"无法验证稳定币分类，请稍后重试。"]; return; }
            [self fetchJSON:MarketURL(@"tokenized-btc") token:token completion:^(id wrapped,NSString *wrappedError) {
                NSSet *btcIDs=CategoryIDs(wrapped); if(!btcIDs) { [self fail:wrappedError?:@"无法验证 BTC 锚定币分类，请稍后重试。"]; return; }
                NSMutableSet *excluded=[stableIDs mutableCopy]; [excluded unionSet:btcIDs];
                self.cachedMarkets=markets; self.cachedExcluded=excluded; self.cacheTime=Now(); [self loadExchange:token];
            }];
        }];
    }];
}
-(void)loadExchange:(NSInteger)token {
    self.statusLabel.stringValue=@"正在核对币安 USDT 现货币种…";
    [self fetchBinance:@"/api/v3/exchangeInfo?permissions=SPOT" endpoint:0 token:token completion:^(id json,NSString *error) {
        NSUInteger removed=0,unsupported=0;
        self.candidates=ScreenCandidates(self.cachedMarkets,self.cachedExcluded,json,&removed,&unsupported); self.excludedCount=removed; self.unsupportedCount=unsupported;
        if(error || !self.candidates.count) { [self fail:error?:@"未找到可比较的 USDT 现货币种。"]; return; }
        self.statusLabel.stringValue=@"正在获取 BTC 的已收盘 K 线…";
        [self fetchBinance:ScreenKlines(@"BTCUSDT",self.cutoff,self.interval) endpoint:0 token:token completion:^(id data,NSString *err) {
            self.btcReturns=AlignedReturns(data,self.cutoff,self.interval);
            if(err || !self.btcReturns || !isfinite(ReturnCorrelation(self.btcReturns,self.btcReturns))) { [self fail:@"BTC 数据缺失、未对齐或无有效波动，无法计算。请重新搜索。"]; return; }
            self.progress.indeterminate=NO; self.progress.doubleValue=0; [self pump:token];
        }];
    }];
}
-(void)pump:(NSInteger)token {
    if(!self.running || token!=self.generation) return;
    while(self.active<4 && self.nextIndex<self.candidates.count) {
        NSDictionary *coin=self.candidates[self.nextIndex++]; self.active++;
        [self fetchBinance:ScreenKlines(coin[@"pair"],self.cutoff,self.interval) endpoint:0 token:token completion:^(id json,NSString *error) {
            self.active--; self.completed++;
            NSArray *returns=error?nil:AlignedReturns(json,self.cutoff,self.interval);
            double r=returns?ReturnCorrelation(self.btcReturns,returns):NAN;
            if(isfinite(r)) { NSMutableDictionary *match=[coin mutableCopy]; match[@"correlation"]=@(r); match[@"interval"]=self.interval; [self.matches addObject:match]; } else self.failed++;
            self.progress.doubleValue=100.0*self.completed/self.candidates.count;
            self.statusLabel.stringValue=[NSString stringWithFormat:@"正在比较 %lu / %lu 个币种…",(unsigned long)self.completed,(unsigned long)self.candidates.count];
            [self pump:token];
        }];
    }
    if(self.completed==self.candidates.count && !self.active) [self finish];
}
-(void)finish {
    [self stop]; self.progress.indeterminate=NO; self.progress.doubleValue=100;
    [self displayResults:nil];
}
-(void)displayResults:(id)sender {
    if(self.running || !self.completed || self.completed!=self.candidates.count) return;
    BOOL strict=!self.strictButton || self.strictButton.state==NSControlStateValueOn;
    self.results=RankedMatches(self.matches,strict); [self.table reloadData];
    NSDateFormatter *dates=[NSDateFormatter new]; dates.timeZone=[NSTimeZone timeZoneWithName:@"Asia/Shanghai"]; dates.dateFormat=@"MM/dd HH:mm";
    NSString *from=[dates stringFromDate:[NSDate dateWithTimeIntervalSince1970:self.cutoff-86400]],*to=[dates stringFromDate:[NSDate dateWithTimeIntervalSince1970:self.cutoff]];
    NSString *summary=strict?(self.results.count?[NSString stringWithFormat:@"找到 %lu 个高度同步币种%@",(unsigned long)self.results.count,self.results.count<10?@"，不足10个不凑数":@""]:@"没有达到0.80的币；取消勾选可查看最接近的10个。"):[NSString stringWithFormat:@"最接近 BTC 的 %lu 个币（含未达到0.80标准的结果）",(unsigned long)self.results.count];
    self.statusLabel.stringValue=[NSString stringWithFormat:@"%@%@\n%@ — %@（北京 · %@ · %lu个已收盘涨跌幅）",self.failed?@"部分完成：":@"",summary,from,to,[self.interval isEqual:@"1h"]?@"1小时":@"15分钟",(unsigned long)ScreenSamples(self.interval)];
    self.detailLabel.stringValue=[NSString stringWithFormat:@"市值前200：排除 %lu · 不可用/过期 %lu · 成功比较 %lu · 数据不足/失败 %lu\n市值及分类：CoinGecko（缓存最多5分钟）· K线：Binance\n相关性描述过去24小时的同步程度，不代表后续涨跌。",(unsigned long)self.excludedCount,(unsigned long)self.unsupportedCount,(unsigned long)self.matches.count,(unsigned long)self.failed];
}
@end
@implementation Controller (Screening)
-(void)showScreening:(id)sender {
    Controller *root=self.rootController?:self;
    BOOL fresh=!root.screener;
    if(fresh) { root.screener=[BTCScreener new]; root.screener.owner=root; }
    [root.screener show]; if(fresh) [root.screener start:nil];
}
@end
