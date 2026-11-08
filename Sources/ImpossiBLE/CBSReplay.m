#import "include/ImpossiBLE.h"
#import "CBSConnection.h"
#import "CBSMock.h"
#import "CBSReplayInternal.h"

// In-process Replay: plays a wire recording (the JSON Passthrough writes) as if
// the menu bar app were serving this process in Replay mode. The player is
// attached as CBSConnection's local provider, so the activator neither knows
// nor cares that no socket is involved — and no provider needs to run.
//
// Mirrors the Mac app's ReplayScript/ScriptedReplayResponder; keep the two in
// step (format, ordering, matching, timeout).

static NSString *const kCBSReplayErrorDomain = @"ImpossiBLE";

NSString *const ImpossiBLEReplayRestartNotification = @"com.impossible.replay.restart";
NSString *const ImpossiBLEReplayPassedNotification = @"com.impossible.replay.passed";
NSString *const ImpossiBLEReplayFailedNotification = @"com.impossible.replay.failed";

#if TARGET_OS_SIMULATOR

const NSTimeInterval kCBSReplayFromClientTimeout = 60;

#pragma mark - Options

static double gSpeed = 1;
static ImpossiBLEReplayMatching gMatching = ImpossiBLEReplayMatchingStrict;
static BOOL gPM5CurrentTime = YES;

/// A replay setting: the environment variable `name`, else the launch argument
/// pair `-name value`. Launch arguments are for tools that start the app with
/// arguments but cannot set its environment (e2e frameworks driving an
/// unmodified app); `simctl launch` and XCUIApplication can do either.
static NSString *CBSReplaySetting(NSString *name)
{
    NSProcessInfo *process = NSProcessInfo.processInfo;
    NSString *value = process.environment[name];
    if (value.length > 0) return value;
    NSArray<NSString *> *arguments = process.arguments;
    NSUInteger flag = [arguments indexOfObject:[@"-" stringByAppendingString:name]];
    if (flag != NSNotFound && flag + 1 < arguments.count) return arguments[flag + 1];
    return nil;
}

