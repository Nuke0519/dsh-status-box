/*
 * DSH Status Box — macOS menu bar companion for the dsh-status-box plugin.
 *
 * Why this exists: the DSH desktop window cannot reach the macOS menu bar from a
 * plugin (the Tray belongs to the packaged Electron shell), so this small helper
 * runs beside it and mirrors the plugin's status:
 *
 *   client half  --POST /status-->  this helper  -->  menu bar title + menu
 *                                                      + native floating panel
 *   client half  <--GET /command--  this helper  <--  tasks typed in the panel
 *   client half  --POST /command/ack--> this helper  (delivery confirmation)
 *
 * The floating capture panel and the global hotkey (Carbon RegisterEventHotKey,
 * no Accessibility permission needed) are intentionally independent of DSH:
 * pressing option+command+shift+D opens the panel even when DSH is closed, and
 * anything typed there is persisted to queue.json and delivered as soon as a
 * DSH frame polls /command again.
 *
 * Local only: the HTTP server binds 127.0.0.1 and never talks to the network.
 */

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static const uint16_t kPort = 59421;
static const NSTimeInterval kStaleAfter = 90.0;

// The bridge only accepts browser requests from the DSH page itself: the
// desktop shell loads it from the custom dsh-app:// scheme, the web UI from
// loopback http. Local tools (curl, the installer, the hotkey helper) send no
// Origin header and are allowed, because they cannot be reached from a page.
static BOOL bridgeOriginAllowed(NSString *origin) {
  if (origin.length == 0) return YES;
  if ([origin hasPrefix:@"dsh-app://"]) return YES;
  if ([origin hasPrefix:@"http://127.0.0.1:"]) return YES;
  if ([origin hasPrefix:@"http://localhost:"]) return YES;
  return NO;
}

static __thread char tBridgeAllowedOrigin[160];

// /debug and /panelstate expose internals (session titles, the draft text in
// the capture field): off unless explicitly enabled for a debugging session.
static BOOL debugRoutesEnabled(void) {
  const char *value = getenv("DSH_STATUS_BOX_DEBUG");
  return value != NULL && strcmp(value, "1") == 0;
}

// While the DSH app is alive the last known status stays authoritative: the
// renderer may be throttled (minimized window, closed window) and simply stop
// posting for a while, but that is not "no status" — the menu bar item keeps
// showing the last numbers and only turns grey when DSH itself is gone.

// helpers defined further down, used by the persisted-state / queue block
static NSNumber *numOr(NSDictionary *dict, NSString *key, double fallback);
static id dictAt(NSDictionary *dict, NSString *key);
static NSArray *arrayAt(NSDictionary *dict, NSString *key);
static void refreshCaptureWindow(void);
static void hideCaptureWindow(void);

// ---------------------------------------------------------------- shared state

static NSDictionary *gStatus = nil;      // last {v,ts,totals,workspaces,sessions}
static NSString *gRaw = nil;             // raw last status body (debug)
static NSTimeInterval gStatusAt = 0;     // time the last status arrived
// The bridge serves requests on a utility queue while AppKit updates run on the
// main thread, so the status snapshot is read and written from two threads.
// Without this lock a handler can message a dictionary that applyStatus just
// released — that crashed the companion on 2026-11-11 (SIGSEGV in dictAt).
static NSObject *gStatusLock = nil;

static BOOL dshRunning(void);
static NSDictionary *currentStatus(void) {
  @synchronized(gStatusLock) { return gStatus; }
}

static void storeStatus(NSDictionary *status) {
  @synchronized(gStatusLock) { gStatus = status; }
}

static NSTimeInterval currentStatusAt(void) {
  @synchronized(gStatusLock) { return gStatusAt; }
}

static void storeStatusAt(NSTimeInterval at) {
  @synchronized(gStatusLock) { gStatusAt = at; }
}

static NSString *currentRaw(void) {
  @synchronized(gStatusLock) { return gRaw; }
}

static void storeRaw(NSString *raw) {
  @synchronized(gStatusLock) { gRaw = raw; }
}

static BOOL statusUsable(void) {
  if (currentStatus() == nil) return NO;
  if (([NSDate timeIntervalSinceReferenceDate] - currentStatusAt()) < kStaleAfter) return YES;
  return dshRunning();
}
static NSStatusItem *gItem = nil;
static NSString *gChip = @"";
static BOOL gListening = NO;

// native capture window + the durable task queue it feeds
@class CaptureController;
static CaptureController *gCapture = nil;
static int gHotkeyRegisterStatus = -999;
static int gHotkeyHandlerStatus = -999;
static int gHotkeyPresses = 0;
static int gHotkeyAltStatus = -999;
static NSString *gHotkeySource = @"carbon";
static NSMutableArray *gQueue = nil;   // [{id,text,workspaceId,state,at}]
static NSObject *gQueueToken = nil;    // guards gQueue and its file
static BOOL gStatusFromDisk = NO;      // status loaded from disk, not live yet
static NSMutableDictionary *gConfig = nil;  // {openOnSend: bool}, persisted
static BOOL configBool(NSString *key, BOOL fallback);
static void saveConfig(void);

static void notifyTaskResult(BOOL ok, NSString *error, NSString *text);
static void showCaptureWindow(void);
static void toggleCaptureWindow(void);

static void postOnMain(dispatch_block_t block) {
  dispatch_async(dispatch_get_main_queue(), block);
}

// ------------------------------------------------------ persisted bridge files

static NSString *supportDir(void) {
  static NSString *dir = nil;
  if (dir == nil) {
    NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    dir = [base stringByAppendingPathComponent:@"DSHStatusBox"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
  }
  return dir;
}

static NSString *statePath(NSString *name) {
  return [supportDir() stringByAppendingPathComponent:name];
}

static void writeJSONFile(NSDictionary *dict, NSString *path) {
  if (dict == nil) return;
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&error];
  if (data == nil) return;
  [data writeToFile:path options:NSDataWritingAtomic error:&error];
  if (error != nil) NSLog(@"dsh-status-box companion: write %@ failed: %@", path.lastPathComponent, error.localizedDescription);
}

static NSDictionary *readJSONFile(NSString *path) {
  NSData *data = [NSData dataWithContentsOfFile:path];
  if (data == nil) return nil;
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  return [json isKindOfClass:[NSDictionary class]] ? (NSDictionary *)json : nil;
}

static BOOL dshRunning(void) {
  for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
    if ([app.bundleIdentifier isEqualToString:@"com.deepseek.dsh"] && !app.terminated) return YES;
  }
  return NO;
}

// ------------------------------------------------------------------- config
// The settings page inside DSH edits this over the local bridge and the menu
// flips it too, so the file is the single source of truth for both sides.

static void loadConfig(void) {
  NSDictionary *saved = readJSONFile(statePath(@"config.json"));
  gConfig = [NSMutableDictionary dictionary];
  gConfig[@"openOnSend"] = @(NO);
  if (saved != nil) {
    for (NSString *key in saved) {
      gConfig[key] = saved[key];
    }
  }
  if (![gConfig[@"openOnSend"] isKindOfClass:[NSNumber class]]) gConfig[@"openOnSend"] = @(NO);
}

