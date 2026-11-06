#import <Foundation/Foundation.h>
#import "include/ImpossiBLE.h"

// Shared between the strict player (CBSReplay.m) and the relaxed one
// (CBSReplayRelaxed.m). Not public.

#if TARGET_OS_SIMULATOR

NS_ASSUME_NONNULL_BEGIN

extern const NSTimeInterval kCBSReplayFromClientTimeout;

@interface CBSReplayEntry : NSObject
@property (nonatomic) NSInteger seq;
@property (nonatomic, strong) NSDate *timestamp;
@property (nonatomic) BOOL fromClient;
@property (nonatomic, copy) NSDictionary *message;
@property (nonatomic, copy) NSString *type;
- (BOOL)matches:(NSDictionary *)actual;
@end

/// The keys replay matching compares: everything but `value`, `valueB64`, and
/// `_`-prefixed shim bookkeeping.
NSDictionary *CBSReplayRelevantKeys(NSDictionary *message);

/// Logs final states, posts the passed/failed Darwin notifications, and calls
/// the status handler on the main queue.
void CBSReplayReportStatus(ImpossiBLEReplayState state, NSString *_Nullable detail);

/// What both players offer the public API. All methods are asynchronous and
/// thread-safe.
@protocol CBSReplayPlaying <NSObject>
/// Called on the player's queue at the top of every `start`, before anything
/// is played — where the PM5 clock is moved to the time of that run.
@property (nonatomic, copy, nullable) void (^willStartRun)(void);
- (void)start;
- (void)stop;
- (void)handle:(NSDictionary *)message;
@end

/// Answers app requests on demand from what the recording paired with them,
/// and plays everything else (notifications, advertisements, disconnects) on
/// the recorded timeline, gated on the app having sent each distinct request
/// recorded before it, in any order. See ImpossiBLEReplayMatchingRelaxed.
@interface CBSReplayRelaxedPlayer : NSObject <CBSReplayPlaying>
/// - Parameter channels: request characteristic UUID prefix → response
///   characteristic UUID prefix (uppercase), e.g. `CE060021` → `CE060022`.
- (instancetype)initWithEntries:(NSArray<CBSReplayEntry *> *)entries
                          speed:(double)speed
                       channels:(NSDictionary<NSString *, NSString *> *)channels
                        deliver:(void (^)(NSDictionary *message))deliver;
@end

/// Moves every Concept2 PM5 timestamp in `entries` (workout summaries, CSAFE
/// date/time and logged-workout replies on `responseChannels`) by the offset
/// that makes the last workout summary read as `now`. Returns `entries`,
/// rewritten in place.
NSArray<CBSReplayEntry *> *CBSReplayShiftPM5Times(NSArray<CBSReplayEntry *> *entries,
                                                  NSDate *now,
                                                  NSSet<NSString *> *responseChannels);

/// The command structure of a CSAFE frame, with all data left out: e.g.
/// `76[13] 7E[80 81]`. nil unless `bytes` is one complete frame (`F0 … F2`).
NSString *_Nullable CBSReplayCSAFESignature(NSData *bytes);

NS_ASSUME_NONNULL_END

#endif
