#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The CoreBluetooth <-> wire-protocol translation layer for Passthrough mode.
///
/// This is the former impossible-helper daemon minus its socket server: it
/// consumes decoded protocol messages and emits reply messages through
/// `messageHandler`, leaving transport ownership to whoever hosts it (the mock
/// app's socket server, or the capture workflow talking to it in process).
@interface CBSPassthroughBridge : NSObject

/// Outgoing protocol messages, invoked on a private serial queue.
@property (nonatomic, copy, nullable) void (^messageHandler)(NSDictionary<NSString *, id> *message);

/// Real-device communication activity (GATT/L2CAP operations only), invoked on
/// a private serial queue. Replaces the daemon's activity snapshot file.
@property (nonatomic, copy, nullable) void (^activityHandler)(NSString *peripheralId,
                                                              NSString *name,
                                                              NSString *operation,
                                                              NSString *detail);

/// Called on the recorder's private queue whenever a recording opens a new
/// session file, with its absolute path. Set before starting a recording.
@property (nonatomic, copy, nullable) void (^recordingFileHandler)(NSString *path);

/// Whether wire traffic is being recorded. Off until started.
@property (nonatomic, readonly, getter=isRecording) BOOL recording;

/// Opens a recording: one `passthrough-<date>-<pid>-<ptr>.json` file (see
/// `CBSWireRecorder`) per client session, the first one opening with the next
/// recorded message. Starting again closes the current file.
///
/// The bridge does not record on its own: the host calls `recordMessage:` with
/// what the app actually sent and received. Traffic the host injects or
/// consumes itself (the PM5 remote) must not reach the recording, and only
/// the host can tell it apart.
- (void)startRecordingToDirectory:(NSString *)directory;

/// As `startRecordingToDirectory:`, with `<filePrefix>-…` file names.
- (void)startRecordingToDirectory:(NSString *)directory filePrefix:(NSString *)filePrefix;

/// Appends one message to the current recording; a no-op while not recording.
/// `direction` is `CBSWireDirectionFromClient` or `CBSWireDirectionToClient`.
- (void)recordMessage:(NSDictionary<NSString *, id> *)message direction:(NSString *)direction;

/// Closes the current recording file and records nothing further.
- (void)stopRecording;

/// Feed one decoded protocol message. Call from a single serial queue.
- (void)handleMessage:(NSDictionary<NSString *, id> *)message;

/// Tear down everything the current client owned: stop scanning, cancel
/// connections, close L2CAP channels, and clear all object stores. Call when
/// the client disconnects or is superseded.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
