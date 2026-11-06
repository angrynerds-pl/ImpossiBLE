#import "CBSReplayInternal.h"

// Relaxed replay: for recordings of apps whose traffic is not byte-for-byte
// repeatable — polling timers, Set-ordered subscriptions, wall-clock data in
// writes. Strict replay (CBSReplay.m) blocks the whole timeline on each
// recorded app message in order; here only the *first* occurrence of each
// distinct request gates the timeline, in any order, and every request is
// answered on demand with the replies the recording paired with it.
//
// Mirrored by the Mac app's relaxed ScriptedReplayResponder; keep the two in
// step.

#if TARGET_OS_SIMULATOR

#pragma mark - CSAFE

/// The bytes between the F0 and F2 flags with byte stuffing undone, or nil
/// when `bytes` is not exactly one frame.
static NSData *CBSReplayCSAFEContent(NSData *bytes)
{
    const uint8_t *b = bytes.bytes;
    NSUInteger n = bytes.length;
    if (n < 3 || b[0] != 0xF0 || b[n - 1] != 0xF2) return nil;
    NSMutableData *content = [NSMutableData dataWithCapacity:n];
    for (NSUInteger i = 1; i < n - 1; i++) {
        uint8_t c = b[i];
        if (c == 0xF3) {
            if (i + 1 >= n - 1 || b[i + 1] > 0x03) return nil;
            c = (uint8_t)(0xF0 + b[++i]);
        } else if (c >= 0xF0 && c <= 0xF3) {
            // An unstuffed flag inside the frame.
            return nil;
        }
        [content appendBytes:&c length:1];
    }
    return content;
}

/// Commands whose data is itself a list of commands: SETUSERCFG1 and the
/// Concept2 PM configuration/data wrappers.
static BOOL CBSReplayCSAFEIsWrapper(uint8_t command)
{
    return command == 0x1A || command == 0x76 || command == 0x77 || command == 0x7E || command == 0x7F;
}

static BOOL CBSReplayCSAFEAppendCommands(const uint8_t *b, NSUInteger n, NSMutableArray<NSString *> *parts)
{
    NSUInteger i = 0;
    while (i < n) {
        uint8_t command = b[i++];
        if (command >= 0x80) {
            // Short command: no length, no data.
            [parts addObject:[NSString stringWithFormat:@"%02X", command]];
            continue;
        }
        if (i >= n) return NO;
        NSUInteger length = b[i++];
        if (i + length > n) return NO;
        if (CBSReplayCSAFEIsWrapper(command)) {
            NSMutableArray<NSString *> *inner = [NSMutableArray array];
            if (!CBSReplayCSAFEAppendCommands(b + i, length, inner)) return NO;
            [parts addObject:[NSString stringWithFormat:@"%02X[%@]", command, [inner componentsJoinedByString:@" "]]];
        } else {
            [parts addObject:[NSString stringWithFormat:@"%02X", command]];
        }
        i += length;
    }
    return YES;
}

NSString *CBSReplayCSAFESignature(NSData *bytes)
{
    NSData *content = CBSReplayCSAFEContent(bytes);
    // At least one command byte plus the checksum.
    if (content.length < 2) return nil;
    const uint8_t *b = content.bytes;
    NSUInteger n = content.length - 1;
    // Extended frames carry destination and source addresses (PM: FD 00).
    NSUInteger start = (n >= 3 && b[0] == 0xFD) ? 2 : 0;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (!CBSReplayCSAFEAppendCommands(b + start, n - start, parts) || parts.count == 0) return nil;
    return [parts componentsJoinedByString:@" "];
}

#pragma mark - Wire helpers