static BOOL configBool(NSString *key, BOOL fallback) {
  if (gConfig == nil) return fallback;
  id value = gConfig[key];
  if (![value isKindOfClass:[NSNumber class]]) return fallback;
  return [(NSNumber *)value boolValue];
}

static void saveConfig(void) {
  if (gConfig == nil) return;
  writeJSONFile([gConfig copy], statePath(@"config.json"));
}

// ------------------------------------------------------------- durable queue

static void loadQueue(void) {
  if (gQueueToken == nil) gQueueToken = [[NSObject alloc] init];
  if (gQueue == nil) gQueue = [NSMutableArray array];
  @synchronized(gQueueToken) {
    [gQueue removeAllObjects];
    NSArray *tasks = arrayAt(readJSONFile(statePath(@"queue.json")), @"tasks");
    for (id item in tasks) {
      if (![item isKindOfClass:[NSDictionary class]]) continue;
      NSMutableDictionary *task = [(NSDictionary *)item mutableCopy];
      task[@"state"] = @"pending";
      [gQueue addObject:task];
    }
  }
}

static void saveQueueLocked(void) {
  writeJSONFile(@{ @"tasks": [gQueue copy] ?: @[] }, statePath(@"queue.json"));
}

static NSDictionary *enqueueTask(NSString *workspaceId, NSString *text) {
  NSMutableDictionary *task = [NSMutableDictionary dictionary];
  task[@"id"] = [[NSUUID UUID] UUIDString];
  task[@"text"] = text;
  if (workspaceId.length > 0) task[@"workspaceId"] = workspaceId;
  task[@"state"] = @"pending";
  task[@"at"] = @([[NSDate date] timeIntervalSince1970]);
  // snapshot the preference now: flipping it later must not move an old task
  task[@"open"] = @(configBool(@"openOnSend", NO));
  @synchronized(gQueueToken) {
    [gQueue addObject:task];
    saveQueueLocked();
  }
  NSLog(@"dsh-status-box companion: task queued");
  return task;
}

static NSArray *takePendingTasks(void) {
  NSMutableArray *out = [NSMutableArray array];
  @synchronized(gQueueToken) {
    if (gQueue == nil) gQueue = [NSMutableArray array];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    for (NSMutableDictionary *task in gQueue) {
      NSString *state = task[@"state"];
      NSTimeInterval at = [task[@"at"] doubleValue];
      BOOL retry = (now - at) > 45.0;
      if (![state isEqualToString:@"pending"] && !retry) continue;
      task[@"state"] = @"inflight";
      task[@"at"] = @(now);
      NSMutableDictionary *wire = [NSMutableDictionary dictionary];
      wire[@"id"] = task[@"id"];
      wire[@"text"] = task[@"text"];
      wire[@"workspaceId"] = task[@"workspaceId"] ?: @"";
      wire[@"open"] = task[@"open"] ?: @NO;
      [out addObject:wire];
    }
    if (out.count > 0) saveQueueLocked();
  }
  return out;
}

static void ackTask(NSString *taskId, BOOL ok, NSString *error) {
  NSString *text = nil;
  @synchronized(gQueueToken) {
    for (NSInteger index = 0; index < (NSInteger)gQueue.count; index += 1) {
      if ([gQueue[(NSUInteger)index][@"id"] isEqual:taskId]) {
        text = gQueue[(NSUInteger)index][@"text"];
        [gQueue removeObjectAtIndex:(NSUInteger)index];
        break;
      }
    }
    saveQueueLocked();
  }
  if (ok) NSLog(@"dsh-status-box companion: task delivered");
  else NSLog(@"dsh-status-box companion: task failed: %@", error.length > 0 ? error : @"unknown");
  notifyTaskResult(ok, error, text);
}

// --------------------------------------------------------------------- helpers

static NSNumber *numOr(NSDictionary *dict, NSString *key, double fallback) {
  if (dict == nil) return @(fallback);
  id value = dict[key];
  if ([value isKindOfClass:[NSNumber class]]) return value;
  return @(fallback);
}

static id dictAt(NSDictionary *dict, NSString *key) {
  if (dict == nil) return nil;
  id value = dict[key];
  return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSArray *arrayAt(NSDictionary *dict, NSString *key) {
  if (dict == nil) return @[];
  id value = dict[key];
  return [value isKindOfClass:[NSArray class]] ? value : @[];
}

/**
 * Open DSH via its own protocol handler. The shell handles `dsh://open` by
 * restoring a minimized window, showing it and focusing it.
 */
static void openDsh(void) {
  // 1) the app's own dsh://open handler restores a minimized window and focuses it
  NSURL *url = [NSURL URLWithString:@"dsh://open"];
  if (url != nil) [[NSWorkspace sharedWorkspace] openURL:url];

  // 2) `open -a` goes through Launch Services, which is allowed to bring a
  //    background app forward (and switch Spaces) where -activate often is not.
  NSURL *bundle = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.deepseek.dsh"];
  if (bundle == nil) bundle = [NSURL fileURLWithPath:@"/Applications/DeepSeek Harness.app"];
  if (bundle != nil) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = @[ @"-a", bundle.path ];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
      NSLog(@"dsh-status-box companion: could not activate DSH: %@", error);
    }
  }
}

static void summonDock(void) {
  // Decoupled from DSH: the hotkey toggles our own floating window, so it works
  // even when DSH is closed (tasks are queued and delivered on next launch).
  // Press once to summon, press again to hide.
  toggleCaptureWindow();
}

// --------------------------------------------------------------- status -> UI

static void refreshTitle(void);

static void applyStatus(NSDictionary *status) {
  storeStatus(status);
  storeStatusAt([NSDate timeIntervalSinceReferenceDate]);
  gStatusFromDisk = NO;
  writeJSONFile(status, statePath(@"status.json"));
  refreshTitle();
  refreshCaptureWindow();
}

// ------------------------------------------------------------ menu bar icon

/**
 * WeChat-like silhouette: a rounded speech bubble with a small tail and two
 * task rows inside. Drawn as a template image so macOS tints it for light and
 * dark menu bars.
 */
static CGImageRef gWhaleMask = NULL;

