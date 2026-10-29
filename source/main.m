#import <Cocoa/Cocoa.h>

@interface Quote : NSObject
@property double price, change, timestamp;
@property BOOL live;
@end
@implementation Quote
@end
@interface ChartState : NSObject
@property BOOL expanded;
@property NSString *symbol, *interval, *chartError;
@property NSArray *candles;
@property NSURLSessionDataTask *chartTask;
@property NSInteger chartGeneration;
@property double chartFetched, chartAttempt;
@property NSMutableArray<NSButton *> *buttons;
@property NSButton *rowButton;
@end
@implementation ChartState
-(instancetype)init { if((self=[super init])) { _interval=@"15m"; _candles=@[]; _buttons=[NSMutableArray new]; } return self; }
@end
@class Controller;
@interface PanelView : NSView
@property (weak) Controller *owner;
@property NSTrackingArea *resizeTracking;
@property NSUInteger hoveredEdges;
@end
@interface Controller : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property NSPanel *panel;
@property PanelView *view;
@property NSStatusItem *status;
@property NSMutableDictionary<NSString *, Quote *> *quotes;
@property NSURLSession *session;
@property NSURLSessionWebSocketTask *socket;
@property NSURLSessionDataTask *pollTask;
@property NSTimer *timer;
@property double lastWS, lastPoll, lastConnect, started, retryAt, delay, lastRecovery;
@property NSInteger generation, pollGeneration;
@property BOOL polling;
@property NSArray<ChartState *> *charts;
-(void)fetchChart:(ChartState *)chart;
-(void)layoutPanel:(double)scale;
-(void)drawChart:(ChartState *)chart;
-(double)baseHeight;
-(double)rowY:(NSInteger)index;