/// Request type → @[reply types, keys a reply must share with its request].
static NSDictionary<NSString *, NSArray *> *CBSReplayReplyRules(void)
{
    static NSDictionary *rules;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rules = @{
            @"connect": @[@[@"didConnect", @"didFailConnect"], @[@"id"]],
            @"cancel": @[@[@"didDisconnect"], @[@"id"]],
            @"discoverServices": @[@[@"didDiscoverServices"], @[@"id"]],
            @"discoverIncludedServices": @[@[@"didDiscoverIncludedServices"], @[@"id"]],
            @"discoverCharacteristics": @[@[@"didDiscoverCharacteristics"], @[@"id", @"serviceId"]],
            @"discoverDescriptors": @[@[@"didDiscoverDescriptors"], @[@"id", @"characteristicId"]],
            @"read": @[@[@"didUpdateValue"], @[@"id", @"characteristicId"]],
            @"readDescriptor": @[@[@"didUpdateDescriptorValue"], @[@"id", @"descriptorId"]],
            @"write": @[@[@"didWriteValue"], @[@"id", @"characteristicId"]],
            @"writeDescriptor": @[@[@"didWriteDescriptorValue"], @[@"id", @"descriptorId"]],
            @"setNotify": @[@[@"didUpdateNotification"], @[@"id", @"characteristicId"]],
            @"readRSSI": @[@[@"didReadRSSI"], @[@"id"]],
            @"openL2CAP": @[@[@"didOpenL2CAP"], @[@"id"]],
        };
    });
    return rules;
}

/// Requests replay keeps track of: those with replies, plus `scan`, which
/// gates the advertisements that follow it.
static BOOL CBSReplayIsRequest(NSString *type)
{
    return CBSReplayReplyRules()[type] != nil || [type isEqualToString:@"scan"];
}

static BOOL CBSReplayWantsResponse(NSDictionary *write)
{
    // CBCharacteristicWriteWithResponse == 0
    return [write[@"writeType"] respondsToSelector:@selector(integerValue)] && [write[@"writeType"] integerValue] == 0;
}

/// The characteristic UUID in a `<service id>:<UUID>:<index>` characteristic id.
static NSString *CBSReplayCharacteristicUUID(id characteristicId)
{
    if (![characteristicId isKindOfClass:NSString.class]) return nil;
    NSArray<NSString *> *parts = [characteristicId componentsSeparatedByString:@":"];
    return parts.count >= 2 ? parts[parts.count - 2].uppercaseString : nil;
}

static NSData *CBSReplayValue(NSDictionary *message)
{
    id value = message[@"value"] ?: message[@"valueB64"];
    return [value isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:value options:0] : nil;
}

static NSString *CBSReplayCanonical(NSDictionary *relevant)
{
    NSData *json = [NSJSONSerialization dataWithJSONObject:relevant options:NSJSONWritingSortedKeys error:NULL];
    return json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : relevant.description;
}

static NSString *CBSReplayHex(NSData *data)
{
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *b = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02X", b[i]];
    return hex;
}

#pragma mark - Requests

/// One recorded app request and the replies the recording paired with it. A
/// CSAFE frame written in chunks is one request: its final chunk.
@interface CBSReplayRequest : NSObject
@property (nonatomic, strong) CBSReplayEntry *entry;
/// Requests answered interchangeably share a group: same relevant keys, and
/// for CSAFE frames the same command signature.
@property (nonatomic, copy) NSString *group;
@property (nonatomic, copy, nullable) NSData *value;
@property (nonatomic, copy, nullable) NSString *signature;
@property (nonatomic, strong) NSMutableArray<CBSReplayEntry *> *replies;
/// The first recorded request of its group: the timeline does not pass it
/// before the app sent one like it.
@property (nonatomic) BOOL anchor;
/// A leading chunk of a CSAFE frame: only claims its write confirmation.
@property (nonatomic) BOOL chunk;
@property (nonatomic) BOOL used;
@end

@implementation CBSReplayRequest
- (NSString *)describe
{
    NSString *where = CBSReplayCharacteristicUUID(self.entry.message[@"characteristicId"]);
    NSMutableString *text = [self.entry.type mutableCopy];
    if (where) [text appendFormat:@" %@", where];
    if (self.signature) [text appendFormat:@" CSAFE %@", self.signature];
    [text appendFormat:@" (seq %ld)", (long)self.entry.seq];
    return text;
}
@end

#pragma mark - Player