// The DeepSeek whale mark, tinted with the current state colour. The bundled
// PNG is a pure alpha mask (black pixels, alpha = shape), so the silhouette can
// be painted in any colour and still reads correctly in light and dark menu
// bars. Clipping to the mask in Core Graphics gives clean edges; compositing the
// PNG directly left a faint box around the glyph.
static CGImageRef whaleMask(void) {
  if (gWhaleMask != NULL) return gWhaleMask;
  NSString *path = [[NSBundle mainBundle] pathForResource:@"whale" ofType:@"png"];
  if (path == nil) {
    NSString *exe = [[NSBundle mainBundle] executablePath];
    path = [[exe stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"../Resources/whale.png"];
  }
  if (path == nil) return NULL;
  NSURL *url = [NSURL fileURLWithPath:[path stringByStandardizingPath]];
  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
  if (source == NULL) return NULL;
  gWhaleMask = CGImageSourceCreateImageAtIndex(source, 0, NULL);
  CFRelease(source);
  return gWhaleMask;
}

static NSImage *tintedWhaleIcon(NSColor *color) {
  CGImageRef mask = whaleMask();
  if (mask == NULL) return nil;

  const CGFloat scale = 2.0;
  size_t width = (size_t)(20.0 * scale);
  size_t height = (size_t)(20.0 * scale);
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                               kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(space);
  if (context == NULL) return nil;

  CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
  // whale mask is 217x160 (aspect 1.357): keep it undistorted inside 19x19pt
  CGRect box = CGRectMake(0.0, 2.6 * scale, 20.0 * scale, 14.8 * scale);
  CGContextClipToMask(context, box, mask);
  CGContextSetFillColorWithColor(context, color.CGColor);
  CGContextFillRect(context, box);

  CGImageRef rendered = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  if (rendered == NULL) return nil;
  NSImage *image = [[NSImage alloc] initWithCGImage:rendered size:NSMakeSize(20, 20)];
  CGImageRelease(rendered);
  return image;
}

static NSImage *statusBarIcon(NSColor *color) {
  NSImage *whale = tintedWhaleIcon(color);
  if (whale != nil) return whale;
  // 20x20 with a filled speech bubble; the task rows are punched out of the
  // fill so they show through as menu-bar background (bold, WeChat-like weight).
  CGFloat side = 20.0;
  NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(side, side)];
  [image lockFocus];

  [color setFill];

  NSBezierPath *tail = [NSBezierPath bezierPath];
  [tail moveToPoint:NSMakePoint(7.8, 3.9)];
  [tail lineToPoint:NSMakePoint(5.6, 0.6)];
  [tail lineToPoint:NSMakePoint(11.6, 4.1)];
  [tail closePath];
  [tail fill];

  NSBezierPath *bubble = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0.7, 2.7, 18.6, 16.4)
                                                        xRadius:5.0
                                                        yRadius:5.0];
  [bubble fill];

  // punch out the two task rows
  [NSGraphicsContext saveGraphicsState];
  [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositingOperationClear];
  [[NSColor clearColor] setFill];

  NSBezierPath *dot1 = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(4.5, 12.1, 2.5, 2.5)];
  [dot1 fill];
  NSBezierPath *row1 = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(8.4, 12.3, 7.0, 2.1)
                                                      xRadius:1.05
                                                      yRadius:1.05];
  [row1 fill];

  NSBezierPath *dot2 = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(4.5, 6.8, 2.5, 2.5)];
  [dot2 fill];
  NSBezierPath *row2 = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(8.4, 7.0, 4.8, 2.1)
                                                      xRadius:1.05
                                                      yRadius:1.05];
  [row2 fill];

  [NSGraphicsContext restoreGraphicsState];

  [image unlockFocus];
  return image;
}

static void refreshTitle(void) {
  if (gItem == nil) return;
  NSStatusBarButton *button = gItem.button;
  button.imagePosition = NSImageLeading;
  button.imageScaling = NSImageScaleProportionallyDown;

  BOOL live = statusUsable();
  NSInteger waiting = 0;
  NSInteger running = 0;
  NSInteger done = 0;
  if (live) {
    NSDictionary *totals = dictAt(currentStatus(), @"totals");
    waiting = [numOr(totals, @"waiting", 0) integerValue];
    running = [numOr(totals, @"running", 0) integerValue];
    done = [numOr(totals, @"done", 0) integerValue];
  }

  // the glyph itself carries the state colour (WeChat-style coloured bubble)
  NSString *text = @"";
  NSColor *color = [NSColor labelColor];
  if (!live) {
    color = [NSColor secondaryLabelColor];
  } else if (waiting > 0) {
    text = [NSString stringWithFormat:@" %ld", (long)waiting];
    color = [NSColor systemOrangeColor];
  } else if (running > 0) {
    text = [NSString stringWithFormat:@" %ld", (long)running];
    color = [NSColor systemGreenColor];
  } else if (done > 0) {
    text = [NSString stringWithFormat:@" %ld", (long)done];
    color = [NSColor systemBlueColor];
  }
  button.image = statusBarIcon(color);
  button.attributedTitle = [[NSAttributedString alloc] initWithString:text
                                                          attributes:@{
                                                            NSForegroundColorAttributeName : color,
                                                            NSFontAttributeName : [NSFont systemFontOfSize:12
                                                                                                   weight:NSFontWeightSemibold],
                                                          }];

  NSMutableArray<NSString *> *tips = [NSMutableArray array];
  if (!live) {
    [tips addObject:@"未连接（新建任务仍可用，会排队）"];
  } else {
    if (!(currentStatus() != nil && ([NSDate timeIntervalSinceReferenceDate] - currentStatusAt()) < kStaleAfter)) {
      [tips addObject:@"状态为最后已知值（DSH 在运行）"];
    }
    if (waiting > 0) [tips addObject:[NSString stringWithFormat:@"%ld 个任务等你处理", (long)waiting]];
    if (running > 0) [tips addObject:[NSString stringWithFormat:@"%ld 个任务运行中", (long)running]];
    if (waiting == 0 && running == 0) {
      [tips addObject:done > 0 ? [NSString stringWithFormat:@"%ld 个已完成", (long)done] : @"空闲"];
    }
  }
  [tips addObject:@"点击查看 · ⌥⌘⇧D 新建任务"];
  button.toolTip = [@"DSH 状态盒：" stringByAppendingString:[tips componentsJoinedByString:@" · "]];
}

// ------------------------------------------------------ native capture window
//
// Spotlight-like: a borderless rounded field, nothing else. The chosen
// workspace lives in the placeholder (Tab cycles it), Enter sends, Esc closes,
// clicking anywhere else closes too.

@interface CaptureWindow : NSPanel
@end

@implementation CaptureWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface CaptureController : NSObject <NSWindowDelegate, NSTextFieldDelegate>
- (void)showWindow;
- (void)hideWindow;
- (void)refreshFromStatus;
- (void)flashResult:(BOOL)ok error:(NSString *)error;
- (void)presentResult:(BOOL)ok error:(NSString *)error text:(NSString *)text;
@end

@implementation CaptureController {
  CaptureWindow *_window;
  NSVisualEffectView *_backdrop;
  NSImageView *_glyph;
  NSTextField *_field;
  NSTextField *_hint;
  NSMutableArray<NSDictionary *> *_workspaces;
  NSString *_targetWorkspaceId;
  NSTimeInterval _shownAt;
}

