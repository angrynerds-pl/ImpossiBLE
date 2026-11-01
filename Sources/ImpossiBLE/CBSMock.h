#import <Foundation/Foundation.h>
#import "include/ImpossiBLE.h"

// Internal glue between the public mock API and the activator.

NS_ASSUME_NONNULL_BEGIN

/// The handler registered by `ImpossiBLESetMockL2CAPHandler`, if any.
ImpossiBLEL2CAPPeerHandler _Nullable CBSMockL2CAPHandler(void);

/// Whether the connected app supplied the configuration currently being served.
/// Local L2CAP is gated on this: in Passthrough mode a real channel exists, and
/// quietly serving a loopback instead would hide the very hardware the user
/// switched to.
BOOL CBSMockConfigurationActive(void);
void CBSMockSetConfigurationActive(BOOL active);

#if TARGET_OS_SIMULATOR
/// Opens the provider socket with the activator's message and state handlers
/// installed. The public API can run before any CBCentralManager exists; opening
/// the bare connection then would drop every reply (or, for a local replay,
/// every replayed message).
void CBSEnsureConnectionOpen(void);

/// Sets up and starts the replay named by `IMPOSSIBLE_REPLAY_RECORDING`, if the
/// process was launched with it. Called from `+load`, so a UI test can replay a
/// recording without the app calling any ImpossiBLE API.
void CBSReplayStartFromEnvironment(void);

/// Serves an L2CAP channel inside this process when a handler is registered and
/// a client-supplied configuration is active. Returns NO when the caller should
/// fall back to asking the provider.
@class CBSPeripheral;
BOOL cbs_try_local_l2cap(CBSPeripheral *peripheral, uint16_t psm);
#endif

NS_ASSUME_NONNULL_END