/// How far after a request its reply may come and still be paired with it.
static const NSTimeInterval kCBSReplayReplyWindow = 30;
/// How many unused requests of a group are searched for one with an identical
/// value before taking the first.
static const NSUInteger kCBSReplayValueLookahead = 64;
/// A peripheral keeps advertising until the app connects to it, as a real one
/// would: its last recorded advertisement is repeated this often (real time,
/// not scaled) while the app scans. Apps drop a device that stops advertising
/// (ErgData after 2 s), and a recording that connected quickly holds only a
/// few advertisements — at 10× they are gone in a fraction of a second.
static const NSTimeInterval kCBSReplayAdvertisingInterval = 1.0;

@implementation CBSReplayRelaxedPlayer {
    double _speed;
    NSDictionary<NSString *, NSString *> *_channels;
    void (^_deliver)(NSDictionary *);
    dispatch_queue_t _queue;

    NSArray<CBSReplayRequest *> *_requests;
    NSDictionary<NSString *, NSArray<CBSReplayRequest *> *> *_groups;
    NSArray<CBSReplayRequest *> *_anchors;
    NSArray<CBSReplayEntry *> *_timeline;

    // Run state, on _queue.
    NSUInteger _generation;
    BOOL _started;
    BOOL _running;
    BOOL _accepting;
    BOOL _waiting;
    NSMutableArray<NSDictionary *> *_preStart;
    NSMutableSet<NSString *> *_seenGroups;
    NSMutableDictionary<NSString *, NSNumber *> *_groupCursor;
    NSMutableDictionary<NSString *, CBSReplayRequest *> *_lastUsed;
    NSMutableDictionary<NSString *, NSMutableData *> *_appFrames;
    NSUInteger _t;
    NSInteger _delayedT;
    NSUInteger _anchorCursor;
    NSUInteger _anchorRef;
    NSDate *_previousTimestamp;
    NSUInteger _answered;
    NSUInteger _unmatched;
    dispatch_source_t _timer;
    BOOL _scanning;
    /// The app's current scan request, kept across restarts: an app that is
    /// already scanning does not scan again, and the new run would otherwise
    /// wait for a scan forever.
    NSDictionary *_activeScan;
    NSMutableDictionary<NSString *, NSDictionary *> *_advertising;
    dispatch_source_t _advertisingTimer;
}

- (instancetype)initWithEntries:(NSArray<CBSReplayEntry *> *)entries
                          speed:(double)speed
                       channels:(NSDictionary<NSString *, NSString *> *)channels
                        deliver:(void (^)(NSDictionary *))deliver
{
    self = [super init];
    if (self) {
        _speed = speed > 0 ? speed : 1;
        _channels = [channels copy];
        _deliver = [deliver copy];
        _queue = dispatch_queue_create("impossible.replay.relaxed", DISPATCH_QUEUE_SERIAL);
        _preStart = [NSMutableArray array];
        _seenGroups = [NSMutableSet set];
        _groupCursor = [NSMutableDictionary dictionary];
        _lastUsed = [NSMutableDictionary dictionary];
        _appFrames = [NSMutableDictionary dictionary];
        _advertising = [NSMutableDictionary dictionary];
        _delayedT = -1;
        _accepting = YES;
        [self prepare:entries];
    }
    return self;
}

/// The response characteristic prefix when `characteristicId` is the request
/// side of a channel.
- (NSString *)responseChannelFor:(id)characteristicId
{
    NSString *uuid = CBSReplayCharacteristicUUID(characteristicId);
    if (!uuid) return nil;
    __block NSString *response = nil;
    [_channels enumerateKeysAndObjectsUsingBlock:^(NSString *request, NSString *resp, BOOL *stop) {
        if ([uuid hasPrefix:request]) {
            response = resp;
            *stop = YES;
        }
    }];
    return response;
}

- (NSString *)groupFor:(NSDictionary *)message signature:(NSString *)signature
{
    NSString *group = CBSReplayCanonical(CBSReplayRelevantKeys(message));
    return signature ? [group stringByAppendingFormat:@"|%@", signature] : group;
}

#pragma mark Preprocessing