/// Request → response characteristic UUID prefixes for relaxed replay.
static NSDictionary<NSString *, NSString *> *CBSReplayChannels(void)
{
    NSString *configured = CBSReplaySetting(@"IMPOSSIBLE_REPLAY_CHANNELS");
    if (configured.length == 0) {
        // Concept2 PM5: CSAFE commands are written to CE060021 and answered
        // with notifications on CE060022.
        return @{@"CE060021": @"CE060022"};
    }
    NSMutableDictionary *channels = [NSMutableDictionary dictionary];
    for (NSString *pair in [configured componentsSeparatedByString:@","]) {
        NSArray<NSString *> *sides = [pair componentsSeparatedByString:@":"];
        NSString *request = [sides.firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *response = [sides.lastObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (sides.count == 2 && request.length > 0 && response.length > 0) {
            channels[request.uppercaseString] = response.uppercaseString;
        }
    }
    return channels;
}

#pragma mark - Script

@implementation CBSReplayEntry

NSDictionary *CBSReplayRelevantKeys(NSDictionary *message)
{
    NSMutableDictionary *relevant = [NSMutableDictionary dictionaryWithCapacity:message.count];
    [message enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (![key isKindOfClass:NSString.class]) return;
        if ([key isEqualToString:@"value"] || [key isEqualToString:@"valueB64"] || [key hasPrefix:@"_"]) return;
        relevant[key] = value;
    }];
    return relevant;
}

- (BOOL)matches:(NSDictionary *)actual
{
    return [CBSReplayRelevantKeys(self.message) isEqualToDictionary:CBSReplayRelevantKeys(actual)];
}

@end

static BOOL CBSReplayFail(NSError **error, NSInteger code, NSString *message)
{
    if (error) {
        *error = [NSError errorWithDomain:kCBSReplayErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return NO;
}

static NSDate *CBSReplayParseTimestamp(NSString *string)
{
    static NSISO8601DateFormatter *fractional;
    static NSISO8601DateFormatter *whole;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fractional = [NSISO8601DateFormatter new];
        fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        whole = [NSISO8601DateFormatter new];
    });
    return [fractional dateFromString:string] ?: [whole dateFromString:string];
}

static NSArray<CBSReplayEntry *> *CBSReplayLoadScript(NSString *path, NSError **error)
{
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (!data) {
        CBSReplayFail(error, 10, [NSString stringWithFormat:@"Cannot read %@: %@", path, readError.localizedDescription]);
        return nil;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (!json) {
        CBSReplayFail(error, 11, @"Not valid JSON");
        return nil;
    }
    if (![json isKindOfClass:NSArray.class]) {
        CBSReplayFail(error, 11, @"Expected a JSON array of entries");
        return nil;
    }
    NSArray *array = json;
    if (array.count == 0) {
        CBSReplayFail(error, 11, @"The recording has no entries");
        return nil;
    }

    NSMutableArray<CBSReplayEntry *> *entries = [NSMutableArray arrayWithCapacity:array.count];
    NSMutableSet<NSNumber *> *seenSeqs = [NSMutableSet set];
    for (NSUInteger index = 0; index < array.count; index++) {
        NSDictionary *object = array[index];
        NSString *problem = nil;
        if (![object isKindOfClass:NSDictionary.class]) {
            problem = @"not an object";
        } else if (![object[@"seq"] isKindOfClass:NSNumber.class] ||
                   CFNumberIsFloatType((CFNumberRef)object[@"seq"]) ||
                   CFGetTypeID((CFTypeRef)object[@"seq"]) == CFBooleanGetTypeID()) {
            problem = @"missing or non-integer seq";
        } else if (![object[@"timestamp"] isKindOfClass:NSString.class] || !CBSReplayParseTimestamp(object[@"timestamp"])) {
            problem = @"missing or invalid timestamp";
        } else if (![object[@"direction"] isEqual:@"fromClient"] && ![object[@"direction"] isEqual:@"toClient"]) {
            problem = @"direction must be fromClient or toClient";
        } else if (![object[@"message"] isKindOfClass:NSDictionary.class]) {
            problem = @"missing message object";
        } else if (![object[@"message"][@"type"] isKindOfClass:NSString.class] || [object[@"message"][@"type"] length] == 0) {
            problem = @"message has no type";
        } else if ([seenSeqs containsObject:object[@"seq"]]) {
            problem = [NSString stringWithFormat:@"duplicate seq %@", object[@"seq"]];
        }
        if (problem) {
            CBSReplayFail(error, 11, [NSString stringWithFormat:@"Entry %lu: %@", (unsigned long)index, problem]);
            return nil;
        }
        [seenSeqs addObject:object[@"seq"]];

        CBSReplayEntry *entry = [CBSReplayEntry new];
        entry.seq = [object[@"seq"] integerValue];
        entry.timestamp = CBSReplayParseTimestamp(object[@"timestamp"]);
        entry.fromClient = [object[@"direction"] isEqual:@"fromClient"];
        entry.message = object[@"message"];
        entry.type = object[@"message"][@"type"];
        [entries addObject:entry];
    }
    [entries sortUsingComparator:^NSComparisonResult(CBSReplayEntry *a, CBSReplayEntry *b) {
        return a.seq < b.seq ? NSOrderedAscending : (a.seq > b.seq ? NSOrderedDescending : NSOrderedSame);
    }];
    if ([entries indexOfObjectPassingTest:^BOOL(CBSReplayEntry *entry, NSUInteger idx, BOOL *stop) { return !entry.fromClient; }] == NSNotFound) {
        CBSReplayFail(error, 11, @"Nothing in it goes to the app — this looks like a file Replay mode recorded. Load a Passthrough recording (made against a real device) instead.");
        return nil;
    }
    return entries;
}

#pragma mark - Player

static ImpossiBLEReplayStatusHandler gStatusHandler;
/// `IMPOSSIBLE_REPLAY_DEBUG`: log every message between the app and the
/// replay, one line each, to see which request a stuck replay never answered.
static void CBSReplayTrace(NSString *arrow, NSDictionary *message)
{
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ enabled = CBSReplaySetting(@"IMPOSSIBLE_REPLAY_DEBUG").length > 0; });
    if (!enabled) return;
    NSMutableString *line = [NSMutableString stringWithString:[message[@"type"] description] ?: @"?"];
    NSString *characteristic = message[@"characteristicId"];
    if ([characteristic isKindOfClass:NSString.class]) {
        NSArray<NSString *> *parts = [characteristic componentsSeparatedByString:@":"];
        if (parts.count >= 2) [line appendFormat:@" %@", [parts[parts.count - 2] substringToIndex:MIN((NSUInteger)8, parts[parts.count - 2].length)]];
    }
    NSString *value = message[@"value"] ?: message[@"valueB64"];
    NSData *data = [value isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:value options:0] : nil;
    if (data.length > 0) {
        NSMutableString *hex = [NSMutableString string];
        const uint8_t *bytes = data.bytes;
        for (NSUInteger i = 0; i < MIN(data.length, (NSUInteger)24); i++) [hex appendFormat:@"%02X", bytes[i]];
        [line appendFormat:@" %@%@", hex, data.length > 24 ? @"…" : @""];
    }
    if ([message[@"error"] isKindOfClass:NSString.class] && [message[@"error"] length] > 0) [line appendFormat:@" error=%@", message[@"error"]];
    NSLog(@"ImpossiBLE: replay %@ %@", arrow, line);
}

