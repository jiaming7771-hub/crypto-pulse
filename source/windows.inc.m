// Included by main.m: multi-window ownership, persistence and the coin picker.
static NSString *NormalizeSymbol(NSString *input) {
    if(![input isKindOfClass:NSString.class]) return nil;
    NSString *s=[[input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    s=[s stringByReplacingOccurrencesOfString:@"/" withString:@""];
    if(!s.length || s.length>30 || [s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"] invertedSet]].location!=NSNotFound) return nil;
    if(![s hasSuffix:@"USDT"]) s=[s stringByAppendingString:@"USDT"];
    return s.length>4?s:nil;
}
static NSNumber *MarketDigits(id json, NSString *symbol) {
    if(![json isKindOfClass:NSDictionary.class] || ![json[@"symbols"] isKindOfClass:NSArray.class]) return nil;
    for(id item in json[@"symbols"]) {
        if(![item isKindOfClass:NSDictionary.class] || ![item[@"symbol"] isEqual:symbol] || ![item[@"quoteAsset"] isEqual:@"USDT"] || ![item[@"status"] isEqual:@"TRADING"] || ![item[@"isSpotTradingAllowed"] isKindOfClass:NSNumber.class] || ![item[@"isSpotTradingAllowed"] boolValue]) continue;
        if([Symbols() containsObject:symbol]) return @(PriceDigits(symbol));
        if(![item[@"filters"] isKindOfClass:NSArray.class]) continue;
        for(id filter in item[@"filters"]) {
            if(![filter isKindOfClass:NSDictionary.class] || ![filter[@"filterType"] isEqual:@"PRICE_FILTER"] || ![filter[@"tickSize"] isKindOfClass:NSString.class]) continue;
            NSString *tick=filter[@"tickSize"];
            if(tick.doubleValue<=0 || !isfinite(tick.doubleValue)) continue;
            NSArray *parts=[tick componentsSeparatedByString:@"."];
            NSString *fraction=parts.count==2?parts[1]:@"";
            while([fraction hasSuffix:@"0"]) fraction=[fraction substringToIndex:fraction.length-1];
            return @(MIN(12,fraction.length));
        }
    }
    return nil;
}
static NSTextField *PickerLabel(NSString *text, NSRect frame, CGFloat size) {
    NSTextField *label=[NSTextField wrappingLabelWithString:text]; label.frame=frame;
    label.font=[NSFont systemFontOfSize:size]; return label;
}
@implementation Controller (Windows)
-(Controller *)newWindowController { return [Controller new]; }
-(void)setupWindowCommands {
    self.status=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.status.button.image=[NSImage imageWithSystemSymbolName:@"chart.line.uptrend.xyaxis" accessibilityDescription:@"Crypto Pulse 行情"];
    NSMenu *(^makeMenu)(void)=^NSMenu *{
        NSMenu *menu=[NSMenu new];
        for(NSArray *entry in @[@[@"新建单币窗口…",@"newCoinWindow:",@"n"],@[@"显示主窗口",@"show:",@""],@[@"显示所有行情窗口",@"showAll:",@""],@[@"重新连接所有行情",@"reconnectAll:",@""],@[@"主窗口移到右上角",@"reset:",@""],@[@"退出 Crypto Pulse",@"quit:",@"q"]]) {
            NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:entry[2]]; item.target=self; [menu addItem:item];
        }
        return menu;
    };
    self.status.menu=makeMenu();
    NSMenu *main=[NSMenu new]; NSMenuItem *app=[NSMenuItem new]; [main addItem:app]; app.submenu=makeMenu(); NSApp.mainMenu=main;
    NSMenuItem *edit=[[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""]; [main addItem:edit]; edit.submenu=[[NSMenu alloc] initWithTitle:@"编辑"];
    for(NSArray *entry in @[@[@"剪切",@"cut:",@"x"],@[@"复制",@"copy:",@"c"],@[@"粘贴",@"paste:",@"v"],@[@"全选",@"selectAll:",@"a"]]) [edit.submenu addItem:[[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:entry[2]]];
}
-(NSMenu *)applicationDockMenu:(NSApplication *)app {
    NSMenu *menu=[NSMenu new];
    for(NSArray *entry in @[@[@"新建单币窗口…",@"newCoinWindow:"],@[@"显示主窗口",@"show:"],@[@"显示所有行情窗口",@"showAll:"]]) {
        NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""]; item.target=self; [menu addItem:item];
    }
    return menu;
}
-(void)showAll:(id)sender {
    Controller *root=self.rootController?:self; [root show:nil];
    for(Controller *child in root.singleWindows) [child show:nil];
}
-(void)reconnectAll:(id)sender {
    Controller *root=self.rootController?:self; [root reconnect:nil];
    for(Controller *child in root.singleWindows) [child reconnect:nil];
}
-(void)stop {
    self.closed=YES; self.generation++; self.pollGeneration++;
    [self.timer invalidate]; self.timer=nil;
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [self.socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil]; self.socket=nil;
    [self.pollTask cancel]; self.pollTask=nil; self.polling=NO;
    for(ChartState *chart in self.charts) { chart.chartGeneration++; [chart.chartTask cancel]; chart.chartTask=nil; }
    [self.session invalidateAndCancel]; self.session=nil;
    [self.streamSession invalidateAndCancel]; self.streamSession=nil;
}
-(void)closeWindow:(id)sender {
    if(!self.windowID) { [self.panel orderOut:nil]; return; }
    Controller *root=self.rootController;
    [self stop]; self.panel.delegate=nil; [self.panel close];
    [root.singleWindows removeObjectIdenticalTo:self]; [root saveSingleWindows];
}
-(BOOL)windowShouldClose:(NSWindow *)window {
    if(window==self.picker) [self cancelPicker:nil]; else [self closeWindow:nil];
    return NO;
}
-(Controller *)createSingleWindow:(NSString *)symbol digits:(NSInteger)digits record:(NSDictionary *)record {
    Controller *root=self.rootController?:self;
    Controller *child=[root newWindowController]; child.rootController=root;
    child.windowID=NSUUID.UUID.UUIDString;
    child.selectedSymbols=@[symbol]; child.symbolDigits=@{symbol:@(MAX(0,MIN(12,digits)))};
    ChartState *chart=[ChartState new]; chart.symbol=symbol; chart.expanded=YES;
    if([@[@"15m",@"1h",@"4h",@"1d"] containsObject:record[@"interval"]]) chart.interval=record[@"interval"];
    if([record[@"expanded"] isKindOfClass:NSNumber.class]) chart.expanded=[record[@"expanded"] boolValue];
    child.charts=@[chart];
    if(!root.singleWindows) root.singleWindows=[NSMutableArray new];
    [root.singleWindows addObject:child]; [child startWindow];
    if(child.panel) {
        NSRect screen=(root.panel.screen?:NSScreen.mainScreen).visibleFrame;
        double scale=[record[@"scale"] isKindOfClass:NSNumber.class]?[record[@"scale"] doubleValue]:1;
        if(!isfinite(scale) || scale<=0) scale=1;
        [child layoutPanel:scale];
        NSRect frame=child.panel.frame;
        BOOL restored=NO;
        if([record[@"frame"] isKindOfClass:NSString.class]) {
            NSRect old=NSRectFromString(record[@"frame"]);
            if(isfinite(old.origin.x) && isfinite(old.origin.y)) {
                for(NSScreen *s in NSScreen.screens) if(NSIntersectsRect(old,s.visibleFrame)) { frame.origin=old.origin; screen=s.visibleFrame; restored=YES; break; }
            }
        }
        if(!restored) {
            NSUInteger slot=root.singleWindows.count;
            frame.origin=NSMakePoint(NSMaxX(root.panel.frame)-frame.size.width-28*slot,NSMaxY(root.panel.frame)-frame.size.height-28*slot);
        }
        frame.origin.x=MAX(NSMinX(screen),MIN(frame.origin.x,NSMaxX(screen)-frame.size.width));
        frame.origin.y=MAX(NSMinY(screen),MIN(frame.origin.y,NSMaxY(screen)-frame.size.height));
        [child.panel setFrame:frame display:YES]; [child show:nil];
    }
    [root saveSingleWindows]; return child;
}
-(void)saveSingleWindows {
    Controller *root=self.rootController?:self;
    if(!root.singleWindows || root.restoringWindows) return;
    NSMutableArray *records=[NSMutableArray new];
    for(Controller *child in root.singleWindows) {
        if(child.closed || !child.panel || !child.charts.count) continue;
        ChartState *chart=child.charts.firstObject;
        [records addObject:@{@"symbol":chart.symbol,@"digits":@([child digitsForSymbol:chart.symbol]),@"interval":chart.interval,@"expanded":@(chart.expanded),@"frame":NSStringFromRect(child.panel.frame),@"scale":@(child.panel.frame.size.width/310)}];
    }
    [NSUserDefaults.standardUserDefaults setObject:records forKey:@"SingleCoinWindows"];
}
-(void)restoreSingleWindows {
    id records=[NSUserDefaults.standardUserDefaults objectForKey:@"SingleCoinWindows"];
    if(![records isKindOfClass:NSArray.class]) return;
    self.restoringWindows=YES;
    for(id record in records) {
        if(![record isKindOfClass:NSDictionary.class]) continue;
        NSString *symbol=NormalizeSymbol(record[@"symbol"]);
        if(!symbol) continue;
        NSInteger digits=[record[@"digits"] isKindOfClass:NSNumber.class]?[record[@"digits"] integerValue]:PriceDigits(symbol);
        [self createSingleWindow:symbol digits:digits record:record];
    }
    self.restoringWindows=NO; [self saveSingleWindows];
}
-(void)newCoinWindow:(id)sender {
    if(self.rootController) { [self.rootController newCoinWindow:sender]; return; }
    if(!self.picker) {
        self.picker=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,400,250) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.picker.title=@"新建单币窗口"; self.picker.delegate=self; self.picker.releasedWhenClosed=NO;
        self.picker.floatingPanel=YES; self.picker.hidesOnDeactivate=NO;
        self.picker.level=MAX(NSFloatingWindowLevel+1,self.panel.level+1);
        self.picker.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
        NSView *v=self.picker.contentView;
        [v addSubview:PickerLabel(@"选择币种",NSMakeRect(24,210,350,22),16)];
        NSTextField *hint=PickerLabel(@"输入币种简称，例如 SOL、DOGE，或 SOL/USDT。",NSMakeRect(24,177,352,22),12); hint.textColor=NSColor.secondaryLabelColor; [v addSubview:hint];
        self.coinInput=[[NSComboBox alloc] initWithFrame:NSMakeRect(24,137,352,30)];
        [self.coinInput addItemsWithObjectValues:@[@"BTC",@"ETH",@"PENDLE",@"SOL",@"DOGE",@"XRP",@"BNB",@"SHIB"]];
        self.coinInput.completes=YES; self.coinInput.stringValue=@"BTC";
        self.coinInput.placeholderString=@"币种简称"; [self.coinInput setAccessibilityLabel:@"币种简称，USDT现货"];
        [v addSubview:self.coinInput];
        self.pickerMessage=PickerLabel(@"每次打开一个独立置顶窗口，可重复选择同一币种。",NSMakeRect(24,70,352,54),12);
        self.pickerMessage.textColor=NSColor.secondaryLabelColor; [v addSubview:self.pickerMessage];
        NSButton *cancel=[NSButton buttonWithTitle:@"取消" target:self action:@selector(cancelPicker:)]; cancel.frame=NSMakeRect(190,22,80,32); cancel.keyEquivalent=@"\033"; [v addSubview:cancel];
        self.openCoinButton=[NSButton buttonWithTitle:@"打开窗口" target:self action:@selector(confirmCoin:)]; self.openCoinButton.frame=NSMakeRect(278,22,98,32); self.openCoinButton.keyEquivalent=@"\r"; [v addSubview:self.openCoinButton];
        [self.picker center];
    }
    [NSApp activateIgnoringOtherApps:YES]; [self.picker makeKeyAndOrderFront:nil];
    if(!self.pickerTask) [self.picker makeFirstResponder:self.coinInput];
}
-(void)cancelPicker:(id)sender {
    self.pickerGeneration++; [self.pickerTask cancel]; self.pickerTask=nil;
    [self.pickerSession invalidateAndCancel]; self.pickerSession=nil;
    self.coinInput.enabled=YES; self.openCoinButton.enabled=YES;
    self.openCoinButton.title=@"打开窗口";
    self.pickerMessage.stringValue=@"每次打开一个独立置顶窗口，可重复选择同一币种。";
    self.pickerMessage.textColor=NSColor.secondaryLabelColor;
    [self.picker orderOut:nil];
}
-(void)confirmCoin:(id)sender {
    if(self.pickerTask) return;
    NSString *symbol=NormalizeSymbol(self.coinInput.stringValue);
    if(!symbol) { self.pickerMessage.stringValue=@"请输入币种简称，例如 BTC 或 SOL/USDT。"; self.pickerMessage.textColor=NSColor.systemRedColor; return; }
    if(Now()<self.pickerRetryAt) { self.pickerMessage.stringValue=@"查询暂时受限，请稍后再试。"; self.pickerMessage.textColor=NSColor.systemRedColor; return; }
    self.coinInput.enabled=NO; self.openCoinButton.enabled=NO; self.openCoinButton.title=@"正在查询…";
    self.pickerMessage.stringValue=[NSString stringWithFormat:@"正在确认 %@ 的实时行情…",symbol]; self.pickerMessage.textColor=NSColor.secondaryLabelColor;
    self.pickerSession=[self newSession];
    [self validateCoin:symbol endpoint:0 attempt:0 generation:++self.pickerGeneration];
}
-(void)validateCoin:(NSString *)symbol endpoint:(NSUInteger)endpoint attempt:(NSUInteger)attempt generation:(NSInteger)generation {
    NSURLComponents *url=[NSURLComponents componentsWithString:[APIHosts()[endpoint] stringByAppendingString:@"/api/v3/exchangeInfo"]];
    url.queryItems=@[[NSURLQueryItem queryItemWithName:@"symbol" value:symbol]];
    NSURLRequest *request=[NSURLRequest requestWithURL:url.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
    self.pickerTask=[self.pickerSession dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if(generation!=self.pickerGeneration) return;
            self.pickerTask=nil;
            NSInteger status=[(NSHTTPURLResponse *)response statusCode];
            id json=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
            NSNumber *digits=!error && status==200?MarketDigits(json,symbol):nil;
            if(digits) {
                [self cancelPicker:nil]; [self createSingleWindow:symbol digits:digits.integerValue record:nil]; return;
            }
            BOOL invalid=[json isKindOfClass:NSDictionary.class] && [json[@"code"] isKindOfClass:NSNumber.class] && [json[@"code"] integerValue]==-1121;
            BOOL limited=status==429 || status==418;
            if(!invalid && !limited && status!=200 && attempt+1<APIHosts().count) {
                [self validateCoin:symbol endpoint:(endpoint+1)%APIHosts().count attempt:attempt+1 generation:generation]; return;
            }
            if(limited) self.pickerRetryAt=Now()+MAX(30,[[(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Retry-After"] doubleValue]);
            self.pickerMessage.stringValue=invalid || (!error && status==200)?@"未找到可交易的 USDT 现货币种，请检查简称。":(limited?@"查询暂时受限，请稍后再试。":@"暂时连不上行情服务，请稍后再试。你输入的币种已保留。");
            self.pickerMessage.textColor=NSColor.systemRedColor;
            self.coinInput.enabled=YES; self.openCoinButton.enabled=YES; self.openCoinButton.title=@"打开窗口";
            [self.pickerSession finishTasksAndInvalidate]; self.pickerSession=nil;
            [self.picker makeFirstResponder:self.coinInput];
        });
    }]; [self.pickerTask resume];
}
@end
