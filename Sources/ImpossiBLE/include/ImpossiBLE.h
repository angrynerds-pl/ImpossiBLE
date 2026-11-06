#import <Foundation/Foundation.h>

// ImpossiBLE — transparent BLE bridge for iOS Simulator.
//
// Link this library into your iOS app. On simulator builds, it automatically
// swizzles CBCentralManager to forward BLE operations to a macOS helper
// process that uses real Bluetooth hardware.
//
// Bridging itself needs no API — activation is automatic via +load. The
// functions below exist only for tests that want to supply their own virtual
// peripherals instead of relying on the menu bar app's selection.

NS_ASSUME_NONNULL_BEGIN

/// Uploads a mock configuration for this app's session.
///
/// `configurationJSON` has the same shape as a saved configuration file, so an
/// exported configuration can be handed over verbatim:
///
///     { "id": "…", "name": "…", "devices": [ … ] }
///
/// This is what lets a test own its fixture instead of depending on whatever
/// happens to be selected in the menu bar app — which matters as soon as the
/// service UUIDs under test are computed rather than fixed.
///
/// The uploaded configuration is **ephemeral**: it is never written to the
/// user's saved configurations, and it is discarded when this app disconnects.
///
/// Returns NO when no provider is connected. Always NO on device builds, where
/// the bridge is inactive.
BOOL ImpossiBLESetMockConfiguration(NSData *configurationJSON);

/// Hands control back to whatever the menu bar app has selected.
void ImpossiBLEClearMockConfiguration(void);

/// Whether a provider (mock or forwarding helper) is currently reachable.
/// Tests should wait for this before uploading a configuration.
BOOL ImpossiBLEIsProviderConnected(void);

/// Replays a wire recording inside this process — no menu bar app needed.
///
/// `path` names a recording in the format Passthrough writes to
/// `/tmp/impossible-passthrough-recordings/` (a JSON array of `{seq, timestamp,
/// direction, message}` entries). A UI test can bundle one and hand its path to
/// the app (e.g. via `launchEnvironment`); the Simulator shares the Mac's file
/// system, so the test bundle's path is readable as is. `~` is expanded.
///
/// After setup the library behaves as if the menu bar app were serving it in
/// Replay mode: Bluetooth reports powered on, and the socket to the menu bar
/// app is dropped and not reconnected until `ImpossiBLECleanupReplay`. Call it
/// before creating a `CBCentralManager` to avoid a powered-off/on bounce.
///
/// The recording is validated up front; returns NO with `error` describing the
/// first problem when it is unreadable or invalid. Setting up again replaces
/// the previous recording. Always NO on device builds.
///
/// A UI test does not need the app to call this: launching the app with the
/// `IMPOSSIBLE_REPLAY_RECORDING` environment variable set to a recording path
/// sets up and starts that replay when the library loads.
BOOL ImpossiBLESetupReplay(NSString *path, NSError * _Nullable * _Nullable error);

/// Darwin notification that restarts a replay started from
/// `IMPOSSIBLE_REPLAY_RECORDING`: the recording moves back to its first entry
/// and plays from there, as `ImpossiBLEStartReplay` does; the app's Bluetooth
/// state is left alone. Post it from a UI test, which runs in another
/// process, with `CFNotificationCenterPostNotification` on the Darwin notify
/// center. Replays set up through `ImpossiBLESetupReplay` ignore it; call
/// `ImpossiBLEStartReplay` instead.
extern NSString *const ImpossiBLEReplayRestartNotification;

/// Posted on the Darwin notify center when a replay passes or fails, so a UI
/// test — another process — can wait for the result. The reason is logged
/// (`ImpossiBLE: replay FAILED — …`); Darwin notifications carry no payload.
extern NSString *const ImpossiBLEReplayPassedNotification;
extern NSString *const ImpossiBLEReplayFailedNotification;

typedef NS_ENUM(NSInteger, ImpossiBLEReplayMatching) {
    /// Every recorded app message is waited for, in recorded order.
    ImpossiBLEReplayMatchingStrict,
    /// For apps whose traffic varies between runs (polling, unordered
    /// subscriptions, wall-clock data in writes). Each app request is answered
    /// on demand with the replies recorded for the most similar recorded
    /// request — identical value first, then (for CSAFE frames on a request
    /// channel) the same command structure, then the next of its kind; extra
    /// requests reuse the last answer. Everything else — notifications,
    /// advertisements, disconnects — plays on the recorded timeline, which
    /// only waits for the first occurrence of each distinct request, in any
    /// order. Request channels pair a write characteristic with the one its
    /// answers are notified on: by default `CE060021` → `CE060022` (Concept2
    /// PM5), or `IMPOSSIBLE_REPLAY_CHANNELS=req:resp[,req:resp…]` (UUID
    /// prefixes).
    ImpossiBLEReplayMatchingRelaxed,
};