static void CBSReplayDeliver(NSDictionary *message)
{
    CBSReplayTrace(@"→ app", message);
    CBSConnectionDeliverLocal(message);
}

/// `IMPOSSIBLE_REPLAY_STATUS_FILE`: where a replay started from the environment
/// writes its outcome, since a Darwin notification carries no reason.
static NSString *gStatusFilePath;

static void CBSReplayWriteStatusFile(NSString *state, NSString *detail)
{
    NSString *path = gStatusFilePath;
    if (path.length == 0) return;
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions |= NSISO8601DateFormatWithFractionalSeconds;
    NSDictionary *status = @{@"state": state, @"detail": detail ?: @"", @"timestamp": [formatter stringFromDate:[NSDate date]]};
    NSData *data = [NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingPrettyPrinted error:nil];
    if (![data writeToFile:path options:NSDataWritingAtomic error:nil]) {
        NSLog(@"ImpossiBLE: could not write the replay status to %@", path);
    }
}

/// A run has no outcome yet: a test that reads the file instead of waiting
/// for the notification must not see the previous run's passed/failed.
static void CBSReplayClearStatusFile(void)
{
    if (gStatusFilePath.length == 0) return;
    [NSFileManager.defaultManager removeItemAtPath:gStatusFilePath error:nil];
}

void CBSReplayReportStatus(ImpossiBLEReplayState state, NSString *detail)
{
    switch (state) {
        case ImpossiBLEReplayStatePassed:
        case ImpossiBLEReplayStateFailed:
        case ImpossiBLEReplayStateStopped:
            NSLog(@"ImpossiBLE: replay %@%@",
                  state == ImpossiBLEReplayStatePassed ? @"passed" : (state == ImpossiBLEReplayStateFailed ? @"FAILED" : @"stopped"),
                  detail ? [@" — " stringByAppendingString:detail] : @"");
            break;
        default:
            break;
    }
    // A UI test runs in another process; Darwin notifications are what it
    // can observe, and the status file, written first, tells it why.
    if (state == ImpossiBLEReplayStatePassed || state == ImpossiBLEReplayStateFailed) {
        CBSReplayWriteStatusFile(state == ImpossiBLEReplayStatePassed ? @"passed" : @"failed", detail);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)(state == ImpossiBLEReplayStatePassed
                                                                    ? ImpossiBLEReplayPassedNotification
                                                                    : ImpossiBLEReplayFailedNotification),
                                             NULL, NULL, true);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        ImpossiBLEReplayStatusHandler handler = gStatusHandler;
        if (handler) {
            handler(state, detail);
        }
    });
}