- (void)prepare:(NSArray<CBSReplayEntry *> *)entries
{
    NSMutableArray<CBSReplayRequest *> *requests = [NSMutableArray array];
    NSMutableArray<CBSReplayEntry *> *timeline = [NSMutableArray array];
    NSMutableIndexSet *claimed = [NSMutableIndexSet indexSet];
    // Recorded frames being assembled, by characteristic id.
    NSMutableDictionary<NSString *, NSMutableData *> *frames = [NSMutableDictionary dictionary];
    // "<peripheral>|<response prefix>" → the frame whose replies are arriving.
    NSMutableDictionary<NSString *, CBSReplayRequest *> *openFrames = [NSMutableDictionary dictionary];

    for (NSUInteger i = 0; i < entries.count; i++) {
        CBSReplayEntry *entry = entries[i];
        NSDictionary *message = entry.message;

        if (!entry.fromClient) {
            if ([claimed containsIndex:i]) continue;
            if ([entry.type isEqualToString:@"didUpdateValue"]) {
                NSString *uuid = CBSReplayCharacteristicUUID(message[@"characteristicId"]);
                __block CBSReplayRequest *frame = nil;
                [openFrames enumerateKeysAndObjectsUsingBlock:^(NSString *key, CBSReplayRequest *request, BOOL *stop) {
                    NSArray<NSString *> *parts = [key componentsSeparatedByString:@"|"];
                    if ([parts[0] isEqual:message[@"id"]] && [uuid hasPrefix:parts[1]]) {
                        frame = request;
                        *stop = YES;
                    }
                }];
                if (frame) {
                    [frame.replies addObject:entry];
                    continue;
                }
            }
            [timeline addObject:entry];
            continue;
        }

        if (!CBSReplayIsRequest(entry.type)) continue;

        CBSReplayRequest *request = [CBSReplayRequest new];
        request.entry = entry;
        request.replies = [NSMutableArray array];
        request.value = CBSReplayValue(message);

        NSString *response = [entry.type isEqualToString:@"write"] ? [self responseChannelFor:message[@"characteristicId"]] : nil;
        if (response) {
            NSString *characteristicId = message[@"characteristicId"];
            NSString *frameKey = [NSString stringWithFormat:@"%@|%@", message[@"id"], response];
            // Any write on the request side ends the previous frame's replies.
            [openFrames removeObjectForKey:frameKey];
            NSMutableData *frame = frames[characteristicId] ?: [NSMutableData data];
            [frame appendData:request.value ?: [NSData data]];
            const uint8_t *bytes = frame.bytes;
            if (frame.length > 0 && bytes[frame.length - 1] == 0xF2) {
                [frames removeObjectForKey:characteristicId];
                request.value = frame;
                request.signature = CBSReplayCSAFESignature(frame) ?: CBSReplayHex(frame);
                openFrames[frameKey] = request;
            } else {
                frames[characteristicId] = frame;
                request.chunk = YES;
            }
        }
        request.group = [self groupFor:message signature:request.signature];

        NSArray *rule = CBSReplayReplyRules()[entry.type];
        BOOL wantsReply = rule && (![entry.type isEqualToString:@"write"] || CBSReplayWantsResponse(message));
        if (wantsReply) {
            NSArray<NSString *> *replyTypes = rule[0];
            NSArray<NSString *> *keys = rule[1];
            for (NSUInteger j = i + 1; j < entries.count; j++) {
                CBSReplayEntry *candidate = entries[j];
                if ([candidate.timestamp timeIntervalSinceDate:entry.timestamp] > kCBSReplayReplyWindow) break;
                if (candidate.fromClient || [claimed containsIndex:j] || ![replyTypes containsObject:candidate.type]) continue;
                BOOL same = YES;
                for (NSString *key in keys) {
                    if (![candidate.message[key] isEqual:message[key]]) {
                        same = NO;
                        break;
                    }
                }
                if (!same) continue;
                [claimed addIndex:j];
                [request.replies addObject:candidate];
                break;
            }
        }
        [requests addObject:request];
    }

    NSMutableDictionary<NSString *, NSMutableArray<CBSReplayRequest *> *> *groups = [NSMutableDictionary dictionary];
    NSMutableArray<CBSReplayRequest *> *anchors = [NSMutableArray array];
    for (CBSReplayRequest *request in requests) {
        [request.replies sortUsingComparator:^NSComparisonResult(CBSReplayEntry *a, CBSReplayEntry *b) {
            return a.seq < b.seq ? NSOrderedAscending : (a.seq > b.seq ? NSOrderedDescending : NSOrderedSame);
        }];
        if (request.chunk) continue;
        NSMutableArray *group = groups[request.group];
        if (!group) {
            group = [NSMutableArray array];
            groups[request.group] = group;
            request.anchor = YES;
            [anchors addObject:request];
        }
        [group addObject:request];
    }
    _requests = requests;
    _groups = groups;
    _anchors = anchors;
    _timeline = timeline;
}

