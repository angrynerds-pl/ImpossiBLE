#import <Foundation/Foundation.h>

typedef void (^CBSMessageHandler)(NSDictionary *message);
typedef void (^CBSStateHandler)(BOOL connected);

void CBSConnectionSetMessageHandler(CBSMessageHandler handler);
void CBSConnectionSetStateHandler(CBSStateHandler handler);
void CBSConnectionSend(NSDictionary *msg);
void CBSConnectionOpen(void);
BOOL CBSConnectionIsConnected(void);

/// Serves this process from an in-process provider instead of the socket.
///
/// While attached, `CBSConnectionSend` hands every message to `provider`, the
/// provider answers through `CBSConnectionDeliverLocal`, and the connection
/// reports itself connected — so the activator behaves exactly as if the menu
/// bar app were serving it, and no provider needs to run at all. Attaching
/// drops any socket connection (with the usual disconnect synthesis) and
/// suppresses reconnects; detaching (nil) reports a disconnect and resumes the
/// socket. Used by Replay set up in process (`ImpossiBLESetupReplay`).
void CBSConnectionSetLocalProvider(CBSMessageHandler provider);

/// Delivers a message from the local provider to the activator, as if it had
/// arrived on the socket. Ignored when no local provider is attached.
void CBSConnectionDeliverLocal(NSDictionary *msg);