/// Plays entries one at a time in seq order. Before each entry it waits for
/// the timestamp distance to the previous one; then a toClient entry is
/// delivered as recorded, and a fromClient entry blocks until the app sends a
/// matching message, failing the run after kCBSReplayFromClientTimeout.
///
/// App messages are buffered — including those sent after setup but before
/// start — so one that arrives early still matches later. Messages the script
/// never asks for are ignored. After the run passes, fails, or is stopped, the
/// app is no longer answered.
///
/// All state is confined to `_queue`; scheduled callbacks check `_generation`,
/// so nothing from a previous run fires into the next.
@interface CBSReplayPlayer : NSObject <CBSReplayPlaying>
- (instancetype)initWithEntries:(NSArray<CBSReplayEntry *> *)entries speed:(double)speed;
@end

@implementation CBSReplayPlayer {
    void (^_willStartRun)(void);
    NSArray<CBSReplayEntry *> *_entries;
    double _speed;
    dispatch_queue_t _queue;
    NSUInteger _generation;
    NSUInteger _index;
    // The entry whose leading delay has already elapsed.
    NSInteger _delayedIndex;
    BOOL _awaiting;
    BOOL _running;
    BOOL _accepting;
    NSMutableArray<NSDictionary *> *_pending;
    dispatch_source_t _timer;
}

- (instancetype)initWithEntries:(NSArray<CBSReplayEntry *> *)entries speed:(double)speed
{
    self = [super init];
    if (self) {
        _entries = [entries copy];
        _speed = speed > 0 ? speed : 1;
        _queue = dispatch_queue_create("impossible.replay.player", DISPATCH_QUEUE_SERIAL);
        _pending = [NSMutableArray array];
        _delayedIndex = -1;
        _accepting = YES;
    }
    return self;
}

@synthesize willStartRun = _willStartRun;

- (void)start
{
    dispatch_async(_queue, ^{
        if (self->_willStartRun) self->_willStartRun();
        // The first start keeps what the app sent since setup; a restart
        // begins from a clean slate.
        if (self->_running || !self->_accepting) {
            [self resetRun];
        }
        self->_index = 0;
        self->_delayedIndex = -1;
        self->_running = YES;
        self->_accepting = YES;
        [self run];
    });
}

- (void)stop
{
    dispatch_async(_queue, ^{
        BOOL wasRunning = self->_running;
        NSUInteger step = self->_index + 1;
        [self resetRun];
        self->_accepting = NO;
        if (wasRunning) {
            CBSReplayReportStatus(ImpossiBLEReplayStateStopped,
                                  [NSString stringWithFormat:@"at step %lu of %lu", (unsigned long)step, (unsigned long)self->_entries.count]);
        }
    });
}

- (void)handle:(NSDictionary *)message
{
    dispatch_async(_queue, ^{
        if (!self->_accepting) return;
        [self->_pending addObject:message];
        if (!self->_running || !self->_awaiting) return;
        if (![self takePendingMatching:self->_entries[self->_index]]) return;
        self->_awaiting = NO;
        [self cancelTimer];
        self->_index++;
        [self run];
    });
}

#pragma mark Run loop (on _queue)