#pragma mark Public

- (void)start
{
    dispatch_async(_queue, ^{
        BOOL first = !self->_started;
        NSArray<NSDictionary *> *early = first ? [self->_preStart copy] : (self->_activeScan ? @[self->_activeScan] : @[]);
        [self resetRun];
        self->_started = YES;
        self->_running = YES;
        self->_accepting = YES;
        [self startAdvertisingTimer];
        for (NSDictionary *message in early) {
            [self answer:message];
        }
        [self runTimeline];
    });
}

- (void)stop
{
    dispatch_async(_queue, ^{
        BOOL wasRunning = self->_running;
        NSUInteger step = self->_t + 1;
        [self resetRun];
        self->_accepting = NO;
        if (wasRunning) {
            CBSReplayReportStatus(ImpossiBLEReplayStateStopped,
                                  [NSString stringWithFormat:@"at timeline entry %lu of %lu",
                                   (unsigned long)step, (unsigned long)self->_timeline.count]);
        }
    });
}

- (void)handle:(NSDictionary *)message
{
    dispatch_async(_queue, ^{
        if (!self->_accepting) return;
        if (!self->_started) {
            [self->_preStart addObject:message];
            return;
        }
        [self answer:message];
        if (self->_waiting) {
            [self runTimeline];
        }
    });
}

#pragma mark Answering (on _queue)

- (void)answer:(NSDictionary *)message
{
    NSString *type = message[@"type"];
    if ([type isEqual:@"scan"]) {
        _scanning = YES;
        _activeScan = message;
    } else if ([type isEqual:@"stopScan"]) {
        _scanning = NO;
        _activeScan = nil;
    } else if ([type isEqual:@"connect"] && [message[@"id"] isKindOfClass:NSString.class]) {
        [_advertising removeObjectForKey:message[@"id"]];
    }
    if (![type isKindOfClass:NSString.class] || !CBSReplayIsRequest(type)) return;

    NSString *signature = nil;
    NSData *value = CBSReplayValue(message);
    NSString *response = [type isEqualToString:@"write"] ? [self responseChannelFor:message[@"characteristicId"]] : nil;
    if (response) {
        NSString *characteristicId = message[@"characteristicId"];
        NSMutableData *frame = _appFrames[characteristicId] ?: [NSMutableData data];
        [frame appendData:value ?: [NSData data]];
        const uint8_t *bytes = frame.bytes;
        if (frame.length == 0 || bytes[frame.length - 1] != 0xF2) {
            // A leading chunk: confirm it so the app sends the rest.
            _appFrames[characteristicId] = frame;
            if (CBSReplayWantsResponse(message)) {
                _deliver([self writeConfirmationFor:message]);
            }
            return;
        }
        [_appFrames removeObjectForKey:characteristicId];
        value = frame;
        signature = CBSReplayCSAFESignature(frame) ?: CBSReplayHex(frame);
    }

    NSString *group = [self groupFor:message signature:signature];
    [_seenGroups addObject:group];

    CBSReplayRequest *request = [self takeRequestInGroup:group value:value] ?: _lastUsed[group];
    if (request) {
        _lastUsed[group] = request;
        _answered++;
        [self playReplies:request.replies from:request.entry.timestamp index:0 generation:_generation];
        return;
    }

    _unmatched++;
    NSLog(@"ImpossiBLE: replay has nothing recorded for %@%@", type,
          signature ? [NSString stringWithFormat:@" (CSAFE %@)", signature] : @"");
    if ([type isEqualToString:@"write"] && CBSReplayWantsResponse(message)) {
        _deliver([self writeConfirmationFor:message]);
    } else if ([type isEqualToString:@"setNotify"]) {
        _deliver(@{@"type": @"didUpdateNotification", @"id": message[@"id"] ?: @"",
                   @"characteristicId": message[@"characteristicId"] ?: @"",
                   @"enabled": message[@"enabled"] ?: @NO, @"error": @""});
    }
}