-(void)connect;
-(void)poll;
-(NSURLSession *)newSession;
-(void)reconnect:(id)sender;
-(BOOL)accept:(NSDictionary *)item live:(BOOL)live;
@end
static NSColor *Up(void) { return [NSColor colorWithRed:.32 green:.88 blue:.68 alpha:1]; }
static NSColor *Down(void) { return [NSColor colorWithRed:1 green:.43 blue:.49 alpha:1]; }
static double Now(void) { return NSDate.date.timeIntervalSince1970; }
static const double RequestDeadline=12;
static const double RecoveryInterval=30;
static NSArray<NSString *> *Symbols(void) { return @[@"BTCUSDT",@"ETHUSDT",@"PENDLEUSDT"]; }
static NSString *CoinCode(NSString *symbol) { return [symbol substringToIndex:symbol.length-4]; }
static NSInteger PriceDigits(NSString *symbol) { return [symbol isEqualToString:@"PENDLEUSDT"]?4:2; }
static void Label(NSString *text, NSRect rect, CGFloat size, NSColor *color, BOOL bold, BOOL right) {
    NSMutableParagraphStyle *p=[NSMutableParagraphStyle new]; p.alignment=right?NSTextAlignmentRight:NSTextAlignmentLeft;
    NSFont *font=bold?[NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightSemibold]:[NSFont systemFontOfSize:size];
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:p}];
}
static NSArray *ParseCandles(id rows) {
    if(![rows isKindOfClass:NSArray.class] || ![rows count]) return nil;
    double previous=-1;
    for(id r in rows) {
        if(![r isKindOfClass:NSArray.class] || [r count]<7 || ![r[0] isKindOfClass:NSNumber.class]) return nil;
        double t=[r[0] doubleValue]; if(!isfinite(t) || t<=previous) return nil; previous=t;
        double v[4]; for(int i=0;i<4;i++) { if(![r[i+1] isKindOfClass:NSString.class]) return nil; NSScanner *scan=[NSScanner scannerWithString:r[i+1]]; if(![scan scanDouble:&v[i]] || !scan.atEnd || !isfinite(v[i]) || v[i]<=0) return nil; }
        if(v[1]<MAX(v[0],v[3]) || v[2]>MIN(v[0],v[3]) || v[1]<v[2]) return nil;
    }
    return rows;
}
@implementation PanelView
-(BOOL)isFlipped { return YES; }
// Keep the visible resize target eight screen points wide at every zoom level.
-(NSUInteger)resizeEdgesAt:(NSPoint)p {
    NSRect b=self.bounds; CGFloat band=8*b.size.width/MAX(1,self.frame.size.width);
    CGFloat corner=16*b.size.width/MAX(1,self.frame.size.width);
    BOOL nearX=p.x<band || p.x>b.size.width-band;
    BOOL nearY=p.y<band || p.y>b.size.height-band;
    if(!nearX && !nearY) return 0;
    NSUInteger edges=0;
    if(p.x<(nearY?corner:band)) edges|=2;
    else if(p.x>b.size.width-(nearY?corner:band)) edges|=8;
    if(p.y<(nearX?corner:band)) edges|=1;
    else if(p.y>b.size.height-(nearX?corner:band)) edges|=4;
    return edges;
}
-(NSCursor *)cursorForEdges:(NSUInteger)edges {
    if(!edges) return NSCursor.arrowCursor;
    if(@available(macOS 15.0,*)) return [NSCursor frameResizeCursorFromPosition:(NSCursorFrameResizePosition)edges inDirections:NSCursorFrameResizeDirectionsAll];
    if((edges&10) && (edges&5)) {
        static NSCursor *diagonalA,*diagonalB;
        if(!diagonalA) {
            NSMutableArray *cursors=[NSMutableArray new];
            for(NSInteger i=0;i<2;i++) {
                NSImage *image=[NSImage imageWithSize:NSMakeSize(24,24) flipped:NO drawingHandler:^BOOL(NSRect r) {
                    NSAffineTransform *t=[NSAffineTransform transform]; if(i) { [t translateXBy:24 yBy:0]; [t scaleXBy:-1 yBy:1]; [t concat]; }
                    NSBezierPath *p=[NSBezierPath bezierPath];
                    [p moveToPoint:NSMakePoint(5,5)]; [p lineToPoint:NSMakePoint(19,19)];
                    [p moveToPoint:NSMakePoint(5,12)]; [p lineToPoint:NSMakePoint(5,5)]; [p lineToPoint:NSMakePoint(12,5)];
                    [p moveToPoint:NSMakePoint(12,19)]; [p lineToPoint:NSMakePoint(19,19)]; [p lineToPoint:NSMakePoint(19,12)];
                    p.lineWidth=4; [NSColor.whiteColor setStroke]; [p stroke]; p.lineWidth=2; [NSColor.blackColor setStroke]; [p stroke]; return YES;
                }];
                [cursors addObject:[[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(12,12)]];
            }
            diagonalA=cursors[0]; diagonalB=cursors[1];
        }
        return edges==3 || edges==12?diagonalB:diagonalA;
    }
    return edges&10?NSCursor.resizeLeftRightCursor:NSCursor.resizeUpDownCursor;
}
-(BOOL)mouseDownCanMoveWindow { return NO; }
-(NSView *)hitTest:(NSPoint)point {
    NSPoint local=[self convertPoint:point fromView:self.superview];
    if(NSPointInRect(local,self.bounds) && [self resizeEdgesAt:local]) return self;
    return [super hitTest:point];
}
-(void)updateTrackingAreas {
    [super updateTrackingAreas];
    if(self.resizeTracking) [self removeTrackingArea:self.resizeTracking];
    self.resizeTracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingCursorUpdate|NSTrackingActiveAlways|NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.resizeTracking];
}
-(void)updateResizeCursor {
    NSPoint point=[self convertPoint:[self.window mouseLocationOutsideOfEventStream] fromView:nil];
    NSUInteger edges=[self resizeEdgesAt:point];
    if(edges!=self.hoveredEdges) { self.hoveredEdges=edges; [self setNeedsDisplay:YES]; }
    [[self cursorForEdges:edges] set];
}
-(void)cursorUpdate:(NSEvent *)event { [self updateResizeCursor]; }
-(void)mouseMoved:(NSEvent *)event { [self updateResizeCursor]; }
-(void)mouseEntered:(NSEvent *)event { [self updateResizeCursor]; }
-(void)mouseExited:(NSEvent *)event { self.hoveredEdges=0; [self setNeedsDisplay:YES]; [NSCursor.arrowCursor set]; }
-(void)resetCursorRects {
    [super resetCursorRects];
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
    CGFloat e=8*w/MAX(1,self.frame.size.width),c=16*w/MAX(1,self.frame.size.width);
    [self addCursorRect:NSMakeRect(c,0,w-2*c,e) cursor:[self cursorForEdges:1]];
    [self addCursorRect:NSMakeRect(c,h-e,w-2*c,e) cursor:[self cursorForEdges:4]];
    [self addCursorRect:NSMakeRect(0,c,e,h-2*c) cursor:[self cursorForEdges:2]];
    [self addCursorRect:NSMakeRect(w-e,c,e,h-2*c) cursor:[self cursorForEdges:8]];
    for(NSNumber *value in @[@3,@9,@6,@12]) {
        NSUInteger edge=value.unsignedIntegerValue;
        [self addCursorRect:NSMakeRect(edge&2?0:w-e,edge&1?0:h-c,e,c) cursor:[self cursorForEdges:edge]];
        [self addCursorRect:NSMakeRect(edge&2?0:w-c,edge&1?0:h-e,c,e) cursor:[self cursorForEdges:edge]];
    }
}
-(void)mouseDown:(NSEvent *)event {
    NSUInteger edges=[self resizeEdgesAt:[self convertPoint:event.locationInWindow fromView:nil]];
    if(!edges) { [self.window performWindowDragWithEvent:event]; return; }
    NSRect initial=self.window.frame;
    NSPoint start=[self.window convertPointToScreen:event.locationInWindow];
    NSCursor *cursor=[self cursorForEdges:edges]; [cursor push];
    while(YES) {
        NSEvent *next=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];
        if(!next || next.type==NSEventTypeLeftMouseUp) break;
        NSPoint point=[self.window convertPointToScreen:next.locationInWindow];
        double dx=(point.x-start.x)*(edges&2?-1:1),dy=(point.y-start.y)*(edges&4?-1:1);
        double ratio;
        if((edges&10) && (edges&5)) ratio=1+(dx*initial.size.width+dy*initial.size.height)/(initial.size.width*initial.size.width+initial.size.height*initial.size.height);
        else ratio=1+((edges&10)?dx/initial.size.width:dy/initial.size.height);
        double minRatio=self.window.contentMinSize.width/initial.size.width,maxRatio=self.window.contentMaxSize.width/initial.size.width;
        ratio=MAX(minRatio,MIN(maxRatio,ratio));
        NSRect frame=initial; frame.size=NSMakeSize(initial.size.width*ratio,initial.size.height*ratio);
        frame.origin.x=edges&2?NSMaxX(initial)-frame.size.width:(edges&8?initial.origin.x:NSMidX(initial)-frame.size.width/2);
        frame.origin.y=edges&4?NSMaxY(initial)-frame.size.height:(edges&1?initial.origin.y:NSMidY(initial)-frame.size.height/2);
        [self.window setFrame:frame display:YES]; [cursor set];
    }
    [NSCursor pop]; [self.window invalidateCursorRectsForView:self]; [self updateResizeCursor];
}