/// Advances as far as possible without waiting; returns once a delay, an app
/// message, or the end of the script is reached. Iterative, so long runs of
/// zero-delay entries cannot grow the stack.
- (void)run
{
    while (_index < _entries.count) {
        CBSReplayEntry *entry = _entries[_index];

        if (_delayedIndex != (NSInteger)_index) {
            _delayedIndex = (NSInteger)_index;
            NSTimeInterval delay = _index == 0 ? 0 : MAX(0, [entry.timestamp timeIntervalSinceDate:_entries[_index - 1].timestamp]) / _speed;
            if (delay > 0) {
                [self reportProgress];
                __weak typeof(self) weakSelf = self;
                [self scheduleAfter:delay block:^{ [weakSelf run]; }];
                return;
            }
        }

        if (!entry.fromClient) {
            CBSReplayDeliver(entry.message);
            _index++;
        } else if ([self takePendingMatching:entry]) {
            _index++;
        } else {
            _awaiting = YES;
            [self reportProgress];
            __weak typeof(self) weakSelf = self;
            [self scheduleAfter:kCBSReplayFromClientTimeout block:^{ [weakSelf timeOut]; }];
            return;
        }
    }
    _running = NO;
    _accepting = NO;
    CBSReplayReportStatus(ImpossiBLEReplayStatePassed,
                          [NSString stringWithFormat:@"all %lu entries played", (unsigned long)_entries.count]);
}

- (void)timeOut
{
    CBSReplayEntry *entry = _entries[_index];
    NSUInteger step = _index + 1;
    [self resetRun];
    _accepting = NO;
    CBSReplayReportStatus(ImpossiBLEReplayStateFailed,
                          [NSString stringWithFormat:@"step %lu of %lu: no %@ from the app within %d s (seq %ld)",
                           (unsigned long)step, (unsigned long)_entries.count, entry.type,
                           (int)kCBSReplayFromClientTimeout, (long)entry.seq]);
}

- (BOOL)takePendingMatching:(CBSReplayEntry *)entry
{
    for (NSUInteger i = 0; i < _pending.count; i++) {
        if ([entry matches:_pending[i]]) {
            [_pending removeObjectAtIndex:i];
            return YES;
        }
    }
    return NO;
}

- (void)reportProgress
{
    CBSReplayEntry *entry = _entries[_index];
    NSString *detail = [NSString stringWithFormat:@"step %lu of %lu%@",
                        (unsigned long)(_index + 1), (unsigned long)_entries.count,
                        _awaiting ? [NSString stringWithFormat:@", waiting for %@", entry.type] : @""];
    CBSReplayReportStatus(ImpossiBLEReplayStateRunning, detail);
}

- (void)resetRun
{
    _generation++;
    [self cancelTimer];
    _index = 0;
    _delayedIndex = -1;
    _awaiting = NO;
    _running = NO;
    [_pending removeAllObjects];
}

/// One timer at a time is enough: a delay and a match timeout never overlap.
- (void)scheduleAfter:(NSTimeInterval)interval block:(dispatch_block_t)block
{
    [self cancelTimer];
    NSUInteger generation = _generation;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 100);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_generation != generation) return;
        [strongSelf cancelTimer];
        block();
    });
    dispatch_resume(timer);
    _timer = timer;
}