- (NSDictionary *)writeConfirmationFor:(NSDictionary *)write
{
    return @{@"type": @"didWriteValue", @"id": write[@"id"] ?: @"",
             @"characteristicId": write[@"characteristicId"] ?: @"", @"error": @""};
}

/// The first unused request of the group — preferring, among the next few,
/// one recorded with the identical value.
- (CBSReplayRequest *)takeRequestInGroup:(NSString *)group value:(NSData *)value
{
    NSArray<CBSReplayRequest *> *requests = _groups[group];
    if (!requests) return nil;
    NSUInteger cursor = _groupCursor[group].unsignedIntegerValue;
    while (cursor < requests.count && requests[cursor].used) cursor++;
    _groupCursor[group] = @(cursor);
    if (cursor >= requests.count) return nil;

    CBSReplayRequest *chosen = requests[cursor];
    if (value) {
        NSUInteger end = MIN(requests.count, cursor + kCBSReplayValueLookahead);
        for (NSUInteger i = cursor; i < end; i++) {
            if (!requests[i].used && [requests[i].value isEqualToData:value]) {
                chosen = requests[i];
                break;
            }
        }
    }
    chosen.used = YES;
    return chosen;
}

/// Delivers replies one after another, each at its recorded distance from
/// the previous one (scaled), chained so their order can never change.
- (void)playReplies:(NSArray<CBSReplayEntry *> *)replies from:(NSDate *)previous index:(NSUInteger)index generation:(NSUInteger)generation
{
    while (index < replies.count) {
        if (generation != _generation || !_accepting) return;
        CBSReplayEntry *reply = replies[index];
        NSTimeInterval delay = MAX(0, [reply.timestamp timeIntervalSinceDate:previous]) / _speed;
        if (delay > 0.001) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf || strongSelf->_generation != generation || !strongSelf->_accepting) return;
                strongSelf->_deliver(reply.message);
                [strongSelf playReplies:replies from:reply.timestamp index:index + 1 generation:generation];
            });
            return;
        }
        _deliver(reply.message);
        previous = reply.timestamp;
        index++;
    }
}

#pragma mark Timeline (on _queue)

/// The first anchor the app has not matched yet, or nil.
- (CBSReplayRequest *)firstMissingAnchor
{
    while (_anchorCursor < _anchors.count && [_seenGroups containsObject:_anchors[_anchorCursor].group]) {
        _anchorCursor++;
    }
    return _anchorCursor < _anchors.count ? _anchors[_anchorCursor] : nil;
}