- (instancetype)init {
  self = [super init];
  if (self == nil) return nil;

  _workspaces = [NSMutableArray array];
  _targetWorkspaceId = [[NSUserDefaults standardUserDefaults] stringForKey:@"targetWorkspaceId"] ?: @"";

  _window = [[CaptureWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 560, 58)
                styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                  backing:NSBackingStoreBuffered
                    defer:NO];
  _window.backgroundColor = [NSColor clearColor];
  _window.opaque = NO;
  _window.hasShadow = YES;
  _window.movableByWindowBackground = YES;
  _window.level = NSPopUpMenuWindowLevel;
  _window.floatingPanel = YES;
  _window.hidesOnDeactivate = NO;
  _window.releasedWhenClosed = NO;
  _window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorStationary;
  _window.delegate = self;

  NSView *content = _window.contentView;

  _backdrop = [[NSVisualEffectView alloc] initWithFrame:content.bounds];
  _backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _backdrop.material = NSVisualEffectMaterialHUDWindow;
  _backdrop.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  _backdrop.state = NSVisualEffectStateActive;
  _backdrop.wantsLayer = YES;
  _backdrop.layer.cornerRadius = 14.0;
  _backdrop.layer.masksToBounds = YES;
  [content addSubview:_backdrop];

  _glyph = [[NSImageView alloc] initWithFrame:NSZeroRect];
  _glyph.translatesAutoresizingMaskIntoConstraints = NO;
  NSImage *symbol = [NSImage imageWithSystemSymbolName:@"square.and.pencil" accessibilityDescription:nil];
  if (symbol != nil) {
    _glyph.image = [symbol imageWithSymbolConfiguration:
                                [NSImageSymbolConfiguration configurationWithPointSize:15
                                                                               weight:NSFontWeightMedium]];
    _glyph.contentTintColor = [NSColor secondaryLabelColor];
  }
  [_backdrop addSubview:_glyph];

  _field = [[NSTextField alloc] initWithFrame:NSZeroRect];
  _field.translatesAutoresizingMaskIntoConstraints = NO;
  _field.bordered = NO;
  _field.drawsBackground = NO;
  _field.focusRingType = NSFocusRingTypeNone;
  _field.font = [NSFont systemFontOfSize:16 weight:NSFontWeightRegular];
  _field.textColor = [NSColor labelColor];
  _field.placeholderString = @"输入任务，按 Enter 发起…";
  _field.delegate = self;
  _field.usesSingleLineMode = YES;
  [_backdrop addSubview:_field];

  _hint = [NSTextField labelWithString:@"↵"];
  _hint.translatesAutoresizingMaskIntoConstraints = NO;
  _hint.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
  _hint.textColor = [NSColor tertiaryLabelColor];
  [_backdrop addSubview:_hint];

  [NSLayoutConstraint activateConstraints:@[
    [_glyph.leadingAnchor constraintEqualToAnchor:_backdrop.leadingAnchor constant:18],
    [_glyph.centerYAnchor constraintEqualToAnchor:_backdrop.centerYAnchor],
    [_glyph.widthAnchor constraintEqualToConstant:18],
    [_glyph.heightAnchor constraintEqualToConstant:18],
    [_field.leadingAnchor constraintEqualToAnchor:_glyph.trailingAnchor constant:12],
    [_field.centerYAnchor constraintEqualToAnchor:_backdrop.centerYAnchor],
    [_field.trailingAnchor constraintEqualToAnchor:_hint.leadingAnchor constant:-12],
    [_hint.trailingAnchor constraintEqualToAnchor:_backdrop.trailingAnchor constant:-18],
    [_hint.centerYAnchor constraintEqualToAnchor:_backdrop.centerYAnchor],
  ]];

  return self;
}

- (void)refreshFromStatus {
  [_workspaces removeAllObjects];
  for (id item in arrayAt(currentStatus(), @"workspaces")) {
    if (![item isKindOfClass:[NSDictionary class]]) continue;
    NSString *identifier = ((NSDictionary *)item)[@"id"];
    NSString *title = ((NSDictionary *)item)[@"title"];
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) continue;
    if (![title isKindOfClass:[NSString class]] || title.length == 0) title = @"默认工作区";
    [_workspaces addObject:@{ @"id" : identifier, @"title" : title }];
  }
  BOOL found = NO;
  for (NSDictionary *workspace in _workspaces) {
    if ([workspace[@"id"] isEqualToString:_targetWorkspaceId]) {
      found = YES;
      break;
    }
  }
  if (!found) {
    _targetWorkspaceId = _workspaces.count > 0 ? _workspaces[0][@"id"] : @"";
    [[NSUserDefaults standardUserDefaults] setObject:_targetWorkspaceId forKey:@"targetWorkspaceId"];
  }
  [self updatePlaceholder];
}

- (NSString *)targetTitle {
  for (NSDictionary *workspace in _workspaces) {
    if ([workspace[@"id"] isEqualToString:_targetWorkspaceId]) return workspace[@"title"];
  }
  return nil;
}

- (void)updatePlaceholder {
  NSString *title = [self targetTitle];
  if (title != nil) {
    _field.placeholderString = [NSString stringWithFormat:@"发到「%@」：输入任务，按 Enter 发起…", title];
    return;
  }
  BOOL live = statusUsable();
  if (!live && !dshRunning()) {
    _field.placeholderString = @"DSH 未运行：输入任务，启动后自动发出…";
  } else {
    _field.placeholderString = @"输入任务，按 Enter 发起…";
  }
}

- (void)showWindow {
  [self refreshFromStatus];
  _field.stringValue = @"";
  _field.textColor = [NSColor labelColor];
  [self updatePlaceholder];

  // appear on the display that holds the pointer, not always the main screen
  NSScreen *screen = [NSScreen mainScreen];
  NSPoint pointer = [NSEvent mouseLocation];
  for (NSScreen *candidate in [NSScreen screens]) {
    if (NSPointInRect(pointer, candidate.frame)) {
      screen = candidate;
      break;
    }
  }
  NSRect visible = screen.visibleFrame;
  NSRect frame = _window.frame;
  frame.origin = NSMakePoint(round(NSMidX(visible) - frame.size.width / 2.0),
                             round(NSMaxY(visible) - frame.size.height - NSHeight(visible) * 0.24));
  [_window setFrame:frame display:YES];

  _shownAt = [NSDate timeIntervalSinceReferenceDate];
  _window.becomesKeyOnlyIfNeeded = NO;
  [_window orderFrontRegardless];
  [NSApp activateIgnoringOtherApps:YES];
  [_window makeKeyAndOrderFront:nil];
  [_window makeFirstResponder:_field];
  __weak CaptureController *weakWindow = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   CaptureController *strongSelf = weakWindow;
                   if (strongSelf == nil) return;
                   if (!strongSelf->_window.isVisible) return;
                   [strongSelf->_window makeKeyWindow];
                   [strongSelf->_window makeFirstResponder:strongSelf->_field];
                 });


}

- (void)hideWindow {
  [_window orderOut:nil];
}

- (void)windowDidResignKey:(NSNotification *)notification {
  (void)notification;
  // A non-activating panel briefly loses key status while the app activates,
  // so ignore resignations right after showing; a later one means the user
  // clicked into another app (Spotlight-like dismissal).
  if ([NSDate timeIntervalSinceReferenceDate] - _shownAt < 0.6) return;
  __weak CaptureController *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   CaptureController *strongSelf = weakSelf;
                   if (strongSelf == nil) return;
                   if (strongSelf->_window.isVisible && !strongSelf->_window.isKeyWindow) {
                     [strongSelf hideWindow];
                   }
                 });
}

