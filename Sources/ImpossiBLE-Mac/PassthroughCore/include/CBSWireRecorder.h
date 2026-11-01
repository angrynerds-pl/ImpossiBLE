#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Direction values used in recorded entries.
extern NSString *const CBSWireDirectionFromClient;
extern NSString *const CBSWireDirectionToClient;

/// Appends protocol messages to a JSON file: an array of
/// `{seq, timestamp, direction, type, message[, valueHex]}` objects. The file is
/// rewritten in place so it stays a valid JSON array after every entry (a crash
/// loses nothing already recorded). One file per session: the file opens
/// lazily on the first message and `finish` closes it, so the next message
/// starts a fresh `<filePrefix>-<date>-<pid>-<ptr>.json`.
///
/// Shared by Passthrough's opt-in traffic recording and Replay mode, so both
/// produce the same format.
@interface CBSWireRecorder : NSObject

- (instancetype)initWithDirectory:(NSString *)directory filePrefix:(NSString *)filePrefix NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Called on the recorder's private queue whenever a new session file is
/// created, with its absolute path.
@property (nonatomic, copy, nullable) void (^fileOpenedHandler)(NSString *path);

/// Thread-safe; entries are written asynchronously in call order.
- (void)recordMessage:(NSDictionary<NSString *, id> *)message direction:(NSString *)direction;

/// Closes the current session file.
- (void)finish;

@end

NS_ASSUME_NONNULL_END