/// Options for the next `ImpossiBLESetupReplay`. `speed` divides every
/// recorded delay (2 plays twice as fast); the 60 s wait for the app is not
/// scaled. A replay started from `IMPOSSIBLE_REPLAY_RECORDING` takes them from
/// `IMPOSSIBLE_REPLAY_SPEED` and `IMPOSSIBLE_REPLAY_MODE` (`strict` or
/// `relaxed`). Defaults: speed 1, strict.
void ImpossiBLESetReplayOptions(double speed, ImpossiBLEReplayMatching matching);

/// Starts playing the recording, entries in `seq` order, waiting each entry's
/// recorded time distance from the previous one: `toClient` messages are
/// delivered as if from a peripheral, and each `fromClient` entry waits for
/// the app to send a matching message (same type and ids; data values are not
/// compared), failing the run after 60 s. Messages the app sent since setup
/// count, so starting right after the app began scanning is fine. Calling it
/// again restarts from the first entry. NO when nothing is set up.
BOOL ImpossiBLEStartReplay(NSError * _Nullable * _Nullable error);

/// Stops the running replay; nothing is answered until the next start. The
/// recording stays set up. NO when nothing is set up.
BOOL ImpossiBLEStopReplay(NSError * _Nullable * _Nullable error);

/// Unloads the recording: replayed peripherals disconnect, Bluetooth briefly
/// reports powered off, and the library reconnects to the menu bar app if one
/// is running. Succeeds when nothing is set up.
BOOL ImpossiBLECleanupReplay(NSError * _Nullable * _Nullable error);

typedef NS_ENUM(NSInteger, ImpossiBLEReplayState) {
    /// Nothing set up (after cleanup).
    ImpossiBLEReplayStateIdle,
    /// Set up, waiting for start.
    ImpossiBLEReplayStateReady,
    /// Playing; reported whenever the run starts waiting (delay or app message).
    ImpossiBLEReplayStateRunning,
    /// Every entry played.
    ImpossiBLEReplayStatePassed,
    /// An expected app message did not arrive in time; `detail` says which.
    ImpossiBLEReplayStateFailed,
    /// Stopped by `ImpossiBLEStopReplay` (or replaced by a new setup).
    ImpossiBLEReplayStateStopped,
};

typedef void (^ImpossiBLEReplayStatusHandler)(ImpossiBLEReplayState state, NSString * _Nullable detail);

/// Observes replay progress, on the main queue. Results are also logged
/// (`ImpossiBLE: replay passed` / `FAILED — …`). Pass nil to stop observing.
void ImpossiBLESetReplayStatusHandler(ImpossiBLEReplayStatusHandler _Nullable handler);

/// Receives the far end of an L2CAP channel the app just opened.
///
/// `psm` is a `CBL2CAPPSM`, typed here as `uint16_t` so this header stays free
/// of CoreBluetooth. The streams are already open; the handler owns scheduling
/// them and closing them when done.
typedef void (^ImpossiBLEL2CAPPeerHandler)(uint16_t psm,
                                           NSInputStream *input,
                                           NSOutputStream *output);

/// Serves L2CAP channels locally, so an app can talk to itself over one.
///
/// A mock peripheral cannot answer an L2CAP channel: nothing on the provider
/// side knows what bytes your protocol expects. Only the app does — so instead
/// of inventing a peer, ImpossiBLE hands the app the other end of the channel
/// and lets it play both roles. For an app whose peripheral role cannot run in
/// the Simulator at all, this is the only way to exercise the bulk-transfer
/// path without hardware.
///
/// Applies only while a client-supplied configuration is active. In Passthrough
/// mode the real channel is used, so a registered handler is ignored rather
/// than shadowing the hardware.
///
/// Pass nil to stop serving channels locally.
void ImpossiBLESetMockL2CAPHandler(ImpossiBLEL2CAPPeerHandler _Nullable handler);

NS_ASSUME_NONNULL_END