- (void)cycleWorkspaceBy:(NSInteger)step {
  if (_workspaces.count == 0) return;
  NSInteger index = 0;
  for (NSInteger i = 0; i < (NSInteger)_workspaces.count; i += 1) {
    if ([_workspaces[(NSUInteger)i][@"id"] isEqualToString:_targetWorkspaceId]) {
      index = i;
      break;
    }
  }
  NSInteger count = (NSInteger)_workspaces.count;
  index = (index + step % count + count) % count;
  _targetWorkspaceId = _workspaces[(NSUInteger)index][@"id"];
  [[NSUserDefaults standardUserDefaults] setObject:_targetWorkspaceId forKey:@"targetWorkspaceId"];
  [self updatePlaceholder];
}

- (void)submit {
  NSString *text = [_field.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (text.length == 0) {
    NSBeep();
    return;
  }
  BOOL openAfterSend = configBool(@"openOnSend", NO);
  enqueueTask(_targetWorkspaceId ?: @"", text);
  BOOL running = dshRunning();
  [self hideWindow];
  // "open the conversation" brings DSH forward either way; the client half then
  // navigates to the session it just created. Without the preference we only
  // launch DSH when it is closed and leave the user where they were.
  if (!running || openAfterSend) openDsh();
}

- (void)flashResult:(BOOL)ok error:(NSString *)error {
  [self presentResult:ok error:error text:nil];
}

/**
 * Delivery result for a task typed in this window. The window is hidden right
 * after submitting, so a failure has to come back into view: re-open it with
 * the original text, focus the field and say what went wrong, otherwise the
 * user never learns that the task did not start.
 */
- (void)presentResult:(BOOL)ok error:(NSString *)error text:(NSString *)text {
  if (ok) {
    NSLog(@"dsh-status-box companion: task delivered");
    return;
  }
  NSLog(@"dsh-status-box companion: task failed: %@", error.length > 0 ? error : @"unknown");
  if (text.length > 0) {
    [self showWindow];
    _field.stringValue = text;
    _field.textColor = [NSColor labelColor];
    [_window makeFirstResponder:_field];
    [_field selectText:nil];
  } else if (!_window.isVisible) {
    [self showWindow];
  }
  // The field holds the retry text, so the placeholder cannot carry the reason:
  // show it where the return hint usually lives and tint the glyph red.
  _glyph.contentTintColor = [NSColor systemRedColor];
  _hint.stringValue = [NSString stringWithFormat:@"发送失败（%@）", error.length > 0 ? error : @"未知错误"];
  _hint.textColor = [NSColor systemRedColor];
  NSBeep();

  __weak CaptureController *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   CaptureController *strongSelf = weakSelf;
                   if (strongSelf == nil) return;
                   strongSelf->_glyph.contentTintColor = [NSColor secondaryLabelColor];
                   strongSelf->_hint.stringValue = @"↵";
                   strongSelf->_hint.textColor = [NSColor tertiaryLabelColor];
                 });
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
  (void)control;
  (void)textView;
  if (commandSelector == @selector(insertNewline:)) {
    [self submit];
    return YES;
  }
  if (commandSelector == @selector(cancelOperation:)) {
    [self hideWindow];
    return YES;
  }
  if (commandSelector == @selector(insertTab:)) {
    [self cycleWorkspaceBy:1];
    return YES;
  }
  if (commandSelector == @selector(insertBacktab:)) {
    [self cycleWorkspaceBy:-1];
    return YES;
  }
  return NO;
}

- (void)toggleWindow {
  if (_window.isVisible) {
    [self hideWindow];
    return;
  }
  [self showWindow];
}