- (void)cancelTimer
{
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

@end

#pragma mark - Public API

static id<CBSReplayPlaying> gPlayer;

static id CBSReplayLock(void)
{
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static id<CBSReplayPlaying> CBSReplayCurrentPlayer(void)
{
    @synchronized (CBSReplayLock()) {
        return gPlayer;
    }
}

BOOL ImpossiBLESetupReplay(NSString *path, NSError **error)
{
    if (path.length == 0) {
        return CBSReplayFail(error, 12, @"Missing recording path");
    }
    NSArray<CBSReplayEntry *> *entries = CBSReplayLoadScript(path.stringByExpandingTildeInPath, error);
    if (!entries) {
        NSLog(@"ImpossiBLE: replay recording rejected: %@", error ? (*error).localizedDescription : path);
        return NO;
    }

    double speed;
    ImpossiBLEReplayMatching matching;
    BOOL pm5CurrentTime;
    @synchronized (CBSReplayLock()) {
        speed = gSpeed;
        matching = gMatching;
        pm5CurrentTime = gPM5CurrentTime;
    }
    NSDictionary<NSString *, NSString *> *channels = CBSReplayChannels();
    id<CBSReplayPlaying> player;
    if (matching == ImpossiBLEReplayMatchingRelaxed) {
        player = [[CBSReplayRelaxedPlayer alloc] initWithEntries:entries
                                                           speed:speed
                                                        channels:channels
                                                         deliver:^(NSDictionary *message) { CBSReplayDeliver(message); }];
    } else {
        player = [[CBSReplayPlayer alloc] initWithEntries:entries speed:speed];
    }
    if (pm5CurrentTime) {
        // Every run — the first start and each restart — moves the clock to
        // its own start time from the recorded values, so a restarted run is
        // not logged as a duplicate of the previous one. Only toClient values
        // change, which neither player matches on; the players share these
        // entry objects and call this on their queue.
        NSArray<NSDictionary *> *recorded = [entries valueForKey:@"message"];
        NSSet<NSString *> *responseChannels = [NSSet setWithArray:channels.allValues];
        player.willStartRun = ^{
            [entries enumerateObjectsUsingBlock:^(CBSReplayEntry *entry, NSUInteger index, BOOL *stop) {
                entry.message = recorded[index];
            }];
            CBSReplayShiftPM5Times(entries, [NSDate date], responseChannels);
        };
    }
    id<CBSReplayPlaying> previous;
    BOOL attached;
    @synchronized (CBSReplayLock()) {
        previous = gPlayer;
        attached = previous != nil;
        gPlayer = player;
    }
    [previous stop];

    if (!attached) {
        // Every outgoing message goes to whichever player is current, so a
        // second setup just swaps players without bouncing the connection.
        CBSConnectionSetLocalProvider(^(NSDictionary *message) {
            CBSReplayTrace(@"app →", message);
            [CBSReplayCurrentPlayer() handle:message];
        });
        // Install the activator's handlers now: setup may run before the app
        // creates its CBCentralManager, and replayed messages need a receiver.
        CBSEnsureConnectionOpen();
    }
    NSLog(@"ImpossiBLE: replay set up with %lu entries from %@ (%@, speed %g)", (unsigned long)entries.count, path,
          matching == ImpossiBLEReplayMatchingRelaxed ? @"relaxed" : @"strict", speed);
    CBSReplayReportStatus(ImpossiBLEReplayStateReady, nil);
    return YES;
}

void ImpossiBLESetReplayOptions(double speed, ImpossiBLEReplayMatching matching)
{
    @synchronized (CBSReplayLock()) {
        gSpeed = speed > 0 ? speed : 1;
        gMatching = matching;
    }
}

void ImpossiBLESetReplayPM5CurrentTime(BOOL enabled)
{
    @synchronized (CBSReplayLock()) {
        gPM5CurrentTime = enabled;
    }
}

BOOL ImpossiBLEStartReplay(NSError **error)
{
    id<CBSReplayPlaying> player = CBSReplayCurrentPlayer();
    if (!player) {
        return CBSReplayFail(error, 13, @"No replay is set up; call ImpossiBLESetupReplay first");
    }
    [player start];
    return YES;
}

BOOL ImpossiBLEStopReplay(NSError **error)
{
    id<CBSReplayPlaying> player = CBSReplayCurrentPlayer();
    if (!player) {
        return CBSReplayFail(error, 13, @"No replay is set up; call ImpossiBLESetupReplay first");
    }
    [player stop];
    return YES;
}

BOOL ImpossiBLECleanupReplay(NSError **error)
{
    id<CBSReplayPlaying> player;
    @synchronized (CBSReplayLock()) {
        player = gPlayer;
        gPlayer = nil;
    }
    if (!player) return YES;
    [player stop];
    // Reports a disconnect (tearing down replayed peripherals) and hands the
    // process back to the menu bar app, if one is running.
    CBSConnectionSetLocalProvider(nil);
    CBSReplayReportStatus(ImpossiBLEReplayStateIdle, nil);
    return YES;
}

void ImpossiBLESetReplayStatusHandler(ImpossiBLEReplayStatusHandler handler)
{
    gStatusHandler = [handler copy];
}

/// Moves the replay back to its first entry and plays it from there; nothing
/// else about the app's Bluetooth state changes.
static void CBSReplayRestart(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                             const void *object, CFDictionaryRef userInfo)
{
    NSError *error = nil;
    CBSReplayClearStatusFile();
    if (!ImpossiBLEStartReplay(&error)) {
        NSLog(@"ImpossiBLE: replay restart failed: %@", error.localizedDescription);
        return;
    }
    NSLog(@"ImpossiBLE: replay restarted (%@)", (__bridge NSString *)name);
}

void CBSReplayStartFromEnvironment(void)
{
    NSString *path = CBSReplaySetting(@"IMPOSSIBLE_REPLAY_RECORDING");
    if (path.length == 0) return;
    gStatusFilePath = [CBSReplaySetting(@"IMPOSSIBLE_REPLAY_STATUS_FILE") copy];
    CBSReplayClearStatusFile();

    double speed = CBSReplaySetting(@"IMPOSSIBLE_REPLAY_SPEED").doubleValue;
    NSString *mode = CBSReplaySetting(@"IMPOSSIBLE_REPLAY_MODE").lowercaseString;
    if (mode.length > 0 && ![mode isEqualToString:@"strict"] && ![mode isEqualToString:@"relaxed"]) {
        NSLog(@"ImpossiBLE: ignoring IMPOSSIBLE_REPLAY_MODE=%@ (strict or relaxed)", mode);
    }
    ImpossiBLESetReplayOptions(speed > 0 ? speed : 1,
                               [mode isEqualToString:@"relaxed"] ? ImpossiBLEReplayMatchingRelaxed : ImpossiBLEReplayMatchingStrict);
    ImpossiBLESetReplayPM5CurrentTime(![CBSReplaySetting(@"IMPOSSIBLE_REPLAY_PM5_TIME").lowercaseString isEqualToString:@"recorded"]);

    NSError *error = nil;
    if (!ImpossiBLESetupReplay(path, &error) || !ImpossiBLEStartReplay(&error)) {
        NSLog(@"ImpossiBLE: replay from IMPOSSIBLE_REPLAY_RECORDING failed: %@", error.localizedDescription);
        CBSReplayWriteStatusFile(@"failed", [@"setup failed: " stringByAppendingString:error.localizedDescription ?: @"unknown error"]);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)ImpossiBLEReplayFailedNotification, NULL, NULL, true);
        return;
    }
    // A UI test runs in another process and cannot call into this one; a Darwin
    // notification is the one signal it can send the app without its help.
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, CBSReplayRestart,
                                    (__bridge CFStringRef)ImpossiBLEReplayRestartNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    NSLog(@"ImpossiBLE: replaying %@ (from IMPOSSIBLE_REPLAY_RECORDING)", path);
}

#else

// On a device the real radio is used; replay has nothing to stand in for.

static BOOL CBSReplayUnavailable(NSError **error)
{
    if (error) {
        *error = [NSError errorWithDomain:kCBSReplayErrorDomain
                                     code:14
                                 userInfo:@{NSLocalizedDescriptionKey: @"Replay is only available in the Simulator"}];
    }
    return NO;
}

BOOL ImpossiBLESetupReplay(NSString *path, NSError **error) { return CBSReplayUnavailable(error); }
BOOL ImpossiBLEStartReplay(NSError **error) { return CBSReplayUnavailable(error); }
BOOL ImpossiBLEStopReplay(NSError **error) { return CBSReplayUnavailable(error); }
BOOL ImpossiBLECleanupReplay(NSError **error) { return CBSReplayUnavailable(error); }
void ImpossiBLESetReplayOptions(double speed, ImpossiBLEReplayMatching matching) {}
void ImpossiBLESetReplayPM5CurrentTime(BOOL enabled) {}
void ImpossiBLESetReplayStatusHandler(ImpossiBLEReplayStatusHandler handler) {}

#endif