- (void)runTimeline
{
    if (!_running) return;
    _waiting = NO;
    [self cancelTimer];

    while (_t < _timeline.count) {
        CBSReplayEntry *entry = _timeline[_t];

        CBSReplayRequest *missing = [self firstMissingAnchor];
        if (missing && missing.entry.seq < entry.seq) {
            [self waitFor:missing];
            return;
        }

        if (_delayedT != (NSInteger)_t) {
            _delayedT = (NSInteger)_t;
            // Measured from the later of the previous timeline entry and the
            // last request it waited for.
            NSDate *reference = _previousTimestamp;
            while (_anchorRef < _anchors.count && _anchors[_anchorRef].entry.seq < entry.seq) _anchorRef++;
            NSDate *anchorTime = _anchorRef > 0 ? _anchors[_anchorRef - 1].entry.timestamp : nil;
            if (!reference || (anchorTime && [anchorTime compare:reference] == NSOrderedDescending)) {
                reference = anchorTime;
            }
            NSTimeInterval delay = reference ? MAX(0, [entry.timestamp timeIntervalSinceDate:reference]) / _speed : 0;
            if (delay > 0.001) {
                if (_t % 100 == 0) [self reportProgress:nil];
                __weak typeof(self) weakSelf = self;
                [self scheduleAfter:delay block:^{ [weakSelf runTimeline]; }];
                return;
            }
        }

        _deliver(entry.message);
        if ([entry.type isEqual:@"didDiscover"] && [entry.message[@"id"] isKindOfClass:NSString.class]) {
            _advertising[entry.message[@"id"]] = entry.message;
        }
        _previousTimestamp = entry.timestamp;
        _t++;
    }

    CBSReplayRequest *missing = [self firstMissingAnchor];
    if (missing) {
        [self waitFor:missing];
        return;
    }
    // Passed. Requests are still answered: the app may well keep talking to
    // the peripheral after its last recorded notification.
    _running = NO;
    CBSReplayReportStatus(ImpossiBLEReplayStatePassed,
                          [NSString stringWithFormat:@"%lu timeline entries played; %lu requests answered, %lu unmatched",
                           (unsigned long)_timeline.count, (unsigned long)_answered, (unsigned long)_unmatched]);
}

- (void)waitFor:(CBSReplayRequest *)anchor
{
    _waiting = YES;
    [self reportProgress:anchor];
    __weak typeof(self) weakSelf = self;
    [self scheduleAfter:kCBSReplayFromClientTimeout block:^{ [weakSelf timeOut:anchor]; }];
}

- (void)timeOut:(CBSReplayRequest *)anchor
{
    NSUInteger step = _t + 1;
    [self resetRun];
    _accepting = NO;
    CBSReplayReportStatus(ImpossiBLEReplayStateFailed,
                          [NSString stringWithFormat:@"timeline entry %lu of %lu: the app sent no %@ within %d s",
                           (unsigned long)step, (unsigned long)_timeline.count, [anchor describe],
                           (int)kCBSReplayFromClientTimeout]);
}

- (void)reportProgress:(CBSReplayRequest *)awaiting
{
    NSString *detail = [NSString stringWithFormat:@"timeline entry %lu of %lu%@",
                        (unsigned long)(_t + 1), (unsigned long)_timeline.count,
                        awaiting ? [NSString stringWithFormat:@", waiting for %@", [awaiting describe]] : @""];
    CBSReplayReportStatus(ImpossiBLEReplayStateRunning, detail);
}

/// Repeats each advertising peripheral's last advertisement while the app scans.
- (void)startAdvertisingTimer
{
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    uint64_t interval = (uint64_t)(kCBSReplayAdvertisingInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, NSEC_PER_SEC / 20);
    NSUInteger generation = _generation;
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_generation != generation || !strongSelf->_accepting || !strongSelf->_scanning) return;
        for (NSDictionary *advertisement in strongSelf->_advertising.allValues) {
            strongSelf->_deliver(advertisement);
        }
    });
    dispatch_resume(timer);
    _advertisingTimer = timer;
}

- (void)resetRun
{
    _generation++;
    [self cancelTimer];
    if (_advertisingTimer) {
        dispatch_source_cancel(_advertisingTimer);
        _advertisingTimer = nil;
    }
    _scanning = NO;
    [_advertising removeAllObjects];
    _running = NO;
    _waiting = NO;
    _t = 0;
    _delayedT = -1;
    _anchorCursor = 0;
    _anchorRef = 0;
    _previousTimestamp = nil;
    _answered = 0;
    _unmatched = 0;
    [_preStart removeAllObjects];
    [_seenGroups removeAllObjects];
    [_groupCursor removeAllObjects];
    [_lastUsed removeAllObjects];
    [_appFrames removeAllObjects];
    for (CBSReplayRequest *request in _requests) request.used = NO;
}

/// One timer at a time: a timeline delay and an anchor timeout never overlap.
- (void)scheduleAfter:(NSTimeInterval)interval block:(dispatch_block_t)block
{
    [self cancelTimer];
    NSUInteger generation = _generation;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 1000);
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

#endif