- (NSString *)stateJSON {
  NSString *text = [_field.stringValue stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
  return [NSString stringWithFormat:
      @"{\"visible\":%d,\"key\":%d,\"appActive\":%d,\"field\":\"%@\",\"target\":\"%@\"}",
      _window.isVisible ? 1 : 0, _window.isKeyWindow ? 1 : 0, [NSApp isActive] ? 1 : 0,
      text ?: @"", _targetWorkspaceId ?: @""];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
  (void)sender;
  [self hideWindow];
  return NO;
}

@end

static void showCaptureWindow(void) {
  if (gCapture == nil) {
    gCapture = [[CaptureController alloc] init];
  }
  [gCapture showWindow];
}

static void toggleCaptureWindow(void) {
  if (gCapture == nil) {
    gCapture = [[CaptureController alloc] init];
  }
  [gCapture toggleWindow];
}

static void hideCaptureWindow(void) {
  if (gCapture == nil) return;
  [gCapture hideWindow];
}

static void notifyTaskResult(BOOL ok, NSString *error, NSString *text) {
  postOnMain(^{
    [gCapture presentResult:ok error:error text:text];
  });
}

static void refreshCaptureWindow(void) {
  if (gCapture == nil) return;
  [gCapture refreshFromStatus];
}

static NSString *capturePanelStateJSON(void) {
  if (gCapture == nil) return @"{\"visible\":0}";
  return [gCapture stateJSON];
}

// ------------------------------------------------------------------ the menu

static void ring(void) {
  NSSound *sound = [NSSound soundNamed:@"Ping"];
  if (sound != nil) [sound play];
}

@interface DockMenu : NSObject <NSMenuDelegate>
@end

@implementation DockMenu

- (void)menuNeedsUpdate:(NSMenu *)menu {
  [menu removeAllItems];

  BOOL live = statusUsable();
  if (!live) {
    NSMenuItem *item = [menu addItemWithTitle:@"未连接：打开 DSH 后自动同步状态" action:nil keyEquivalent:@""];
    item.enabled = NO;
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *open = [menu addItemWithTitle:@"打开 DSH" action:@selector(actionOpen) keyEquivalent:@""];
    open.target = self;
    NSMenuItem *quit = [menu addItemWithTitle:@"退出状态助手" action:@selector(actionQuit) keyEquivalent:@""];
    quit.target = self;
    return;
  }

  NSDictionary *totals = dictAt(currentStatus(), @"totals");
  NSInteger waiting = [numOr(totals, @"waiting", 0) integerValue];
  NSInteger running = [numOr(totals, @"running", 0) integerValue];
  NSInteger done = [numOr(totals, @"done", 0) integerValue];

  if (waiting > 0) {
    NSMenuItem *item = [menu addItemWithTitle:[NSString stringWithFormat:@"◉ %@ 个任务等你处理", @(waiting)]
                                      action:@selector(actionSummon)
                               keyEquivalent:@""];
    item.target = self;
    item.attributedTitle = [[NSAttributedString alloc]
                            initWithString:[NSString stringWithFormat:@"◉ %@ 个任务等你处理", @(waiting)]
                                attributes:@{
                                  NSForegroundColorAttributeName : [NSColor systemOrangeColor],
                                  NSFontAttributeName : [NSFont boldSystemFontOfSize:13],
                                }];
  }

  NSMutableArray<NSString *> *summary = [NSMutableArray array];
  if (running > 0) [summary addObject:[NSString stringWithFormat:@"● %@ 运行中", @(running)]];
  if (done > 0) [summary addObject:[NSString stringWithFormat:@"✓ %@ 已完成", @(done)]];
  if (summary.count == 0) [summary addObject:@"○ 全部空闲"];
  NSMenuItem *head = [menu addItemWithTitle:[summary componentsJoinedByString:@"   "] action:nil keyEquivalent:@""];
  head.enabled = NO;

  NSArray *workspaces = arrayAt(currentStatus(), @"workspaces");
  if (workspaces.count > 0) {
    [menu addItem:[NSMenuItem separatorItem]];
    for (NSDictionary *workspace in workspaces) {
      if (![workspace isKindOfClass:[NSDictionary class]]) continue;
      NSInteger wWaiting = [numOr(workspace, @"waiting", 0) integerValue];
      NSInteger wRunning = [numOr(workspace, @"running", 0) integerValue];
      if (wWaiting == 0 && wRunning == 0) continue;
      NSString *name = workspace[@"title"];
      if (![name isKindOfClass:[NSString class]] || name.length == 0) name = @"未分组";
      NSMutableArray *bits = [NSMutableArray array];
      if (wWaiting > 0) [bits addObject:[NSString stringWithFormat:@"%@ 待", @(wWaiting)]];
      if (wRunning > 0) [bits addObject:[NSString stringWithFormat:@"%@ 运行", @(wRunning)]];
      NSString *line = [NSString stringWithFormat:@"   %@ · %@", name, [bits componentsJoinedByString:@" · "]];
      NSMenuItem *item = [menu addItemWithTitle:line action:@selector(actionOpen) keyEquivalent:@""];
      item.target = self;
    }
  }

  NSArray *sessions = arrayAt(currentStatus(), @"sessions");
  if (sessions.count > 0) {
    [menu addItem:[NSMenuItem separatorItem]];
    NSInteger shown = 0;
    for (NSDictionary *session in sessions) {
      if (![session isKindOfClass:[NSDictionary class]]) continue;
      NSString *title = session[@"title"];
      if (![title isKindOfClass:[NSString class]] || title.length == 0) title = @"未命名会话";
      NSString *state = session[@"state"];
      NSString *dot = @"●";
      NSColor *color = [NSColor systemGreenColor];
      if ([state isEqualToString:@"waiting"]) {
        dot = @"◉";
        color = [NSColor systemOrangeColor];
      } else if ([state isEqualToString:@"done"]) {
        dot = @"✓";
        color = [NSColor secondaryLabelColor];
      }
      if (title.length > 42) title = [[title substringToIndex:41] stringByAppendingString:@"…"];
      NSMenuItem *item = [menu addItemWithTitle:[NSString stringWithFormat:@"%@ %@", dot, title]
                                         action:@selector(actionOpen)
                                  keyEquivalent:@""];
      item.target = self;
      item.attributedTitle = [[NSAttributedString alloc]
                              initWithString:[NSString stringWithFormat:@"%@ %@", dot, title]
                                  attributes:@{
                                    NSForegroundColorAttributeName : color,
                                    NSFontAttributeName : [NSFont systemFontOfSize:12],
                                  }];
      shown += 1;
      if (shown >= 8) break;
    }
  }

  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *summon = [menu addItemWithTitle:@"新建任务…  ⌥⌘⇧D" action:@selector(actionSummon) keyEquivalent:@""];
  summon.target = self;
  NSMenuItem *open = [menu addItemWithTitle:@"打开 DSH" action:@selector(actionOpen) keyEquivalent:@""];
  open.target = self;
  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *quit = [menu addItemWithTitle:@"退出状态助手" action:@selector(actionQuit) keyEquivalent:@""];
  quit.target = self;
}

- (void)actionOpen { openDsh(); }
- (void)actionSummon { showCaptureWindow(); }
- (void)actionQuit { [NSApp terminate:nil]; }
@end

static DockMenu *gMenu = nil;

// Debug-only: the item titles the status menu currently shows, so tests can
// assert what the user actually gets without driving the UI.
static NSString *menuTitlesJSON(void) {
  NSMenu *menu = gItem.menu;
  if (menu == nil || gMenu == nil) return @"{\"items\":[]}";
  // Build the menu the way opening it would, so the titles reflect reality.
  [gMenu menuNeedsUpdate:menu];
  NSMutableArray *titles = [NSMutableArray array];
  for (NSMenuItem *item in menu.itemArray) {
    if (item.isSeparatorItem) continue;
    [titles addObject:item.title ?: @""];
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{ @"items": titles } options:0 error:NULL];
  return data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

// ------------------------------------------------------------- local HTTP server

static void respond(int client, int code, const char *body) {
  const char *reason = "Not Found";
  if (code == 200) reason = "OK";
  else if (code == 204) reason = "No Content";
  else if (code == 403) reason = "Forbidden";
  NSMutableString *head = [NSMutableString string];
  [head appendFormat:@"HTTP/1.1 %d %s\r\n", code, reason];
  [head appendString:@"Content-Type: application/json; charset=utf-8\r\n"];
  if (tBridgeAllowedOrigin[0] != '\0') {
    [head appendFormat:@"Access-Control-Allow-Origin: %s\r\n", tBridgeAllowedOrigin];
    [head appendString:@"Vary: Origin\r\n"];
  }
  [head appendString:@"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"];
  [head appendString:@"Access-Control-Allow-Headers: Content-Type, Access-Control-Request-Private-Network\r\n"];
  // Chrome's Private Network Access: a page in a "less private" address space
  // (e.g. the dsh-app:// shell) must get this header on the preflight, or the
  // request to 127.0.0.1 is blocked before it is ever sent.
  [head appendString:@"Access-Control-Allow-Private-Network: true\r\n"];
  [head appendString:@"Cache-Control: no-store\r\n"];
  if (code == 204) {
    [head appendString:@"Content-Length: 0\r\n"];
  } else {
    [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)strlen(body)];
  }
  [head appendString:@"Connection: close\r\n\r\n"];
  NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
  send(client, headData.bytes, headData.length, 0);
  if (code != 204 && body != NULL) send(client, body, strlen(body), 0);
}

static void handleClient(int client) {
  struct timeval tv = {2, 0};
  setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

  NSMutableData *request = [NSMutableData data];
  uint8_t buffer[4096];
  NSInteger headerEnd = -1;
  NSInteger contentLength = 0;
  ssize_t got = 0;

  while ((got = recv(client, buffer, sizeof(buffer), 0)) > 0) {
    [request appendBytes:buffer length:(NSUInteger)got];
    if (headerEnd < 0) {
      NSRange range = [request rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                                   options:0
                                     range:NSMakeRange(0, request.length)];
      if (range.location != NSNotFound) {
        headerEnd = (NSInteger)(range.location + range.length);
        NSString *head = [[NSString alloc] initWithData:[request subdataWithRange:NSMakeRange(0, (NSUInteger)headerEnd)]
                                               encoding:NSUTF8StringEncoding];
        NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
        for (NSString *line in lines) {
          NSString *lower = [line lowercaseString];
          if ([lower hasPrefix:@"content-length:"]) {
            contentLength = [[line substringFromIndex:15] integerValue];
          }
        }
      }
    }
    if (headerEnd >= 0 && (NSInteger)request.length >= headerEnd + contentLength) break;
    if (request.length > 1024 * 1024) break; // sanity cap
  }

  if (request.length == 0) {
    close(client);
    return;
  }

  NSString *head = [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding];
  if (head == nil) {
    respond(client, 404, "{\"ok\":false}");
    close(client);
    return;
  }
  NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
  NSString *requestLine = lines.count > 0 ? lines[0] : @"";
  NSArray<NSString *> *parts = [requestLine componentsSeparatedByString:@" "];
  NSString *method = parts.count > 0 ? parts[0] : @"GET";
  NSString *path = parts.count > 1 ? parts[1] : @"/";
  NSRange query = [path rangeOfString:@"?"];
  if (query.location != NSNotFound) path = [path substringToIndex:query.location];

  tBridgeAllowedOrigin[0] = '\0';
  NSString *origin = nil;
  for (NSString *line in lines) {
    if ([[line lowercaseString] hasPrefix:@"origin:"]) {
      origin = [[line substringFromIndex:7] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      break;
    }
  }
  if (!bridgeOriginAllowed(origin)) {
    NSLog(@"dsh-status-box companion: rejected origin %@", origin);
    respond(client, 403, "{\"ok\":false,\"error\":\"origin\"}");
    close(client);
    return;
  }
  if (origin.length > 0) {
    strlcpy(tBridgeAllowedOrigin, origin.UTF8String, sizeof(tBridgeAllowedOrigin));
  }

  NSLog(@"dsh-status-box companion: %@ %@", method, path);

  NSData *body = nil;
  if (headerEnd >= 0 && contentLength > 0 && (NSInteger)request.length >= headerEnd + contentLength) {
    body = [request subdataWithRange:NSMakeRange((NSUInteger)headerEnd, (NSUInteger)contentLength)];
  }

  if ([method isEqualToString:@"OPTIONS"]) {
    respond(client, 204, NULL);
  } else if ([path isEqualToString:@"/nudge"] && ([method isEqualToString:@"POST"] || [method isEqualToString:@"GET"])) {
    // kept for scripts: same as /summon, never touches the DSH window
    postOnMain(^{
      summonDock();
    });
    respond(client, 200, "{\"ok\":true}");
  } else if (([path isEqualToString:@"/summon"] && [method isEqualToString:@"POST"]) ||
             ([path isEqualToString:@"/summon"] && [method isEqualToString:@"GET"])) {
    postOnMain(^{
      summonDock();
    });
    respond(client, 200, "{\"ok\":true}");
  } else if ([path isEqualToString:@"/task"] && [method isEqualToString:@"POST"]) {
    id json = body.length > 0 ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
    NSString *text = nil;
    NSString *workspaceId = @"";
    if ([json isKindOfClass:[NSDictionary class]]) {
      id rawText = ((NSDictionary *)json)[@"text"];
      if ([rawText isKindOfClass:[NSString class]]) text = rawText;
      id rawWorkspace = ((NSDictionary *)json)[@"workspaceId"];
      if ([rawWorkspace isKindOfClass:[NSString class]]) workspaceId = rawWorkspace;
    }
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) {
      respond(client, 200, "{\"ok\":false,\"error\":\"empty\"}");
    } else {
      NSDictionary *task = enqueueTask(workspaceId, text);
      if (!dshRunning()) {
        dispatch_async(dispatch_get_main_queue(), ^{
          openDsh();
        });
      }
      NSString *reply = [NSString stringWithFormat:@"{\"ok\":true,\"id\":\"%@\"}", task[@"id"]];
      respond(client, 200, reply.UTF8String);
    }
  } else if ([path isEqualToString:@"/command/ack"] && [method isEqualToString:@"POST"]) {
    id json = body.length > 0 ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
      respond(client, 404, "{\"ok\":false}");
    } else {
      NSString *taskId = ((NSDictionary *)json)[@"id"];
      id rawOk = ((NSDictionary *)json)[@"ok"];
      id rawError = ((NSDictionary *)json)[@"error"];
      if (![taskId isKindOfClass:[NSString class]]) {
        respond(client, 200, "{\"ok\":false}");
      } else {
        ackTask(taskId, [rawOk boolValue], [rawError isKindOfClass:[NSString class]] ? rawError : @"");
        respond(client, 200, "{\"ok\":true}");
      }
    }
  } else if ([path isEqualToString:@"/status"] && [method isEqualToString:@"POST"]) {
    NSError *error = nil;
    id json = body.length > 0 ? [NSJSONSerialization JSONObjectWithData:body options:0 error:&error] : nil;
    if ([json isKindOfClass:[NSDictionary class]]) {
      NSDictionary *status = (NSDictionary *)json;
      double previousWaiting = 0;
      NSDictionary *previous = currentStatus();
      if (previous != nil) {
        previousWaiting = [numOr(dictAt(previous, @"totals"), @"waiting", 0) doubleValue];
      }
      double nextWaiting = [numOr(dictAt(status, @"totals"), @"waiting", 0) doubleValue];
      storeRaw([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]);
      postOnMain(^{
        applyStatus(status);
        if (nextWaiting > previousWaiting) ring();
      });
      respond(client, 200, "{\"ok\":true}");
    } else {
      respond(client, 404, "{\"ok\":false}");
    }
  } else if ([path isEqualToString:@"/command"] && [method isEqualToString:@"GET"]) {
    NSArray *tasks = takePendingTasks();
    NSDictionary *reply = @{ @"tasks": tasks };
    NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL];
    if (data == nil) {
      respond(client, 200, "{\"tasks\":[]}");
    } else {
      char *copy = strndup(data.bytes, data.length);
      respond(client, 200, copy);
      free(copy);
    }
  } else if ([path isEqualToString:@"/debug"] && debugRoutesEnabled()) {
    NSString *raw = currentRaw();
    NSData *data = raw != nil ? [raw dataUsingEncoding:NSUTF8StringEncoding] : [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    const char *text = data.bytes;
    char *copy = strndup(text, data.length);
    respond(client, 200, copy);
    free(copy);
  } else if ([path isEqualToString:@"/menu"] && debugRoutesEnabled()) {
    NSString *json = menuTitlesJSON();
    respond(client, 200, json.UTF8String);
  } else if ([path isEqualToString:@"/panelstate"] && debugRoutesEnabled()) {
    NSString *json = capturePanelStateJSON();
    respond(client, 200, json.UTF8String);
  } else if ([path isEqualToString:@"/hotkey"]) {
    NSString *json = [NSString stringWithFormat:
        @"{\"register\":%d,\"handler\":%d,\"alt\":%d,\"presses\":%d,\"source\":\"%@\",\"trusted\":%d,\"bundle\":\"%@\"}",
        gHotkeyRegisterStatus, gHotkeyHandlerStatus, gHotkeyAltStatus, gHotkeyPresses, gHotkeySource,
        AXIsProcessTrusted() ? 1 : 0, [NSBundle mainBundle].bundleIdentifier ?: @""];
    const char *text = json.UTF8String;
    char *copy = strndup(text, strlen(text));
    respond(client, 200, copy);
    free(copy);
  } else if ([path isEqualToString:@"/config"] && ([method isEqualToString:@"GET"] || [method isEqualToString:@"POST"])) {
    if ([method isEqualToString:@"POST"]) {
      id json = body.length > 0 ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
      if ([json isKindOfClass:[NSDictionary class]]) {
        id rawOpen = ((NSDictionary *)json)[@"openOnSend"];
        if ([rawOpen isKindOfClass:[NSNumber class]]) {
          // apply before replying so the caller gets the value it just set
          @synchronized(gQueueToken) {
            gConfig[@"openOnSend"] = @([rawOpen boolValue]);
            saveConfig();
          }
        }
      }
    }
    // JSON booleans, not 0/1: the settings page type-checks the field.
    NSString *json = [NSString stringWithFormat:@"{\"openOnSend\":%@}",
                                                configBool(@"openOnSend", NO) ? @"true" : @"false"];
    const char *text = json.UTF8String;
    char *copy = strndup(text, strlen(text));
    respond(client, 200, copy);
    free(copy);
  } else if ([path isEqualToString:@"/ping"]) {
    respond(client, 200, "{\"ok\":true}");
  } else {
    respond(client, 404, "{\"ok\":false}");
  }

  close(client);
}

