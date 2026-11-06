# Agent Notes

## Project Shape

- `Sources/ImpossiBLE` is the simulator-side Swift package library. It swizzles CoreBluetooth APIs at `+load` time and sends newline-delimited JSON to `/tmp/impossible.sock`. The socket is opened lazily on the first `CBCentralManager` instantiation (via a `dispatch_once` in `cbs_post_init`), so linking ImpossiBLE without using CoreBluetooth does not contact the provider. The connection layer (`CBSConnection`) auto-reconnects, sends a `hello {clientVersion, bundleId, pid}` handshake on connect (`kCBSLibraryVersion` — bump on release), and drives `CBManagerState` transitions (`poweredOn`/`poweredOff`) based on socket connectivity.
- `Sources/ImpossiBLE-Mac` builds `ImpossiBLE-Mac.app`, the host-side menu bar provider and **single owner of the socket in both modes**. It has its own `Package.swift` with three targets: **`ImpossiBLEProviderKit`** (library product `ProviderKit/` — server, models, panel/editor views, the FontAwesome resource; this is what the Simsalabim suite app will embed), the thin **`ImpossiBLE-Mac`** executable (`App/` — app lifecycle plus the shell wiring in `StatusBarController`), and `ImpossiBLEPassthroughCore`, an ObjC library target containing `CBSPassthroughBridge` — the former `impossible-helper` daemon minus its socket server. The ProviderKit's public surface is deliberately small: `MockServer` (facade with `transport` and `passthroughActivity`), `MockStore`, the panel and editor entry views, and `FontAwesome`; everything else is internal. The transport (socket lifecycle, NDJSON framing, hello handshake, last-connection-wins takeover, client-socket hardening, socket-ownership guard) is SimBridgeKit's `ProtocolServer` (`MockServer.transport`, URL dependency on github.com/mickeyl/SimBridgeKit); `MockServer` is the domain layer on top and routes by `serveMode`: Mock answers from `MockStore`/client fixtures, Passthrough forwards every message to the bridge, which translates to real CoreBluetooth calls and emits replies through its `messageHandler`. All `MockServer` handlers run on the transport's I/O queue, which also guards its mutable state. There is no separate helper process anymore (removed in 3.0.0). Font resources (FontAwesome Brands) are bundled via SPM resource rules. The status item is implemented with AppKit (`StatusBarController`) rather than SwiftUI `MenuBarExtra` so the control panel can remain open while other apps are active.
- Passthrough needs `NSBluetoothAlwaysUsageDescription` (in `Resources/Info.plist`) and — under the Hardened Runtime of release builds — `com.apple.security.device.bluetooth` in `Resources/entitlements.plist`. Missing entitlement is the classic "works in debug (ad-hoc, Hardened Runtime not enforced), denied in release" trap. Ad-hoc dev builds get a fresh identity each rebuild, so macOS re-prompts for Bluetooth consent.
- `Sources/ImpossiBLE-Mac/MCPShim` is the `impossible-mcp` executable, the stdio MCP server agents launch; see **Agent Control (MCP)**.
- `SampleApp` is an iOS sample Xcode project that imports the local package and uses normal CoreBluetooth APIs.
- `Sources/ImpossiBLE/CBSMockConfiguration.m` and `CBSReplay.m` are the only client-side files with a public API. Everything else activates itself; these functions exist so a test can supply its own virtual peripherals (`ImpossiBLESetMockConfiguration` & co.) or replay a recording in process (`ImpossiBLESetupReplay` / `Start` / `Stop` / `Cleanup`).

## Socket discipline & takeover

Both live in SimBridgeKit's `ProtocolServer` since the adoption — see that
repo's AGENTS.md for the invariants (SO_NOSIGPIPE + send-timeout hardening,
last-connection-wins takeover, socket-ownership guard). What matters on this
side:

- `MockServer` never touches fds. Replies go through `transport.send(_:)`,
  domain events surface via `transport.note(_:)`, and
  `transport.onClientTeardown` drives `tearDownClientState()` — mock state,
  client-supplied configuration, and the bridge's scans/connections/L2CAP
  channels are dropped on disconnect, takeover, and stop alike.
- The ownership guard means a second provider instance shows **Blocked** in
  the panel (orange) instead of stealing `/tmp/impossible.sock` from a
  running one.
- The wire code for takeover stays `clientBusy`, so pre-3.0 libraries handle
  eviction identically; the evicted library stops auto-reconnecting — to use
  an older simulator again, relaunch its app.

