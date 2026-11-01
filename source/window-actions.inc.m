// Included by main.m after windows.inc.m.
static NSRect SnapFrame(NSRect frame, NSRect screen, double distance) {
    if(fabs(NSMinX(frame)-NSMinX(screen))<=distance) frame.origin.x=NSMinX(screen);
    else if(fabs(NSMaxX(frame)-NSMaxX(screen))<=distance) frame.origin.x=NSMaxX(screen)-frame.size.width;
    if(fabs(NSMinY(frame)-NSMinY(screen))<=distance) frame.origin.y=NSMinY(screen);
    else if(fabs(NSMaxY(frame)-NSMaxY(screen))<=distance) frame.origin.y=NSMaxY(screen)-frame.size.height;
    return frame;
}
static NSArray<NSValue *> *TileCells(NSArray<NSNumber *> *heights, NSArray<NSNumber *> *scales, NSRect screen) {
    if(!heights.count) return @[];
    NSUInteger bestColumns=1; double bestScore=-1;
    const double gap=12;
    for(NSUInteger columns=1;columns<=heights.count;columns++) {
        NSUInteger rows=(heights.count+columns-1)/columns;
        double w=(screen.size.width-gap*(columns+1))/columns, h=(screen.size.height-gap*(rows+1))/rows;
        if(w<=0 || h<=0) continue;
        double score=1;
        for(NSUInteger i=0;i<heights.count;i++) score=MIN(score,MIN(w/310,h/heights[i].doubleValue)/MAX(.01,scales[i].doubleValue));
        if(score>=bestScore) { bestScore=score; bestColumns=columns; }
    }
    NSUInteger rows=(heights.count+bestColumns-1)/bestColumns;
    // At very large counts, reduce gutters rather than introducing a window-count cap.
    double g=MIN(gap,MIN(screen.size.width/(bestColumns+1)/4,screen.size.height/(rows+1)/4));
    double w=(screen.size.width-g*(bestColumns+1))/bestColumns, h=(screen.size.height-g*(rows+1))/rows;
    NSMutableArray *cells=[NSMutableArray new];
    for(NSUInteger i=0;i<heights.count;i++) [cells addObject:[NSValue valueWithRect:NSMakeRect(NSMinX(screen)+g+(i%bestColumns)*(w+g),NSMaxY(screen)-g-(i/bestColumns+1)*h-(i/bestColumns)*g,w,h)]];
    return cells;
}
@implementation Controller (WindowActions)
-(NSDictionary *)appearanceRecord { return @{@"pinned":@(self.pinned),@"opacity":@(self.opacity),@"snap":@(self.snapEnabled)}; }
-(void)restoreAppearance:(NSDictionary *)record {
    if(![record isKindOfClass:NSDictionary.class]) return;
    self.pinned=[record[@"pinned"] isKindOfClass:NSNumber.class]?[record[@"pinned"] boolValue]:YES;
    self.snapEnabled=[record[@"snap"] isKindOfClass:NSNumber.class]?[record[@"snap"] boolValue]:YES;
    double alpha=[record[@"opacity"] isKindOfClass:NSNumber.class]?[record[@"opacity"] doubleValue]:1;
    self.opacity=isfinite(alpha)?MAX(.6,MIN(1,alpha)):1;
}
-(void)applyWindowAppearance { self.panel.level=self.pinned?NSFloatingWindowLevel:NSNormalWindowLevel; self.panel.alphaValue=self.opacity; }
-(void)togglePinned:(id)sender { self.pinned=!self.pinned; [self applyWindowAppearance]; [self saveSingleWindows]; }
-(void)toggleSnap:(id)sender { self.snapEnabled=!self.snapEnabled; [self saveSingleWindows]; }
-(void)setOpacityFromMenu:(NSMenuItem *)sender { self.opacity=MAX(.6,MIN(1,sender.tag/100.0)); [self applyWindowAppearance]; [self saveSingleWindows]; }
-(BOOL)leftMouseIsDown { return (NSEvent.pressedMouseButtons & 1)!=0; }
-(void)beginWindowDrag {
    [self.dragEndTimer invalidate]; self.dragEndTimer=nil;
    if(!self.snapEnabled || self.closed) return;
    self.lastDragMovement=Now();
    __weak Controller *weakSelf=self;
    // Native window dragging returns immediately and may consume the mouse-up event.
    // Common modes keep this check active while AppKit tracks the drag.
    self.dragEndTimer=[NSTimer timerWithTimeInterval:.05 repeats:YES block:^(NSTimer *timer) { [weakSelf checkWindowDragEnd]; }];
    [NSRunLoop.mainRunLoop addTimer:self.dragEndTimer forMode:NSRunLoopCommonModes];
}
-(void)checkWindowDragEnd {
    if(!self.dragEndTimer) return;
    if(!self.closed && self.snapEnabled && ([self leftMouseIsDown] || Now()-self.lastDragMovement<.1)) return;
    [self.dragEndTimer invalidate]; self.dragEndTimer=nil;
    if(!self.closed && self.snapEnabled) [self snapToEdges];
}
-(void)snapToEdges {
    if(!self.snapEnabled || self.closed) return;
    NSRect frame=SnapFrame(self.panel.frame,(self.panel.screen?:NSScreen.mainScreen).visibleFrame,24);
    [self.panel setFrame:frame display:YES]; [self saveSingleWindows];
}
-(NSMenu *)windowOptions {
    NSMenu *menu=[NSMenu new];
    if(self.windowID) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:@"切换这个窗口的币种…" action:@selector(switchCoin:) keyEquivalent:@""]; item.target=self; [menu addItem:item]; }
    for(NSArray *entry in @[@[@"新建单币窗口…",@"newCoinWindow:"],@[@"一键排列所有窗口",@"arrangeWindows:"]]) {
        NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""]; item.target=self; [menu addItem:item];
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *pin=[[NSMenuItem alloc] initWithTitle:@"窗口置顶" action:@selector(togglePinned:) keyEquivalent:@""]; pin.target=self; pin.state=self.pinned?NSControlStateValueOn:NSControlStateValueOff; [menu addItem:pin];
    NSMenuItem *opacity=[[NSMenuItem alloc] initWithTitle:@"不透明度" action:nil keyEquivalent:@""]; opacity.submenu=[NSMenu new]; [menu addItem:opacity];
    for(NSNumber *value in @[@100,@90,@80,@70,@60]) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@%%%@",value,value.intValue==100?@"（完全不透明）":@""] action:@selector(setOpacityFromMenu:) keyEquivalent:@""]; item.tag=value.integerValue; item.target=self; item.state=fabs(self.opacity*100-value.doubleValue)<.5?NSControlStateValueOn:NSControlStateValueOff; [opacity.submenu addItem:item]; }
    NSMenuItem *snap=[[NSMenuItem alloc] initWithTitle:@"拖到屏幕边缘自动贴齐" action:@selector(toggleSnap:) keyEquivalent:@""]; snap.target=self; snap.state=self.snapEnabled?NSControlStateValueOn:NSControlStateValueOff; [menu addItem:snap];
    return menu;
}
-(void)showWindowOptions:(id)sender {
    NSView *button=[sender isKindOfClass:NSView.class]?sender:self.view;
    [[self windowOptions] popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,NSMaxY(button.bounds)) inView:button];
}
-(void)switchCoin:(id)sender { if(self.windowID && !self.closed) [(self.rootController?:self) presentCoinPickerForWindow:self]; }
-(void)replaceSymbol:(NSString *)symbol digits:(NSInteger)digits {
    if(!self.windowID || self.closed) return;
    self.symbolDigits=@{symbol:@(MAX(0,MIN(12,digits)))};
    if(![self.symbols.firstObject isEqual:symbol]) {
        self.selectedSymbols=@[symbol]; self.quotes=[NSMutableDictionary new]; self.started=Now();
        ChartState *chart=self.charts.firstObject;
        chart.symbol=symbol; chart.chartGeneration++; [chart.chartTask cancel]; chart.chartTask=nil;
        chart.candles=@[]; chart.chartFetched=0; chart.chartError=nil; chart.hovered=NO;
        [self reconnect:nil];
    }
    [self layoutPanel:self.panel.frame.size.width/310]; [self saveSingleWindows];
}
-(void)arrangeWindows:(id)sender {
    Controller *root=self.rootController?:self;
    NSArray *all=[@[root] arrayByAddingObjectsFromArray:root.singleWindows?:@[]];
    for(NSScreen *screen in NSScreen.screens) {
        NSMutableArray<Controller *> *group=[NSMutableArray new]; NSMutableArray *heights=[NSMutableArray new], *scales=[NSMutableArray new];
        for(Controller *window in all) if(!window.closed && (window.panel.screen?:NSScreen.mainScreen)==screen) { [group addObject:window]; [heights addObject:@([window baseHeight])]; [scales addObject:@(window.panel.frame.size.width/310)]; }
        NSArray *cells=TileCells(heights,scales,screen.visibleFrame);
        for(NSUInteger i=0;i<group.count;i++) {
            Controller *window=group[i]; NSRect cell=[cells[i] rectValue];
            [window layoutPanel:[scales[i] doubleValue] inVisibleFrame:cell];
            NSRect frame=window.panel.frame; frame.origin=NSMakePoint(NSMinX(cell),NSMaxY(cell)-frame.size.height); [window.panel setFrame:frame display:YES];
            double maximum=MIN(2,MIN(screen.visibleFrame.size.width/310,screen.visibleFrame.size.height/[window baseHeight]));
            double minimum=MIN(.8,MIN(maximum,frame.size.width/310));
            window.panel.contentMinSize=NSMakeSize(310*minimum,[window baseHeight]*minimum);
            window.panel.contentMaxSize=NSMakeSize(310*maximum,[window baseHeight]*maximum);
            [window show:nil];
        }
    }
    [root saveSingleWindows];
}
@end