-(void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self setBoundsSize:NSMakeSize(310,[self.owner baseHeight])];
    [self setNeedsDisplay:YES];
    [self.window invalidateCursorRectsForView:self];
}
-(void)drawRect:(NSRect)dirty {
    NSRect b=NSInsetRect(self.bounds,.5,.5);
    NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:b xRadius:16 yRadius:16];
    [[NSColor colorWithRed:.065 green:.085 blue:.12 alpha:1] setFill]; [path fill];
    [(self.hoveredEdges?Up():[NSColor colorWithWhite:1 alpha:.16]) setStroke]; [path stroke];
    Label(@"CRYPTO PULSE",NSMakeRect(17,15,150,18),11,NSColor.whiteColor,YES,NO);
    Label(@"置顶",NSMakeRect(155,15,35,18),10,Up(),NO,YES);
    BOOL fresh=self.owner.quotes.count==self.owner.charts.count;
    BOOL live=YES;
    NSArray *names=@[@"Bitcoin",@"Ethereum",@"Pendle"];
    for (NSInteger i=0;i<self.owner.charts.count;i++) {
        ChartState *chart=self.owner.charts[i];
        NSString *s=CoinCode(chart.symbol); Quote *q=self.owner.quotes[chart.symbol];
        BOOL stale=!q || Now()-q.timestamp>15;
        fresh=fresh&&!stale; live=live&&q.live;
        CGFloat y=[self.owner rowY:i]+6;
        if(chart.expanded) {
            [[NSColor colorWithWhite:1 alpha:.045] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(9,y-6,292,62) xRadius:8 yRadius:8] fill];
        }
        NSColor *coin=i==0?NSColor.orangeColor:(i==1?[NSColor colorWithRed:.65 green:.72 blue:1 alpha:1]:[NSColor colorWithRed:.58 green:.86 blue:.84 alpha:1]);
        Label(s,NSMakeRect(17,y,75,25),s.length>3?14:19,coin,YES,NO);
        Label([NSString stringWithFormat:@"%@ %@ K线",names[i],chart.expanded?@"⌄":@"›"],NSMakeRect(17,y+27,80,15),10,NSColor.lightGrayColor,NO,NO);
        NSNumberFormatter *f=[NSNumberFormatter new]; f.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US"]; f.numberStyle=NSNumberFormatterDecimalStyle; f.minimumFractionDigits=PriceDigits(chart.symbol); f.maximumFractionDigits=PriceDigits(chart.symbol);
        NSString *price=q?[f stringFromNumber:@(q.price)]:@"— —";
        Label(price,NSMakeRect(95,y-3,198,34),26,stale?NSColor.grayColor:NSColor.whiteColor,YES,YES);
        NSString *change=q?[NSString stringWithFormat:@"%@%.2f%%",q.change>=0?@"↑ +":@"↓ −",fabs(q.change)]:@"等待行情";
        Label(change,NSMakeRect(120,y+32,173,18),12,stale?NSColor.grayColor:(q.change>=0?Up():Down()),YES,YES);
        if(chart.expanded) {
            [NSGraphicsContext saveGraphicsState]; NSAffineTransform *t=[NSAffineTransform transform];
            [t translateXBy:0 yBy:[self.owner rowY:i]+64-224]; [t concat];
            [self.owner drawChart:chart]; [NSGraphicsContext restoreGraphicsState];
        }
    }
    [[NSColor colorWithWhite:1 alpha:.10] setFill];
    for(NSInteger i=1;i<self.owner.charts.count;i++) NSRectFill(NSMakeRect(17,[self.owner rowY:i]-7,276,1));
    CGFloat footer=[self.owner baseHeight]-31;
    NSString *status=self.owner.quotes.count==0?(Now()-self.owner.started<15?@"连接行情中…":@"网络不可用 · 重试中"):(fresh?(live?@"Binance · 实时":@"Binance · 5秒刷新"):@"数据已过期 · 重连中");
    [(fresh?Up():NSColor.orangeColor) setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(17,footer+5,5,5)] fill];
    Label(status,NSMakeRect(28,footer,160,17),10,NSColor.lightGrayColor,NO,NO);
    Label(@"USDT · 24h涨跌",NSMakeRect(190,footer,103,17),10,NSColor.lightGrayColor,NO,YES);
}
@end
@implementation Controller
-(void)applicationDidFinishLaunching:(NSNotification *)n {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSMutableArray *charts=[NSMutableArray new];
    for(NSString *symbol in Symbols()) { ChartState *chart=[ChartState new]; chart.symbol=symbol; [charts addObject:chart]; }
    self.charts=charts;
    self.quotes=[NSMutableDictionary new]; self.session=[self newSession]; self.started=Now(); self.lastRecovery=self.started; self.delay=2;
    self.panel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,310,[self baseHeight]) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    self.panel.delegate=self;
    self.panel.title=@"Crypto Pulse Mini"; self.panel.level=NSScreenSaverWindowLevel;
    self.panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorStationary;
    self.panel.acceptsMouseMovedEvents=YES; self.panel.floatingPanel=YES; self.panel.hidesOnDeactivate=NO; self.panel.movableByWindowBackground=YES;
    self.panel.opaque=NO; self.panel.backgroundColor=NSColor.clearColor; self.panel.hasShadow=YES;
    self.view=[[PanelView alloc] initWithFrame:NSMakeRect(0,0,310,[self baseHeight])]; self.view.owner=self; self.panel.contentView=self.view;
    NSButton *close=[NSButton buttonWithTitle:@"×" target:self action:@selector(quit:)]; close.frame=NSMakeRect(278,9,24,24); close.bordered=NO; close.font=[NSFont systemFontOfSize:17]; close.contentTintColor=NSColor.lightGrayColor; close.toolTip=@"退出行情窗口"; [close setAccessibilityLabel:@"退出行情窗口"]; [self.view addSubview:close];
    [self addButton:@"−" rect:NSMakeRect(201,9,26,24) action:@selector(zoom:) tag:-1 hint:@"缩小窗口" chart:NO];
    [self addButton:@"＋" rect:NSMakeRect(235,9,26,24) action:@selector(zoom:) tag:1 hint:@"放大窗口" chart:NO];
    NSArray *names=@[@"15分钟",@"1小时",@"4小时",@"1天"];
    for(NSInteger i=0;i<self.charts.count;i++) {
        ChartState *chart=self.charts[i];
        chart.rowButton=[self addButton:@"" rect:NSMakeRect(10,43+i*75,288,64) action:@selector(selectCoin:) tag:i hint:[NSString stringWithFormat:@"展开 %@ K线",CoinCode(chart.symbol)] chart:NO];
        NSButton *closeChart=[self addButton:@"收起" rect:NSZeroRect action:@selector(collapse:) tag:i hint:[NSString stringWithFormat:@"收起 %@ K线",chart.symbol] chart:NO];
        [chart.buttons addObject:closeChart];
        for(NSInteger j=0;j<4;j++) [chart.buttons addObject:[self addButton:names[j] rect:NSZeroRect action:@selector(selectInterval:) tag:i*4+j hint:[NSString stringWithFormat:@"%@ %@",chart.symbol,names[j]] chart:NO]];
    }
    [self.panel setFrameAutosaveName:@"CryptoPulseMiniPosition"];
    if (![self.panel setFrameUsingName:@"CryptoPulseMiniPosition"]) [self reset:nil];
    BOOL visible=NO; for(NSScreen *s in NSScreen.screens) if(NSIntersectsRect(s.visibleFrame,self.panel.frame)) visible=YES;
    if(!visible) [self reset:nil];
    double scale=[NSUserDefaults.standardUserDefaults doubleForKey:@"MiniScale"];
    [self layoutPanel:scale>0?scale:1];
    [self.panel orderFrontRegardless];
    self.status=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength]; self.status.button.image=[NSImage imageWithSystemSymbolName:@"chart.line.uptrend.xyaxis" accessibilityDescription:@"Crypto Pulse 行情"];
    NSMenu *menu=[NSMenu new];
    for(NSArray *entry in @[@[@"显示行情窗口",@"show:"],@[@"重新连接行情",@"reconnect:"],@[@"移到屏幕右上角",@"reset:"],@[@"退出 Crypto Pulse",@"quit:"]]) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""]; item.target=self; [menu addItem:item]; }
    self.status.menu=menu;
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(wake:) name:NSWorkspaceDidWakeNotification object:nil];
    [self connect]; [self poll];
    self.timer=[NSTimer timerWithTimeInterval:1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
-(NSButton *)addButton:(NSString *)title rect:(NSRect)rect action:(SEL)action tag:(NSInteger)tag hint:(NSString *)hint chart:(BOOL)chart {
    NSButton *b=[NSButton buttonWithTitle:title target:self action:action]; b.frame=rect; b.bordered=NO; b.font=[NSFont systemFontOfSize:11 weight:NSFontWeightMedium]; b.contentTintColor=NSColor.lightGrayColor; b.tag=tag; b.toolTip=hint; [b setAccessibilityLabel:hint]; [self.view addSubview:b];
    return b;
}
-(void)layoutPanel:(double)scale {
    NSRect screen=(self.panel.screen?:NSScreen.mainScreen).visibleFrame;
    double height=[self baseHeight];
    double maxScale=MIN(2.0,MIN(screen.size.width/310,screen.size.height/height));
    scale=MIN(maxScale,MAX(.8,scale));
    double minScale=MIN(.8,maxScale);
    self.panel.contentMinSize=NSMakeSize(310*minScale,height*minScale);
    self.panel.contentMaxSize=NSMakeSize(310*maxScale,height*maxScale);
    self.panel.contentAspectRatio=NSMakeSize(310,height);
    NSRect f=self.panel.frame; double top=NSMaxY(f); f.size=NSMakeSize(310*scale,height*scale); f.origin.y=top-f.size.height;
    f.origin.x=MAX(NSMinX(screen),MIN(f.origin.x,NSMaxX(screen)-f.size.width));
    f.origin.y=MAX(NSMinY(screen),MIN(f.origin.y,NSMaxY(screen)-f.size.height));
    [self.panel setFrame:f display:YES]; [self.view setBoundsSize:NSMakeSize(310,height)];
    NSArray *intervals=@[@"15m",@"1h",@"4h",@"1d"];
    for(NSInteger i=0;i<self.charts.count;i++) {
        ChartState *chart=self.charts[i]; double row=[self rowY:i], start=row+64;
        chart.rowButton.frame=NSMakeRect(10,row,288,64);
        NSString *hint=[NSString stringWithFormat:@"%@ %@ K线",chart.expanded?@"收起":@"展开",CoinCode(chart.symbol)];
        chart.rowButton.toolTip=hint; [chart.rowButton setAccessibilityLabel:hint];
        chart.buttons[0].frame=NSMakeRect(250,start,45,24);
        for(NSInteger j=0;j<4;j++) chart.buttons[j+1].frame=NSMakeRect(15+j*71,start+30,66,25);
        for(NSButton *b in chart.buttons) { b.hidden=!chart.expanded; b.contentTintColor=NSColor.lightGrayColor; }
        chart.buttons[1+[intervals indexOfObject:chart.interval]].contentTintColor=Up();
    }
    [NSUserDefaults.standardUserDefaults setDouble:scale forKey:@"MiniScale"];
    [self.view setNeedsDisplay:YES];
}
-(void)windowDidResize:(NSNotification *)n { [NSUserDefaults.standardUserDefaults setDouble:self.panel.frame.size.width/310 forKey:@"MiniScale"]; }
-(void)zoom:(NSButton *)sender { [self layoutPanel:self.panel.frame.size.width/310+sender.tag*.1]; }
-(double)baseHeight {
    double height=80+75*self.charts.count;
    for(ChartState *chart in self.charts) if(chart.expanded) height+=260;
    return height;
}
-(double)rowY:(NSInteger)index {
    double y=43+index*75;
    for(NSInteger i=0;i<index;i++) if(self.charts[i].expanded) y+=260;
    return y;
}
-(void)toggleChart:(NSInteger)index {
    ChartState *chart=self.charts[index]; chart.expanded=!chart.expanded;
    chart.chartGeneration++; [chart.chartTask cancel]; chart.chartTask=nil;
    if(chart.expanded) [self fetchChart:chart];
    [self layoutPanel:self.panel.frame.size.width/310];
}
-(void)selectCoin:(NSButton *)sender { [self toggleChart:sender.tag]; }
-(void)selectInterval:(NSButton *)sender {
    ChartState *chart=self.charts[sender.tag/4];
    chart.interval=@[@"15m",@"1h",@"4h",@"1d"][sender.tag%4];
    chart.chartGeneration++; [chart.chartTask cancel]; chart.chartTask=nil;
    chart.candles=@[]; chart.chartFetched=0; chart.chartError=nil; [self fetchChart:chart];
    [self layoutPanel:self.panel.frame.size.width/310];
}
-(void)collapse:(NSButton *)sender { if(self.charts[sender.tag].expanded) [self toggleChart:sender.tag]; }
-(void)fetchChart:(ChartState *)chart {
    if(!chart.expanded || chart.chartTask) return;
    chart.chartAttempt=Now(); NSInteger token=++chart.chartGeneration;
    NSURLComponents *url=[NSURLComponents componentsWithString:@"https://data-api.binance.vision/api/v3/klines"];
    url.queryItems=@[[NSURLQueryItem queryItemWithName:@"symbol" value:chart.symbol],[NSURLQueryItem queryItemWithName:@"interval" value:chart.interval],[NSURLQueryItem queryItemWithName:@"limit" value:@"60"]];
    NSURLRequest *request=[NSURLRequest requestWithURL:url.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
    chart.chartTask=[self.session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if(token!=chart.chartGeneration) return;
            chart.chartTask=nil;
            NSArray *rows=nil;
            if(!error && [(NSHTTPURLResponse *)response statusCode]==200 && data) rows=ParseCandles([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
            if(rows.count) { chart.candles=rows; chart.chartFetched=Now(); chart.chartError=nil; }
            else chart.chartError=@"K线连接失败 · 自动重试中";
            [self.view setNeedsDisplay:YES];
        });
    }]; [chart.chartTask resume];
}
-(void)drawChart:(ChartState *)chart {
    Label([NSString stringWithFormat:@"%@ · K线",chart.symbol],NSMakeRect(17,228,220,19),12,NSColor.whiteColor,YES,NO);
    if(!chart.candles.count) {
        Label(chart.chartError?:@"正在加载K线…",NSMakeRect(27,350,260,25),12,NSColor.lightGrayColor,NO,NO); return;
    }
    double lo=DBL_MAX,hi=-DBL_MAX;
    for(NSArray *r in chart.candles) { hi=MAX(hi,[r[2] doubleValue]); lo=MIN(lo,[r[3] doubleValue]); }
    double pad=MAX((hi-lo)*.08,hi*.00001); hi+=pad;lo-=pad;
    double (^y)(double)=^double(double price) { return 299+(hi-price)/(hi-lo)*137; };
    for(int i=0;i<4;i++) {
        double price=hi-(hi-lo)*i/3.0, yy=y(price);
        [[NSColor colorWithWhite:1 alpha:.08] setFill]; NSRectFill(NSMakeRect(17,yy,225,.5));
        Label([NSString stringWithFormat:@"%.*f",[chart.symbol isEqualToString:@"PENDLEUSDT"]?4:0,price],NSMakeRect(245,yy-6,49,14),9,NSColor.lightGrayColor,NO,YES);
    }
    double step=225.0/chart.candles.count;
    BOOL stale=Now()-chart.chartFetched>15;
    for(NSUInteger i=0;i<chart.candles.count;i++) {
        NSArray *r=chart.candles[i]; double o=[r[1] doubleValue],h=[r[2] doubleValue],l=[r[3] doubleValue],c=[r[4] doubleValue];
        NSColor *color=stale?NSColor.grayColor:(c>=o?Up():Down()); [color setStroke]; [color setFill];
        double x=17+(i+.5)*step;
        NSBezierPath *wick=[NSBezierPath bezierPath]; [wick moveToPoint:NSMakePoint(x,y(h))]; [wick lineToPoint:NSMakePoint(x,y(l))]; wick.lineWidth=.7; [wick stroke];
        NSRect body=NSMakeRect(x-step*.32,MIN(y(o),y(c)),step*.64,MAX(1,fabs(y(o)-y(c))));
        NSBezierPath *box=[NSBezierPath bezierPathWithRect:body]; box.lineWidth=.7;
        if(c>=o) { [[NSColor colorWithRed:.065 green:.085 blue:.12 alpha:1] setFill]; [box fill]; [color setStroke]; [box stroke]; } else [box fill];
    }
    NSDateFormatter *f=[NSDateFormatter new]; f.timeZone=[NSTimeZone timeZoneWithName:@"Asia/Shanghai"]; f.dateFormat=[chart.interval isEqualToString:@"1d"]?@"MM/dd":@"MM/dd HH:mm";
    for(int i=0;i<2;i++) { NSArray *r=i==0?chart.candles.firstObject:chart.candles.lastObject; Label([f stringFromDate:[NSDate dateWithTimeIntervalSince1970:[r[0] doubleValue]/1000]],NSMakeRect(i==0?17:134,440,108,15),9,NSColor.lightGrayColor,NO,i!=0); }
    NSString *message=stale?@"K线已过期 · 重试中":@"60根 · 5秒更新 · 末根未收盘";
    Label(message,NSMakeRect(17,465,235,16),9,stale?NSColor.orangeColor:NSColor.lightGrayColor,NO,NO);
    Label(@"北京时间",NSMakeRect(240,465,54,16),9,NSColor.lightGrayColor,NO,YES);
    NSArray *last=chart.candles.lastObject;
    Label([NSString stringWithFormat:@"开 %.*f   收 %.*f",(int)PriceDigits(chart.symbol),[last[1] doubleValue],(int)PriceDigits(chart.symbol),[last[4] doubleValue]],NSMakeRect(17,282,280,14),9,NSColor.lightGrayColor,NO,NO);
}
-(void)show:(id)sender { [self.panel orderFrontRegardless]; }
-(BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    [self show:nil]; return YES;
}
-(void)reset:(id)sender { NSRect r=NSScreen.mainScreen.visibleFrame; [self.panel setFrameOrigin:NSMakePoint(NSMaxX(r)-334,NSMaxY(r)-254)]; [self show:nil]; }
-(void)quit:(id)sender { [NSApp terminate:nil]; }
-(NSURLSession *)newSession {
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest=8;
    config.timeoutIntervalForResource=RequestDeadline;
    config.waitsForConnectivity=NO;
    return [NSURLSession sessionWithConfiguration:config];
}
-(void)reconnect:(id)sender {
    // Invalidate generations before cancelling: late completions must not clear new tasks.
    self.lastRecovery=Now(); self.generation++; self.pollGeneration++;
    [self.socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil]; self.socket=nil;
    [self.pollTask cancel]; self.pollTask=nil; self.polling=NO;
    for(ChartState *chart in self.charts) {
        chart.chartGeneration++; [chart.chartTask cancel]; chart.chartTask=nil;
        chart.chartAttempt=0; chart.chartError=nil;
    }
    [self.session invalidateAndCancel]; self.session=[self newSession];
    self.lastWS=0; self.retryAt=0; self.delay=2;
    [self connect]; [self poll];
    for(ChartState *chart in self.charts) if(chart.expanded) [self fetchChart:chart];
    [self.view setNeedsDisplay:YES];
}
-(void)wake:(id)sender { [self reconnect:nil]; [self show:nil]; }
-(void)tick:(id)sender {
    [self.view setNeedsDisplay:YES];
    double now=Now(); BOOL recover=self.polling && now-self.lastPoll>=RequestDeadline;
    for(ChartState *chart in self.charts) if(chart.expanded) {
        if(chart.chartTask && now-chart.chartAttempt>=RequestDeadline) recover=YES;
        // Rebuild a broken connection pool even when individual requests keep failing quickly.
        if(now-self.lastRecovery>=RecoveryInterval && now-MAX(chart.chartFetched,self.lastRecovery)>=RecoveryInterval) recover=YES;
    }
    if(recover) { [self reconnect:nil]; return; }
    for(ChartState *chart in self.charts) if(chart.expanded && !chart.chartTask && now-chart.chartAttempt>=5) [self fetchChart:chart];
    if(Now()-self.lastWS>5 && Now()-self.lastPoll>=5) [self poll];
    if((!self.socket && Now()>=self.retryAt) || (self.socket && Now()-MAX(self.lastWS,self.lastConnect)>20)) [self connect];
}
-(BOOL)accept:(NSDictionary *)item live:(BOOL)live {
    if(![item isKindOfClass:NSDictionary.class]) return NO;
    NSString *s=item[live?@"s":@"symbol"], *p=item[live?@"c":@"lastPrice"], *c=item[live?@"P":@"priceChangePercent"];
    NSNumber *stamp=item[live?@"E":@"closeTime"];
    if(![Symbols() containsObject:s] || ![p isKindOfClass:NSString.class] || ![c isKindOfClass:NSString.class] || ![stamp isKindOfClass:NSNumber.class]) return NO;
    double price,change; NSScanner *ps=[NSScanner scannerWithString:p], *cs=[NSScanner scannerWithString:c];
    if(![ps scanDouble:&price] || !ps.atEnd || ![cs scanDouble:&change] || !cs.atEnd || !isfinite(price) || price<=0 || !isfinite(change)) return NO;
    double time=stamp.doubleValue/1000; Quote *old=self.quotes[s]; if(old && old.timestamp>time) return NO;
    Quote *q=[Quote new]; q.price=price; q.change=change; q.timestamp=time; q.live=live; self.quotes[s]=q;
    [self.view setNeedsDisplay:YES]; return YES;
}
-(void)connect {
    self.generation++; [self.socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    self.lastConnect=Now();
    NSMutableArray *streams=[NSMutableArray new];
    for(NSString *symbol in Symbols()) [streams addObject:[symbol.lowercaseString stringByAppendingString:@"@ticker"]];
    NSString *address=[@"wss://data-stream.binance.vision/stream?streams=" stringByAppendingString:[streams componentsJoinedByString:@"/"]];
    self.socket=[self.session webSocketTaskWithURL:[NSURL URLWithString:address]];
    [self.socket resume]; [self receive:self.socket generation:self.generation];
}
-(void)receive:(NSURLSessionWebSocketTask *)socket generation:(NSInteger)token {
    [socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *m,NSError *error){
        dispatch_async(dispatch_get_main_queue(), ^{
            if(token!=self.generation) return;
            if(error) { self.socket=nil; self.retryAt=Now()+self.delay; self.delay=MIN(60,self.delay*2); return; }
            NSData *data=m.type==NSURLSessionWebSocketMessageTypeString?[m.string dataUsingEncoding:NSUTF8StringEncoding]:m.data;
            id root=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
            if([root isKindOfClass:NSDictionary.class] && [self accept:root[@"data"] live:YES]) { self.lastWS=Now(); self.delay=2; }
            [self receive:socket generation:token];
        });
    }];
}
-(void)poll {
    if(self.polling) return; self.polling=YES; self.lastPoll=Now();
    NSInteger token=++self.pollGeneration;
    NSURLComponents *url=[NSURLComponents componentsWithString:@"https://data-api.binance.vision/api/v3/ticker/24hr"];
    NSString *symbolsJSON=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:Symbols() options:0 error:nil] encoding:NSUTF8StringEncoding];
    url.queryItems=@[[NSURLQueryItem queryItemWithName:@"symbols" value:symbolsJSON]];
    NSURLRequest *request=[NSURLRequest requestWithURL:url.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
    self.pollTask=[self.session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        dispatch_async(dispatch_get_main_queue(), ^{
            if(token!=self.pollGeneration) return;
            self.pollTask=nil; self.polling=NO; if(error || ((NSHTTPURLResponse *)response).statusCode!=200 || !data) return;
            id items=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if([items isKindOfClass:NSArray.class]) for(id item in items) [self accept:item live:NO];
        });
    }]; [self.pollTask resume];
}
@end
int main(int argc,const char *argv[]) { @autoreleasepool {
    if(argc>1 && strcmp(argv[1],"--self-test")==0) {
        Controller *c=[Controller new]; c.quotes=[NSMutableDictionary new];
        NSCAssert(([c accept:@{@"s":@"BTCUSDT",@"c":@"82176.00",@"P":@"1.717",@"E":@(Now()*1000)} live:YES]),@"valid quote");
        NSCAssert((![c accept:@{@"s":@"BTCUSDT",@"c":@"nan",@"P":@"1",@"E":@0} live:YES]),@"invalid quote");
        NSCAssert((![c accept:@{@"s":@"BTCUSDT",@"c":@"-10",@"P":@"1",@"E":@0} live:YES]),@"negative quote");
        NSCAssert((![c accept:@{@"symbol":@"BTCUSDT",@"lastPrice":@"1",@"priceChangePercent":@"1",@"closeTime":@0} live:NO]),@"out of order quote");
        NSCAssert((ParseCandles(@[@[@1000,@"10",@"12",@"9",@"11",@"1",@2000]])!=nil),@"valid candles");
        NSCAssert((ParseCandles(@[@[@1000,@"10",@"8",@"9",@"11",@"1",@2000]])==nil),@"invalid OHLC");
        NSCAssert((ParseCandles(@[@[@1000,@"nan",@"12",@"9",@"11",@"1",@2000]])==nil),@"invalid candle number");
        puts("PASS: candle validation and  valid quotes, invalid values, negative prices, out-of-order updates"); return 0;
    }
    NSApplication *app=NSApplication.sharedApplication; Controller *delegate=[Controller new]; app.delegate=delegate; [app run];
} return 0; }