## Client-Supplied Mock Configurations

An app can upload a configuration over the same socket, which then replaces the menu bar selection for as long as that app is connected.

Wire protocol:

- Client sends `{"type": "setMockConfiguration", "configuration": {...}}` where the payload decodes as `MockConfiguration` (keys `id`, `name`, `devices`).
- Client sends `{"type": "clearMockConfiguration"}` to hand control back.
- Server replies `{"type": "didSetMockConfiguration", "ok": true}`, or `ok: false` with `error` when decoding fails. Failing loudly matters here: a malformed fixture is otherwise indistinguishable from an empty environment.

Invariants that must not be broken when touching this:

- **The uploaded configuration never reaches `MockStore`.** It lives in `MockServer.clientSuppliedDevices` (ioQueue) and `clientSuppliedConfiguration` (published for the UI). Routing it through the store would overwrite the user's working set and persist it, which is exactly what an ephemeral test fixture must not do.
- **It is cleared on both edges of a connection** — in `acceptClient()` and on disconnect in `readFromClient` — so a stale fixture can never outlive the app that supplied it.
- **`fetchEnabledDevices()` and `fetchDevice(uuid:)` are the only two read points.** Any new code path that reaches for devices must go through them, or it will serve the user's configuration while everything else serves the client's.
- **The panel shows what is served, not what is selected.** `MockMenuContent.mockBody` swaps in `clientConfigBanner` plus a read-only `clientDeviceList`. A banner alone, over the user's own device rows, would make the panel describe devices that do not exist.

Note that `MockServer.log()` only updates `lastActivity` for the UI; it does not write to os_log. Absence of console output from the server is not evidence that something failed.

### Loopback L2CAP

`cbs_try_local_l2cap` in `CBSActivator.m` serves a channel in process when a handler is registered *and* `CBSMockConfigurationActive()` is true. `CBSPeripheral.openL2CAPChannel:` calls it first and only falls through to the provider when it returns NO.

- The provider is deliberately not involved. The existing passthrough path already builds a `socketpair` per channel; this reuses the mechanism and simply hands `fds[1]` to the app instead of forwarding it over the Unix socket.
- Both gates matter. Without the handler there is nobody to talk to; without the active client configuration this would hijack Passthrough, where a real channel exists.
- Streams get `kCFStreamPropertyShouldCloseNativeSocket`, or the descriptors outlive the streams and the channel never reports end-of-stream.
- The handler is dispatched off the delegate queue, so a handler that blocks on reads cannot stall `didOpenL2CAPChannel:`.
- `cbs_try_local_l2cap` lives inside the file's `#if TARGET_OS_SIMULATOR` guard; it references simulator-only globals, so moving it out breaks device builds.

The mock *server* still has no L2CAP support (`handleOpenL2CAP` returns "L2CAP is not supported in mock mode"), and that path remains for clients that register no handler.

## Agent Control (MCP)

Agents drive the provider through a tools-only MCP server. The MCP logic lives in the app (`ProviderKit/Control/`); the `impossible-mcp` executable target (`MCPShim/`) is a dumb stdio ⇄ socket pipe, so tools change without touching the shim.