static void startServer(void) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return;

  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(kPort);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    NSLog(@"DSH task dock companion: cannot bind 127.0.0.1:%d (%s)", kPort, strerror(errno));
    close(fd);
    return;
  }
  if (listen(fd, 16) != 0) {
    close(fd);
    return;
  }
  gListening = YES;

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    for (;;) {
      int client = accept(fd, NULL, NULL);
      if (client < 0) {
        usleep(100 * 1000);
        continue;
      }
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        handleClient(client);
      });
    }
  });
}

// ------------------------------------------------------------- global hotkey

static OSStatus hotKeyHandler(EventHandlerCallRef nextHandler, EventRef event, void *userData) {
  (void)nextHandler;
  (void)event;
  (void)userData;
  gHotkeyPresses += 1;
  EventHotKeyID fired = {0, 0};
  if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(fired), NULL, &fired) == noErr) {
    NSLog(@"dsh-status-box companion: hotkey id=%u pressed (count %d)", (unsigned)fired.id, gHotkeyPresses);
  } else {
    NSLog(@"dsh-status-box companion: hotkey pressed (count %d)", gHotkeyPresses);
  }
  summonDock();
  return noErr;
}

static void registerHotKey(void) {
  EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
  OSStatus handlerStatus =
      InstallApplicationEventHandler(NewEventHandlerUPP(hotKeyHandler), 1, &spec, NULL, NULL);
  gHotkeyHandlerStatus = (int)handlerStatus;

  EventHotKeyID hotKeyID;
  hotKeyID.signature = 'DSHK';
  hotKeyID.id = 1;
  EventHotKeyRef ref = NULL;
  OSStatus status = RegisterEventHotKey(kVK_ANSI_K, optionKey | cmdKey | shiftKey, hotKeyID,
                                        GetApplicationEventTarget(), 0, &ref);
  gHotkeyRegisterStatus = (int)status;
  EventHotKeyID altID;
  altID.signature = 'DSHK';
  altID.id = 2;
  EventHotKeyRef altRef = NULL;
  OSStatus altStatus = RegisterEventHotKey(kVK_ANSI_D, optionKey | cmdKey | shiftKey, altID,
                                           GetApplicationEventTarget(), 0, &altRef);
  gHotkeyAltStatus = (int)altStatus;
  NSLog(@"dsh-status-box companion: alt hotkey (option+command+shift+D) status=%d", (int)altStatus);
}

// Fallback for setups where Carbon hot keys never get delivered: an NSEvent
// global monitor sees the same keystroke, but only when this process is trusted
// for Accessibility. Registered in addition to Carbon, never instead of it.
static void registerEventMonitorFallback(void) {
  if (!AXIsProcessTrusted()) {
    NSLog(@"dsh-status-box companion: accessibility not granted (Carbon hot key is the only path)");
    return;
  }
  NSEventMask mask = NSEventMaskKeyDown;
  [NSEvent addGlobalMonitorForEventsMatchingMask:mask
                                         handler:^(NSEvent *event) {
                                           NSEventModifierFlags flags =
                                               event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
                                           NSEventModifierFlags want = NSEventModifierFlagControl |
                                                                      NSEventModifierFlagOption |
                                                                      NSEventModifierFlagCommand |
                                                                      NSEventModifierFlagShift;
                                           if ((NSUInteger)event.keyCode != (NSUInteger)kVK_ANSI_K &&
      (NSUInteger)event.keyCode != (NSUInteger)kVK_ANSI_D) return;
                                           if ((flags & want) != want) return;
                                           dispatch_async(dispatch_get_main_queue(), ^{
                                             NSLog(@"dsh-status-box companion: hotkey pressed via event monitor");
                                             summonDock();
                                           });
                                         }];
  NSLog(@"dsh-status-box companion: accessibility granted, event monitor registered");
}

// ---------------------------------------------------------------------- app

@interface DockApp : NSObject <NSApplicationDelegate>
@end

@implementation DockApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;

  gQueueToken = [[NSObject alloc] init];
  loadQueue();
  loadConfig();

  // last known status: the menu bar item and the floating window keep showing
  // it while DSH is closed (marked as stale after kStaleAfter)
  NSDictionary *saved = readJSONFile(statePath(@"status.json"));
  if (saved != nil) {
    storeStatus(saved);
    gStatusFromDisk = YES;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:statePath(@"status.json") error:NULL];
    NSDate *modified = attributes[NSFileModificationDate];
    storeStatusAt(modified != nil ? [modified timeIntervalSinceReferenceDate] : 0);
  }

  gCapture = [[CaptureController alloc] init];
  gMenu = [[DockMenu alloc] init];

  gItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
  gItem.button.title = @"";
  NSMenu *menu = [[NSMenu alloc] init];
  menu.delegate = gMenu;
  gItem.menu = menu;
  refreshTitle();

  startServer();
  NSBundle *bundle = [NSBundle mainBundle];
  NSLog(@"dsh-status-box companion: bundle=%@ id=%@ path=%@", bundle.bundlePath,
        bundle.bundleIdentifier ?: @"(none)", bundle.executablePath ?: @"(none)");
  registerHotKey();
  registerEventMonitorFallback();

  [NSTimer scheduledTimerWithTimeInterval:2.0
                                   target:self
                                 selector:@selector(tick:)
                                 userInfo:nil
                                  repeats:YES];

  [[[NSWorkspace sharedWorkspace] notificationCenter]
      addObserverForName:NSWorkspaceDidActivateApplicationNotification
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *note) {
                NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
                NSString *identifier = app.bundleIdentifier ?: @"";
                if ([identifier isEqualToString:@"com.dsh.statusbox.menubar"]) return;
                hideCaptureWindow();
              }];
}

- (void)tick:(NSTimer *)timer {
  (void)timer;
  refreshTitle();
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  (void)notification;
  [[NSStatusBar systemStatusBar] removeStatusItem:gItem];
}

@end

int main(int argc, const char *argv[]) {
  gStatusLock = [NSObject new];
  (void)argc;
  (void)argv;
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    DockApp *delegate = [[DockApp alloc] init];
    app.delegate = delegate;
    [app run];
  }
  return 0;
}