- `ProviderControlServer` (public facade, created in `MacAppRuntime`) owns `ControlSocketServer` on `/tmp/impossible-control.sock`, one `MCPSession` per connection, and one shared `ProviderTools`. Enabled by default; the footer `terminal` toggle persists `AgentControlEnabled`.
- **Separate socket on purpose.** `/tmp/impossible.sock` is single-client with last-connection-wins; agents must never evict the simulator, and several may connect at once. Same ownership guard as `ProtocolServer` (probe, never steal); additionally 0600 plus a `getpeereid` uid check, since anyone on the socket can kill the simulator app (`terminate_simulator_app`) and drive the Mac's Bluetooth.
- **Tool handlers run on main** (`MCPSession` hops there): store, mode controller, and activity monitor are main-thread objects. Never `main.sync` from the control queue.
- **Wire shapes are `ControlDTO`, not the persisted `Codable` form**: hex/`valueText` values and named properties/pairing/security, because agents get base64 and bitmasks wrong.
- **The client-supplied-configuration invariants hold here too**: tools only report it (`get_status`, the `note` on working-set results) and never route it into `MockStore`.
- `set_mode` skips re-selecting the current mode, which would otherwise bounce the server and drop the connected app.
- Agent capture uses its **own** `CaptureSession`, independent of the capture window and the serving bridge. Filter/selection logic is shared with the window through `CaptureFilter`.
- `initialize` is answered but not required, so the shim can reconnect transparently after an app relaunch; requests in flight when the socket drops are answered by the shim with a JSON-RPC error.
- **Live mock simulation lives in `MockServer`** (the `Agent control` extension), because it acts on per-client session state on the transport's I/O queue: pushed values go into `writtenCharValues` (so later reads return them, and they die with the client like app writes do), notifications reuse the unsolicited `didUpdateValue` the library already handles, and `disconnect_device` shares `sendDisconnect` with `cancel`. Characteristics are addressed by rebuilding the discovery wire id (`MockDevice.characteristicAddress`); if discovery's id format changes, that helper must change with it.
- **Every mock handler records to `activityLog` and checks `consumeFailure` before answering.** A new handler that skips either is invisible to `mock_activity` or immune to `inject_failure`. Failure rules and the log survive client changes; rules fire only in mock mode. Read/write errors carry `errorDomain`/`errorCode` (`CBATTErrorDomain`) because only those two replies are parsed with `cbs_error_from_msg`; the other replies take an error string.
- Live tools resolve devices among what is *served* (`servedDevice`: the app's uploaded configuration while there is one), not just the working set — they never write to it, so the client-supplied invariants hold.
- The shim is bundled at `Contents/Helpers/impossible-mcp`, **not** `Contents/MacOS`: `mac-stop`/`mac-relaunch` `pkill -f ".app/Contents/MacOS"` and must not kill agents' shims. It is signed before the bundle (the bundle signature does not cover `Helpers` without `--deep`). With no app running it `open -g`s the enclosing `.app` (falling back to the bundle id) and waits up to 15 s.

`make install` links `$(prefix)/bin/impossible-mcp` to the bundled shim; the shim resolves symlinks to find its app.

Smoke test without an agent: pipe newline-delimited JSON-RPC (`initialize`, `tools/list`, `tools/call`) into `ImpossiBLE-Mac.app/Contents/Helpers/impossible-mcp`.

### PM5 remote

`PM5Remote` (main-thread model, `MockServer.pm5Remote`) and `PM5RemoteEngine` (`ProviderKit/Server/PM5Remote.swift`) inject CSAFE frames into the simulator app's live passthrough connection to a Concept2 PM5. The engine sits in `MockServer`'s passthrough path on the I/O queue: `appMessage` sees app → bridge, `bridgeMessage` sees bridge → app, and either can hold or consume a message.

- **ErgData has no CSAFE request/response matching** — it acts on any reply on `CE060022` by content (a stray set-screen-state ack can re-trigger its terminate logic). So while an injected command is in flight the engine holds the app's writes to `CE060021`, consumes its own write confirmations and the reply whose first command byte matches the payload, and forwards any other reply to the app.
- It only starts when the app is between commands: not mid-frame (last chunk lacked `F2`), and not awaiting a reply (unless that is older than 1.5 s); after 2 s of waiting it goes ahead.
- Frames copy ErgData's `formatCsafeFrame`: extended `F0 FD 00 … cks F2`, XOR checksum of the payload, `F0…F3` stuffed. Button presses are SETPMCFG (`0x76`) set-screen-state (`0x13`) workout-screen virtual keys 47–54.
- A PM5 is recognised from the discovered characteristic UUIDs, and *ready* only once the app subscribed to `CE060022`; the engine never subscribes itself, since the app would then see a notification-state change it did not ask for.
- After consuming a reply to its own command, the engine also consumes one identical reply (ignoring the status byte) within 0.3 s: a PM5 was seen answering — and executing — every command twice on one connection (status toggle `81` then `01`), which leaked the second copy to the app. The doubling itself went away after a provider restart and app reconnect; its cause is unknown. `pm5_trace` (engine ring buffer of command/response chunks with their disposition) is the tool to look with.
- Off by default (`PM5RemoteEnabled`); `MockServer.tearDownClientState` resets the engine with the bridge.
- `PM5State` is one GETPMCFG (`0x7E`) frame of single-byte queries (operational/workout/rowing state, workout and interval type, display type and units, battery) plus screen-state status (3 bytes); the reply is parsed as `cmd len data…`. Value names follow ErgData's PM model enums, display type/units the Concept2 CSAFE spec; unknown values keep their number. It is queried `settleDelay` (0.4 s) after a key press, since the PM acks before it redraws.

## Forwarding vs Mocking

The iOS app does not switch modes directly. It always talks to `/tmp/impossible.sock`; the Mac app's selected mode determines behavior.

The segmented **Off / Mock / Passthrough / Replay** picker is bound to a `ModeTransitionController<ImpossiBLEMode>` (`ImpossiBLEMode` is SimBridgeShell's `ProviderMode` trio plus `.replay`, persisted under the same key and raw values) (the single source of truth the picker binds to) so it reflects the choice immediately instead of inferring it from mid-transition server state; transitions are serialized and always bounce through a `server.stop`, so a connected client observes a disconnect instead of a silent behavior change. The menu bar icon reflects the active mode: strikethrough when off, plain Bluetooth when forwarding, dot-badged when mocking, R-badged when replaying. The control panel is a borderless AppKit panel centered under the status item. It is persistent by default. The footer carries label-less icon toggles with tooltips: **Launch at Login** (`power`) and **Dismiss on Switch** (`eye.slash`, restores popover-style hiding on app deactivation). Changing a toggle shows a brief inline confirmation between the toggles and the Quit button.

In Passthrough mode, the bridge reports actual communication activity through its `activityHandler`, aggregated by `PassthroughActivityMonitor` for the panel list and the icon pulse (the pre-3.0 `/tmp/impossible-passthrough-activity.json` snapshot file is gone). The list intentionally ignores scan/discovery/connect activity and only records GATT/L2CAP operations: characteristic read/write, descriptor read/write, subscribe/unsubscribe, L2CAP open/read/write/close.

### Replay

Replay mode (`MockServer.ServeMode.replay`) is shaped like Passthrough but never touches hardware: `ReplayEngine` writes every client message to `/tmp/impossible-replay-recordings/replay-<date>-<pid>-<ptr>.json`, using the same `CBSWireRecorder` (and therefore the same JSON format) as Passthrough's opt-in recording. One file per client session; `tearDownClientState()` resets the engine. The panel shows the message count, the current file with a Reveal button, and a folder button opening the Passthrough recordings folder.

Answers are delegated to a `ReplayResponder`. Per client session it gets `begin(send:)` (called from `MockServer.handleClientConnected` in Replay mode), every client message via `handle`, and `reset` on teardown or replacement. `send` may be called any number of times from any queue; sent messages are recorded as `toClient` entries, and sends from an ended session are dropped so they can never reach the next client. Without a loaded recording the responder is `SilentReplayResponder`: the client sees a powered-on central that never discovers anything.

Dropping a recording on the panel's drop zone (or clicking it to choose a file) runs `MockServer.loadReplayScript`: `ReplayScript.load` validates the file (array of `{seq, timestamp, direction, message.type}` entries, unique `seq`s, ISO 8601 timestamps), and the panel shows a checkmark or an X with the first error. A valid script is **not played until Start** (`MockServer.startReplay`; `replayStarted`, run status `.ready`): loading — or loading another file, or clearing — stops Replay, so matching, speed and the PM5 clock can be set first, and until then the app only gets the silent responder (powered on, nothing to discover; its traffic is still recorded). Stop (`stopReplay`) returns to ready. Once started, the script's responder (strict: `ScriptedReplayResponder`) plays entries in `seq` order:

- Before each entry it waits for the timestamp distance to the previous entry.
- `toClient` entries are sent exactly as recorded, the same path bridge replies take.
- `fromClient` entries block until the client sends a matching message, or fail the run after 60 s. Matching ignores `seq`, timestamps, `value`/`valueB64`, and `_`-prefixed shim bookkeeping (`_scannerKeys`); every other key must be equal. Client messages are buffered, so one that arrives early (during a delay) still matches; messages the script never asks for are ignored.
- Once the run passes or fails, the client is no longer answered, but its traffic is still recorded.

While started, a run starts with every client connection. The restart button on the loaded recording (`MockServer.restartReplay`, enabled while started and a client is connected) replays it from the first entry for the current client. `MockServer.replayRun` carries the run status for the panel; `replayRunID` filters out late updates from a replaced responder. The loaded script is not persisted across launches.

`ReplayOptions` (persisted; `MockServer.setReplayOptions`, the controls row under a loaded recording) chooses **Strict/Relaxed**, a **speed** (1/2/5/10×) and **Move PM5 clock to now**. `makeReplayResponder` wraps the choice in a `ReplayRunResponder`, which builds a fresh inner responder — `ScriptedReplayResponder(speed:)` or `RelaxedReplayResponder` — on every client session and restart, from `ReplayScript.shiftingPM5Times(to: Date())` when the clock option is on, so each run is logged at its own time; statuses from a replaced inner responder are dropped. `RelaxedReplayResponder` and `ReplayPM5Time.swift` are Swift ports of the library's `CBSReplayRelaxed.m` / `CBSReplayPM5Time.m` (CSAFE helpers extend the PM5 remote's `CSAFE` enum) — **keep each pair in step**. The menu app does not accept replay control messages from the app; that lives in the library (below).

### In-process replay (library side)

`ImpossiBLESetupReplay(path, &error)` / `ImpossiBLEStartReplay` / `ImpossiBLEStopReplay` / `ImpossiBLECleanupReplay` and `ImpossiBLESetReplayStatusHandler` (`Sources/ImpossiBLE/CBSReplay.m`) replay a recording **inside the app process**. No menu bar app needs to run. A UI test bundles the JSON and passes its path to the app (the Simulator shares the host file system).

- **Environment trigger.** If the process is launched with `IMPOSSIBLE_REPLAY_RECORDING` set to a recording path, `+load` calls `CBSReplayStartFromEnvironment`, which sets up and starts that replay before the app can create a `CBCentralManager`. A UI test only sets `launchEnvironment`; the app calls no ImpossiBLE API. Failures are logged (`replay from IMPOSSIBLE_REPLAY_RECORDING failed: …`), not raised.
- **Restart from a UI test.** A replay started from `IMPOSSIBLE_REPLAY_RECORDING` also observes the Darwin notification `com.impossible.replay.restart` (`ImpossiBLEReplayRestartNotification`), the one signal a UI test runner can send the app from its own process. It only restarts the player: back to the first entry (dropping messages buffered for the old run), then playing normally. Nothing is synthesized for the app — no disconnect, no Bluetooth state change — so the test brings the app to wherever the recording starts.

- **Mechanism.** `CBSConnectionSetLocalProvider` replaces the socket with an in-process provider. `CBSConnectionSend` hands messages to it, the player answers via `CBSConnectionDeliverLocal` (on a dedicated serial queue, into the activator's normal message handler), and `CBSConnectionIsConnected()` reports YES. The activator is untouched and cannot tell the difference from the menu app in Replay mode.
- **Attaching** bounces through `poweredOff` when the socket was connected (so provider-owned peripherals get the usual disconnect synthesis), wakes the reader with `shutdown()`, and suppresses connect and reconnect. It is synchronous, so a replay set up before the first `CBCentralManager` already reads as powered on. Setup also calls `CBSEnsureConnectionOpen()`, so the activator's handlers exist before any replayed message arrives. **Detaching** (cleanup) reports `poweredOff`, then reconnects the socket if anything had asked for it (`gOpenRequested`).
- **Player.** `CBSReplayPlayer` mirrors the Mac's `ReplayScript`/`ScriptedReplayResponder`: same validation, `seq` ordering, timestamp delays, matching rules, and 60 s timeout. **Keep the two in step.** Difference: app messages sent between setup and the first start are buffered and count, because setup and the app's first scan are usually adjacent. Results go to the status handler (main queue), to the log (`ImpossiBLE: replay passed` / `FAILED — …`), and — for passed/failed — to the Darwin notifications `com.impossible.replay.passed` / `.failed` (`ImpossiBLEReplayPassedNotification` / `FailedNotification`), which a UI test runner can observe.
- **Options.** `ImpossiBLESetReplayOptions(speed, matching)` applies to the next setup; the environment trigger reads `IMPOSSIBLE_REPLAY_SPEED` and `IMPOSSIBLE_REPLAY_MODE` (`strict`/`relaxed`). Speed divides every recorded delay, never the 60 s wait for the app. The Mac app mirrors all three options (speed, matching, PM5 clock) — see Replay above.
- **PM5 clock** (`CBSReplayPM5Time.m`, on by default; `ImpossiBLESetReplayPM5CurrentTime`, `IMPOSSIBLE_REPLAY_PM5_TIME=recorded` to opt out). At setup, before the player is built, every Concept2 PM5 timestamp in the recording moves by the one offset that makes the last workout summary read as now (minute precision). Without it a replayed workout carries its recorded log date and the Concept2 Logbook answers `409 Duplicate Result`, so ErgData folds it into the original entry. Rewritten: `CE060039`/`CE06003A` bytes 0–3, `CE060080` multiplexed `0x39`/`0x3A`/`0x3C` bytes 1–4 (date little endian: month 4 bits, day 5, year-2000 7; then minutes, hours), and CSAFE replies on response channels — `GET_DATETIME` (`0x85`: hour 1–12, minute, AM/PM, month, day, year big endian) plus any summary stamp inside reply data, little *or big* endian (the `0x6A` logged-workout record is big endian; missing that form left the old date in and the server still saw a duplicate). Changed frames get their checksum (XOR after the `00 FD` addresses, status included) recomputed and are re-stuffed. Nothing else changes.
- **Relaxed matching** (`CBSReplayRelaxedPlayer`, `CBSReplayRelaxed.m`) exists for apps whose traffic differs between runs — ErgData's polling timers, `Set`-ordered subscriptions, and wall-clock date writes made strict replay of a real PM5 workout unworkable. At load it pairs each recorded request with its replies (reply type and ids from `CBSReplayReplyRules`, first unclaimed within 30 s) and, on *request channels* (default `CE060021` → `CE060022`, `IMPOSSIBLE_REPLAY_CHANNELS=req:resp,…`), reassembles chunked writes into CSAFE frames and attaches the response-characteristic notifications up to the next write. Every remaining `toClient` entry is the *timeline*. At run time each app request is answered on demand from its group (same relevant keys, plus `CBSReplayCSAFESignature` — command bytes only, data ignored — for frames): an identical value among the next 64 unused first, else the next unused, else the last one used again. Leading frame chunks and unmatched writes get a synthesized `didWriteValue`, unmatched `setNotify` a synthesized `didUpdateNotification`; unmatched requests are counted, not failed. The timeline only waits for *anchors* — the first recorded request of each group — that precede an entry, seen in any order, with the 60 s timeout; it passes once played and all anchors are seen, and keeps answering requests afterwards. Ids in requests and replies are the recording's, which works because the app only knows ids from replayed discovery. A peripheral keeps advertising until the app connects to it: while the app scans, each discovered peripheral's last `didDiscover` is repeated every second, real time. Without it a recording that connected quickly holds a few advertisements that, sped up, vanish before an app with a "not seen for 2 s" rule (ErgData) can show the device.
- Setting up again swaps the player without bouncing the connection. On device builds every call returns NO.

Mock capture runs entirely in process: `CaptureSession` owns its **own** `CBSPassthroughBridge` instance (its own `CBCentralManager`), so capturing no longer stops or restarts whatever mode is currently serving the simulator. Opening **Capture** scans live advertisements and shows filtered capture results. Saving a capture runs a deep inspection pass for selected connectable devices: connect, discover services, discover characteristics, discover descriptors, read readable characteristic values, and read descriptor values. Non-connectable devices or devices that fail inspection are saved advertisement-only. After save, the captured configuration is loaded for tuning.

Capture rows hide unnamed devices by default, sort more "interesting" advertisements first (more advertised services, named, connectable, manufacturer data, RSSI), and use a factory icon to indicate manufacturer-specific advertisement data.

For local development of the menu bar app, prefer:

```bash
make mac-relaunch
```

That target packages the debug Mac binary into `ImpossiBLE-Mac.app`, ad-hoc signs it, stops stale Mac processes, and opens the bundle.

## Build And Verification

Use these checks before preparing changes for commit:

```bash
make mac-clean mac
cd Sources/ImpossiBLE-Mac && swift build   # standalone SPM check
cd Sources/ImpossiBLE-Mac && swift test    # ProviderKit tests (DTOs, MCP session, control socket, store)
xcodebuild -project SampleApp/SampleApp.xcodeproj -scheme SampleApp -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' build
plutil -lint Sources/ImpossiBLE-Mac/Resources/Info.plist Sources/ImpossiBLE-Mac/Resources/entitlements.plist
```

For Gatekeeper-related work:

```bash
make mac-assess
make mac-notarize NOTARY_PROFILE="impossible-notary"
```

`make mac-assess` will fail for ad-hoc signed local builds. A distributable Mac app needs a `Developer ID Application` identity and notarization.

## Debugging Passthrough

The passthrough bridge has gated verbose tracing, off by default. Enable it with the `IMPOSSIBLE_PASSTHROUGH_DEBUG` environment variable (works when running the Mac binary directly) or by creating the `/tmp/impossible-passthrough.debug` sentinel file (works for the `open`/launchd launch path, where env vars don't propagate), then restart the Mac app. Traces cover the L2CAP lifecycle, stream events, write byte counts, and message dispatch, prefixed with `DEBUG: ImpossiBLE-Passthrough:`. `NSLog` goes to both stderr (when run directly) and the unified log; the unified log redacts dynamic args as `<private>`, so capture stderr for full detail (`make mac-dev`).

The bridge can also record its wire traffic as JSON, off by default and never persisted: the **Record** button at the bottom of the Passthrough view (`MockServer.setPassthroughRecording`, state in `passthroughRecording`) calls `CBSPassthroughBridge.startRecording(toDirectory:)` / `stopRecording`, and turns red with a Stop label while recording. A toggle made before the bridge exists is applied when it is created. Files go to `/tmp/impossible-passthrough-recordings/` (the folder button opens it; Replay has the same button, since that is where its recordings come from). Each client session (bridge instance until `reset`) writes one `passthrough-<date>-<pid>-<ptr>.json` file, opened with the session's first message after recording starts, holding an array of `{seq, timestamp, direction, type, message[, valueHex]}` entries, where `direction` is `fromClient` or `toClient`, `message` is the exact protocol message, and `valueHex` decodes any base64 payload. The array is spliced in place so the file is valid JSON after every entry. Capture sessions own their own bridge and never record.

**Recordings hold the app's view, not the bridge's.** The bridge never records on its own; `MockServer` calls `bridge.recordMessage(_:direction:)` — `fromClient` in `handleMessage` *before* `pm5Engine.appMessage` (a held write is recorded when the app sent it), `toClient` in `forwardToApp`, the one path every reply to the app takes (including those the PM5 engine held and released). The engine's own writes enter the bridge directly and the replies it consumes never reach `forwardToApp`, so PM5 remote use leaves no trace in a recording. Any new code that sends to the app in Passthrough must go through `forwardToApp`.

Agents drive recording with `passthrough_record_start {label?}` (Passthrough mode only; `label` becomes the sanitised file prefix, `MockServer.recordingPrefix`), `passthrough_record_stop` (returns `path` and `entryCount`), and `passthrough_recordings_list`; `get_status` carries `passthroughRecording`. These share state with the panel's Record button.

On a provider-connection drop the simulator-side shim closes open L2CAP channels and synthesizes `didDisconnectPeripheral` for every owned peripheral (`cbs_handle_daemon_disconnect`), so the host app re-establishes instead of hanging on a dead channel.

## Known Follow-ups

- **Socket-ownership guard.** Nothing stops a second copy of the Mac app (or, later, the Simsalabim suite app) from `unlink`+`bind`ing `/tmp/impossible.sock` and stealing it from a running instance. Before binding, probe the existing socket with `connect()`; refuse to start the provider when a live listener answers, and only unlink a stale socket file. Planned as part of the shared SimBridgeKit extraction (see `../Simsalabim/PLAN.md`).

## Release Checklist

When cutting a new ImpossiBLE release:

- Bump the version in **three** places and keep them identical:
  `kCBSLibraryVersion` in `Sources/ImpossiBLE/CBSConnection.m`,
  `AppVersion.current` in `Sources/ImpossiBLE-Mac/Models/AppVersion.swift`, and
  `CFBundleShortVersionString` in `Sources/ImpossiBLE-Mac/Resources/Info.plist`.
- Update the Homebrew formula in `mickeyl/homebrew-formulae`. Bump
  `Formula/impossible.rb` to the new tag, update the tarball SHA256, run
  `brew audit --strict --online impossible` and `brew style
  Formula/impossible.rb`, then commit and push the tap update. Note: since
  3.0.0 there is no `impossible-helper` anymore — the formula must only build
  and install the Mac app. It should also link
  `ImpossiBLE-Mac.app/Contents/Helpers/impossible-mcp` into `bin` (as
  `make install` does) so agents can be pointed at a stable path.

## Generated Artifacts

Do not commit generated bundles or build output:

- `.build/`
- `.swiftpm/`
- `*.app`
- `ImpossiBLE-Mac.zip`
- Xcode `xcuserdata/`
