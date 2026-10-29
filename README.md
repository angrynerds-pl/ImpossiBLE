<p align="center">
  <img src="logo.png" alt="ImpossiBLE logo" width="320">
</p>

# ImpossiBLE

**Use real Bluetooth Low Energy hardware from the iOS Simulator.**

Apple's `CoreBluetooth` framework does not function inside the iOS Simulator — peripherals cannot be discovered, connections fail silently, and the `CBCentralManager` state never reaches `poweredOn`. ImpossiBLE makes the impossible possible by transparently bridging BLE operations from your simulated app to actual Bluetooth hardware on the host Mac.

## Simulator Reality (and Why This Exists)

Older iOS Simulator builds exposed *some* CoreBluetooth behavior, but it was incomplete and eventually fell out of maintenance. Apple has long recommended that developers test Bluetooth flows on real devices, and that recommendation still stands. ImpossiBLE is not a replacement for on-device testing — it is a convenience layer so you can iterate faster between device runs.

## How It Works

ImpossiBLE is a two-process architecture:

1. **Library** (linked into your iOS app) — Uses Objective-C runtime swizzling to intercept all `CBCentralManager` calls at load time. Instead of talking to the (non-functional) simulated Bluetooth stack, it forwards every operation as JSON messages over a Unix domain socket.

2. **Mock menu bar app** (runs natively on macOS) — The single provider owning `/tmp/impossible.sock`. In **Mock** mode it serves configurable virtual BLE peripherals; in **Passthrough** mode it translates the same messages into real `CoreBluetooth` API calls against the Mac's Bluetooth hardware — both in one process, switched by a segmented **Off / Mock / Passthrough** control.

The custom menu bar window stays open while you switch apps, or can be set to dismiss on app switch from the footer. The menu bar icon reflects the active mode (strikethrough when off, plain when forwarding, dot-badged when mocking) and flashes on mock or Passthrough traffic so you can see activity at a glance. In Passthrough mode, the app lists only devices your simulator app actually communicates with through GATT or L2CAP operations, not devices that were merely discovered while scanning. The Mac app ships with several stock configurations — from a single heart rate monitor to a dense 12-device sensor environment — and lets you save/load your own. It can also capture nearby BLE advertisements into a new mock configuration; the factory icon in capture results means that advertisement includes manufacturer-specific data. A "Launch at Startup" option in the footer installs a LaunchAgent for automatic login startup. Server state is persisted and auto-restored on launch.

Your app code remains unchanged — `CBCentralManager`, `CBPeripheral`, delegate callbacks, and all other CoreBluetooth types work as expected.

An app can also **bring its own mock configuration** instead of relying on the menu bar selection; see [Client-Supplied Configurations](#client-supplied-configurations) below.

<p align="center">
  <img src="screenshot-mock.png" alt="Mock mode" width="300">
  &nbsp;&nbsp;
  <img src="screenshot-passthrough.png" alt="Passthrough mode" width="300">
</p>

### Under the Hood (Technical Details)

- **Method swizzling on the simulator**: the library swizzles `CBCentralManager` init/state/scan/connect APIs at `+load` and routes them to a local transport. The socket connection to the provider is opened lazily on the first `CBCentralManager` instantiation, so apps that link ImpossiBLE without using CoreBluetooth do not contact the provider.
- **Multi-central multiplexing**: multiple `CBCentralManager` instances in the same app work independently, each with its own peripheral store, scan filters, and delegate callbacks — matching real CoreBluetooth behavior where peripherals and their discovered services are shared across managers.
- **Proxy CoreBluetooth objects**: it creates shim `CBPeripheral`, `CBService`, `CBCharacteristic`, `CBDescriptor`, and `CBL2CAPChannel` objects so your app sees real types.
- **Transport**: newline-delimited JSON over a Unix domain socket (`/tmp/impossible.sock`), with auto-reconnect.
- **Connection-aware state**: `CBCentralManager.state` reflects actual socket connectivity — `poweredOn` when connected to a provider, `poweredOff` when not. `centralManagerDidUpdateState:` fires automatically on transitions, so your app reacts to the provider starting or stopping just like it would to real Bluetooth state changes. If the provider connection drops while peripherals are connected, the library also delivers `centralManager:didDisconnectPeripheral:` for each and closes any open L2CAP channels, so your disconnect handling runs instead of leaving a stale connection.
- **Data encoding**: characteristic values and L2CAP payloads are base64-encoded across the wire.
- **Service filter fidelity**: Passthrough enforces `discoverServices:` filters to match iOS behavior, even though macOS CoreBluetooth returns all cached services.
- **Version handshake**: the library introduces itself with a `hello` message (library version, bundle id, pid), so the panel can show which app and library version is connected and version skew is diagnosable instead of silent.
- **Callback fidelity**: delegate callbacks are dispatched back onto the original `CBCentralManager` delegate queue.

## Features

- Multiple `CBCentralManager` instances with independent scan/connect lifecycles
- Scan for peripherals with service filters
- Connect and disconnect
- Discover services, characteristics, and descriptors
- Read, write (with/without response), and notify
- L2CAP channel support (with timeout handling)
- Passthrough device activity list for actual GATT/L2CAP communication
- Persistent menu bar control panel with optional dismiss-on-app-switch behavior
- Connection-aware `CBManagerState` with automatic `centralManagerDidUpdateState:` callbacks
- Auto-reconnect when the provider starts after the app
- Automatic activation — no setup code required; the provider connection is opened lazily on the first `CBCentralManager` instantiation
- Client-supplied mock configurations, so tests can carry their own virtual peripherals
- Local MCP server so AI agents can switch modes, manage and record mock configurations, drive and inspect the app under test, and remote-control a Concept2 PM5 — see [Agent Control (MCP)](#agent-control-mcp)

## Requirements

- macOS with Bluetooth hardware
- Xcode 15+ (Swift Package Manager)
- Codesigning certificate recommended (optional). If none matches `MAC_CODESIGN_MATCH`, the Mac app is signed ad hoc with a warning. Note that Passthrough mode needs the Bluetooth entitlement under the Hardened Runtime, so a properly signed build is required for distributed copies.

## Quick Start

```bash
# Clone, build, and start the Mac menu bar app
cd ImpossiBLE
make mac-run

# Select "Mock" or "Passthrough" in its panel.

# In Xcode: add ImpossiBLE as a local Swift package dependency,
# then build and run your app in the iOS Simulator.
```

## Client-Supplied Configurations

Mock mode normally serves whatever configuration is selected in the menu bar app. That is convenient for exploring, but awkward for tests: the fixture lives somewhere else, and it silently goes stale. It breaks entirely when the service UUIDs under test are *computed* at runtime rather than fixed — a saved configuration then describes the wrong device and the test just sees an empty scan.

So an app can upload its own configuration:

```swift
import ImpossiBLE

let configuration: Data = try JSONEncoder().encode(myFixture)
if ImpossiBLESetMockConfiguration(configuration) {
    // The mock now serves these devices instead of the menu bar selection.
}
```

The payload has the same shape as a saved configuration file, so an exported configuration can be handed over verbatim:

```json
{
  "id": "…",
  "name": "Two peers and a stranger",
  "devices": [ { "id": "…", "name": "…", "advertisedServiceUUIDs": ["…"], "services": [ … ] } ]
}
```

Three properties are worth knowing:

- **Ephemeral.** The uploaded configuration is held in memory by the provider. It is never written to your saved configurations, and it is discarded when the app disconnects or another app connects. Your own selection resumes automatically.
- **Visible.** While a client configuration is active the menu bar panel shows it in place of the selection — which app supplied it, its name, and a read-only list of the devices actually being served.
- **Verified.** The provider acknowledges with `didSetMockConfiguration`, reporting a decoding failure rather than leaving a malformed fixture to look like an empty environment.

`ImpossiBLEIsProviderConnected()` waits briefly for the socket, so it is safe to call at start-up before any `CBCentralManager` exists. On device builds every function is a no-op returning `NO`, so the same code can run in both places and simply use the real radio.

### L2CAP Against Yourself

A mock provider cannot answer an L2CAP channel: nothing on its side knows what bytes your protocol expects. Only your app does. So rather than inventing a peer, ImpossiBLE hands your app the *other end* of the channel:

```swift
ImpossiBLESetMockL2CAPHandler { psm, input, output in
    // The peer end. Speak your own protocol back at yourself.
}
```

`openL2CAPChannel` is then served in process — a `socketpair` backs the channel, your app gets one end as a normal `CBL2CAPChannel`, the handler gets the other as an already-open stream pair. The provider is not involved, so the loop runs at memory speed.

This matters most for apps whose peripheral role cannot run in the Simulator at all: `CBPeripheralManager` is unavailable there, but the *framing* on both sides is usually the same code. Playing both roles exercises encode → wire → decode against real CoreBluetooth objects.

The handler applies only while a client-supplied configuration is active. In Passthrough mode the real channel is used and a registered handler is ignored, so a loopback can never quietly shadow the hardware you switched to.

### Limitations

Pin the provider alongside the library: a client built against 2.4.0 talking to an older provider has its upload ignored as an unknown message type and then scans against whatever that provider happens to serve. Since 3.0.0 the library reports its version on connect and the panel shows it next to the connected client, so a mismatch is visible instead of silent.

## Forwarding vs Mocking

The iOS app always uses the same ImpossiBLE integration and connects to `/tmp/impossible.sock`. The Mac menu bar app is the single provider owning that socket; the segmented **Off / Mock / Passthrough** picker selects what it serves. In Passthrough mode it also shows the real BLE devices that have seen actual read/write/subscribe/L2CAP traffic, with a short active indicator for current communication.

Passthrough uses macOS Bluetooth directly from the Mac app, so the first activation prompts for Bluetooth permission. Ad-hoc signed development builds get a fresh signing identity on each rebuild, which makes macOS re-prompt.

For headless setups, the app's state can be seeded before launch instead of clicking the panel:

```bash
defaults write com.impossible.ble-mac SelectedProviderMode passthrough   # or: mock / off
make mac-run
```

### Capturing Mock Configurations

<p align="center">
  <img src="screenshot-capture.png" alt="Capture mode" width="300">
</p>

The Mac menu bar app can capture nearby BLE devices into a new editable configuration. Click **Capture**, start scanning, choose the devices to include, then save the configuration.

Capture results hide unnamed devices by default and sort likely useful devices first: advertisements with more service UUIDs, named devices, connectable devices, manufacturer-specific data, then stronger RSSI. Enable **Show Unnamed** when you need to inspect the full noisy environment. The factory icon means the advertisement includes manufacturer-specific data.

When you save a capture, ImpossiBLE performs a deeper inspection for selected connectable devices before writing the configuration. It connects to each device, discovers services, characteristics, and descriptors, and reads values where CoreBluetooth allows reads. Devices that are not connectable, fail to connect, or time out are still saved from their advertisement data. Secured characteristics may fail or trigger normal pairing/security behavior from macOS.

## Agent Control (MCP)

AI agents such as Claude Code can drive ImpossiBLE through a local [MCP](https://modelcontextprotocol.io) server. Anything you can do in the menu bar panel, an agent can do too — plus a few things the panel cannot:

- switch between **Off / Mock / Passthrough**;
- manage mock configurations: list, select, create (import), save, rename, duplicate, delete, export;
- edit the devices being served;
- record real devices with a capture, including the deep GATT inspection;
- in **Mock** mode, drive the app under test (live values, notifications, disconnects, injected failures) and check what it did (an activity log of every request, with the bytes read and written);
- in **Passthrough** mode, watch real traffic and — with a Concept2 PM5 — press its buttons and read its state while the app stays connected.

### How it works

```
┌──────────────┐  stdio (MCP)  ┌───────────────┐  /tmp/impossible-control.sock  ┌──────────────────┐  /tmp/impossible.sock  ┌───────────────┐
│ Agent        │ ────────────▶ │ impossible-mcp│ ─────────────────────────────▶ │ ImpossiBLE-Mac   │ ◀───────────────────── │ App in the    │
│ (Claude Code)│ ◀──────────── │ (shim)        │ ◀───────────────────────────── │ (menu bar app)   │ ─────────────────────▶ │ iOS Simulator │
└──────────────┘               └───────────────┘                                └──────────────────┘                        └───────────────┘
```

- **`impossible-mcp`** is the MCP server your agent launches (stdio transport). It is bundled inside the app at `ImpossiBLE-Mac.app/Contents/Helpers/impossible-mcp`, and `make install` links it to `~/.local/bin/impossible-mcp`. It only passes messages through to the running menu bar app.
- **The menu bar app does the work**: it owns the provider, the mock configurations, and the Bluetooth hardware, so the panel and the agent always see the same state. Whatever an agent changes shows up in the panel immediately.
- **If the app is not running**, the shim launches it and waits up to 15 s. If the app quits or is relaunched mid-session, the shim reconnects on the next call; a call that was in flight at that moment gets an error and can simply be retried.
- **A separate socket**, `/tmp/impossible-control.sock`, so agents can never take over the simulator app's connection on `/tmp/impossible.sock`. Several agents can be connected at once.
- **Local only**: the socket is readable and writable only by your macOS user, and connections from other users are rejected.

### Setup, step by step

1. **Build and install the app** (once, and after updates):

   ```bash
   make install
   ```

   This installs `~/.local/bin/ImpossiBLE-Mac.app` and links `~/.local/bin/impossible-mcp`. For a development build, `make mac-relaunch` puts the shim at `./ImpossiBLE-Mac.app/Contents/Helpers/impossible-mcp` instead.

2. **Start the app** (`make mac-run`, or open it from Finder). Starting it is optional — the shim launches it when needed — but the first launch asks for Bluetooth permission, which is easier to grant with the app in front of you.

3. **Check that agent control is on.** In the panel footer, the **terminal** icon is highlighted when agents are allowed (the default). Click it to switch agent control off or on. A green dot on it means an agent is connected right now.

4. **Register the server with your agent.**

   *Claude Code* — available in every project:

   ```bash
   claude mcp add --scope user impossible -- ~/.local/bin/impossible-mcp
   ```

   or just for the current project: `claude mcp add impossible -- ~/.local/bin/impossible-mcp`.

   *Other MCP clients* (Claude Desktop, Cursor, …) — add a stdio server to the client's MCP configuration, using the absolute path:

   ```json
   {
     "mcpServers": {
       "impossible": {
         "command": "/Users/<you>/.local/bin/impossible-mcp"
       }
     }
   }
   ```

5. **Verify.** Run `claude mcp list` (it should show `impossible … ✓ Connected`), or type `/mcp` inside a Claude Code session. Then ask the agent: *"What is the ImpossiBLE status?"* — it calls `get_status` and reports the mode, the connected simulator app, and the active configuration.

6. **Run your app in the iOS Simulator** with the ImpossiBLE library linked (see [Quick Start](#quick-start)). From now on the agent can switch modes, serve devices, and watch what the app does.

To check the server without an agent, pipe a request straight into the shim:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_status","arguments":{}}}' \
  | ~/.local/bin/impossible-mcp
```

### What you can ask for

You talk to the agent in plain language; it picks the tools. For example:

- *"Switch ImpossiBLE to mock and load the Heart Rate Monitor configuration."*
- *"Record my PM5 as a mock configuration called PM5, with its full GATT database."*
- *"Create a configuration with a thermometer advertising 181A whose 2A6E reads 23.4 °C."*
- *"Stream heart rates from 70 to 150 bpm into the app, one per second."*
- *"Make the next read of 2A19 fail with insufficient authentication, then check how the app handled it."*
- *"Which commands did the app write to the device after I tapped Start?"*
- *"Press Menu on the PM5 and tell me what screen it is on."*
- *"Export the PM5 configuration to Tests/Fixtures/pm5.json."*

### Tool reference

Devices and configurations can be referred to by **id or name** (names match case-insensitively). Tools that only apply in one mode explain that in their result instead of failing silently.

**Status and mode**

| Tool | Arguments | What it does |
|---|---|---|
| `get_status` | — | Mode, provider socket state, connected simulator app (bundle id, pid, library version), active configuration, any configuration the app uploaded itself, capture state. Start here. |
| `set_mode` | `mode`: `off` \| `mock` \| `passthrough` | Switches mode and waits until done. The simulator app sees Bluetooth turn off and on again and reconnects. Selecting the current mode does nothing. |

**Mock configurations**

| Tool | Arguments | What it does |
|---|---|---|
| `list_configurations` | — | Built-in and saved configurations; `active` marks the loaded one. |
| `get_configuration` | `configuration` | Full contents: devices, services, characteristics, descriptors. |
| `select_configuration` | `configuration` | Loads it into the working set (the devices served in mock mode). |
| `create_configuration` | `name`, `devices[]`, `select`?, `replace`? | Creates a configuration from device definitions — also the way to import one. Loads it unless `select: false`. |
| `save_working_set_as` | `name`, `replace`? | Saves the current working set, including edits. |
| `rename_configuration` | `configuration`, `newName` | Built-in configurations cannot be renamed. |
| `duplicate_configuration` | `configuration`, `newName`? | Copies any configuration, built-ins included. |
| `delete_configuration` | `configuration` | Built-in configurations cannot be deleted. |
| `export_configuration` | `configuration`, `path`?, `overwrite`? | JSON in the format `ImpossiBLESetMockConfiguration()` takes, returned as text or written to `path`. |

**Working set** (the devices served in mock mode)

| Tool | Arguments | What it does |
|---|---|---|
| `list_devices` | — | Devices with id, name, enabled, connectable, RSSI, advertised services. |
| `get_device` | `device` | Full GATT definition. |
| `add_device` | `device` | Adds a device; omitted fields get defaults. |
| `update_device` | `device`, `changes` | Changes only the given fields; `services`, when given, replaces the whole GATT tree. |
| `set_device_enabled` | `device`, `enabled` | Shows or hides a device from the app without deleting it. |
| `duplicate_device` / `delete_device` | `device` | |

Working-set edits are saved immediately but only change a stored configuration through `save_working_set_as`.

**Recording real devices**

| Tool | Arguments | What it does |
|---|---|---|
| `capture_start` | `advertisingService`? | Starts scanning with the Mac's Bluetooth, independent of the current mode. Wait a few seconds before reading results. |
| `capture_results` | `onlyConnectable`?, `includeUnnamed`?, `nameContains`?, `advertisingService`?, `limit`? | Devices seen so far, most interesting first. Unnamed devices are hidden unless `includeUnnamed`. |
| `capture_save` | `name`?, `deviceIds`? or filters, `inspect`?, `select`?, `replace`? | Saves the chosen devices as a configuration. With `inspect` (default) each connectable device is connected to and its services, characteristics, descriptors and readable values are read — several seconds per device, with progress updates. `inspect: false` saves advertisement data only, without connecting. |
| `capture_stop` | — | Stops scanning; results stay available. |

**Driving and checking the app (mock mode)**

| Tool | Arguments | What it does |
|---|---|---|
| `set_characteristic_value` | `device`, `characteristic`, `service`?, `value` or `valueText`, `notify`? | Changes a value live. Sent as a notification if the app subscribed; every later read returns it. Lasts until the app disconnects (use `update_device` to change the stored value). |
| `disconnect_device` | `device`, `error`? | Drops the app's connection as if the link was lost; the app gets `didDisconnectPeripheral` with an error. |
| `inject_failure` | `device`, `operation`, `characteristic`?, `behavior`?, `error`?, `attError`?, `count`? | Makes the next request(s) fail. `operation`: `connect`, `discoverServices`, `discoverCharacteristics`, `read`, `write`, `readDescriptor`, `writeDescriptor`, `setNotify`, `readRSSI`. `behavior`: `error` (default; reads and writes carry a `CBATTError` code, default 14) or `noResponse` (never answers). `count` 0 keeps failing until cleared. |
| `list_failures` / `clear_failures` | `id`? | Armed failures; clear one or all. |
| `mock_activity` | `since`?, `limit`? | Everything the app did, oldest first: scans, connects, discovery, reads (with the value returned), writes (with the bytes written), subscriptions, values agents pushed, failures that fired — plus current connections and subscriptions. Pass the previous `lastSeq` as `since` to get only new events. |
| `clear_mock_activity` | — | Empties the log, e.g. before the step you want to check. |

**Passthrough**

| Tool | Arguments | What it does |
|---|---|---|
| `passthrough_activity` | — | The real devices the app talks to and its latest GATT/L2CAP operation on each. |
| `terminate_simulator_app` | — | Sends SIGTERM to the connected simulator app, e.g. to restart it with a clean Bluetooth state. |

**PM5 remote** (passthrough, with the app connected to a Concept2 PM5 — see [PM5 Remote](#pm5-remote))

| Tool | Arguments | What it does |
|---|---|---|
| `pm5_status` | — | Whether the remote is on, the connected PM5s and whether they are ready, and the last known state. |
| `pm5_set_remote_enabled` | `enabled` | Same as the switch on the panel's PM5 Remote card. Off by default. |
| `pm5_press_key` | `key`: `A`–`E`, `units`, `display`, `menu`; `device`? | Presses a PM5 button and returns the PM5's state just after. |
| `pm5_get_state` | `device`? | Operational state, workout state, rowing state, workout and interval type, display type and units, battery, last screen command. |
| `pm5_screen_command` | `command`: `prepareToWorkout` \| `terminateWorkout` \| `rearmWorkout` \| `goToMainScreen`; `device`? | Workout-screen actions. `terminateWorkout` ends the workout in progress. |
| `pm5_send_csafe` | `payload` (hex), `awaitResponse`?, `writeWithoutResponse`?, `device`? | Any CSAFE command, unframed (ImpossiBLE adds framing, checksum, byte stuffing). Returns the PM5's reply. |
| `pm5_trace` | `since`? | Recent CSAFE traffic on the PM5's command and response characteristics: what the app wrote, what the remote sent, and what happened to each reply (passed to the app or kept back). For debugging. |

### Device format

Tools that take or return devices use JSON that is easy to write by hand:

```json
{
  "name": "Thermo",
  "rssi": -55,
  "isConnectable": true,
  "advertisedServiceUUIDs": ["181A"],
  "manufacturerData": "4C000215",
  "pairingMode": "none",
  "services": [
    {
      "uuid": "181A",
      "characteristics": [
        {
          "uuid": "2A6E",
          "properties": ["read", "notify"],
          "value": "2409",
          "descriptors": [{ "uuid": "2902", "value": "0000" }]
        },
        { "uuid": "2A29", "properties": ["read"], "valueText": "Acme" }
      ]
    }
  ]
}
```

- **Values** are hex (`"0A1B"`, `"0x0A1B"` and `"0a 1b"` all work), or UTF-8 text via `valueText`. Results include `valueText` whenever a value is readable text.
- **properties**: `broadcast`, `read`, `writeWithoutResponse`, `write`, `notify`, `indicate`, `authenticatedSignedWrites`, `extendedProperties` — or the raw bitmask as a number.
- **pairingMode**: `none`, `justWorks`, or `passkey` (with a six-digit `passkey`). **securityLevel** per characteristic: `none` or `encryptionRequired`.
- A device returned by `get_device` can be sent back to `update_device` or `create_configuration` unchanged.

### Workflows

**Record a real device and use it as a mock**

1. *"Record my PM5 as a configuration called PM5."* — the agent runs `capture_start`, `capture_results`, then `capture_save` with inspection. Keep the device awake and not connected to another app.
2. *"Switch to mock and select PM5."* — `set_mode mock`, `select_configuration PM5`.
3. The simulator app now finds the recorded device, with the same name, services, and readable values. A recording is a snapshot: live data such as notifications is not part of it, but the agent can push values with `set_characteristic_value`.

**Test how an app handles a scenario**

1. Load a configuration in mock mode and `clear_mock_activity`.
2. Use the app (or let the agent drive it), pushing values with `set_characteristic_value` and arming failures with `inject_failure` / `disconnect_device` where needed.
3. Read `mock_activity` to check what the app did: which characteristics it read, the exact bytes it wrote, what it subscribed to, and how it reacted to the failures.
4. Keep the scenario: `export_configuration` with a `path` gives your own tests a fixture for `ImpossiBLESetMockConfiguration()`.

**Press PM5 buttons while the app uses the erg**

1. *"Switch to passthrough."* Connect the simulator app to the PM5.
2. *"Turn the PM5 remote on and tell me what the PM5 shows."* — `pm5_set_remote_enabled`, `pm5_get_state`.
3. *"Press Menu, then B."* — each `pm5_press_key` returns the state after the press.

### Troubleshooting

| Symptom | Cause and fix |
|---|---|
| *"ImpossiBLE-Mac is not reachable at /tmp/impossible-control.sock"* | Agent control is switched off (terminal icon in the panel footer), or the app could not be launched. Switch it on, or start the app and check the shim's path. |
| `claude mcp list` shows the server as failed | The path given to `claude mcp add` does not exist — re-run `make install`, or point it at `./ImpossiBLE-Mac.app/Contents/Helpers/impossible-mcp` for a dev build. |
| `get_status` shows `simulatorApp: null` | No app is connected. Launch the app in the simulator. If an app was replaced by another connection (e.g. a second app), relaunch it — a replaced app stops reconnecting on its own. |
| The app shows Bluetooth as off | The mode is **Off**, or the app is not connected (see above). |
| Mock devices do not appear in the app | The mode is not **Mock**, the device is disabled (`set_device_enabled`), or the app uploaded its own configuration, which takes precedence (`get_status` shows `appSuppliedConfiguration`). |
| Capture finds nothing | The Mac's Bluetooth permission was not granted yet (development builds ask again after each rebuild), or the device is off or connected elsewhere. |
| One PM5 button press moves two screens | The PM5 was processing every command twice; `pm5_trace` shows each command answered twice, with the status byte alternating `81`/`01`. Seen once with a stale connection, and gone after restarting ImpossiBLE and reconnecting the app to the PM5. |
| `pm5_*` tools say no PM5 is connected | The mode must be **Passthrough** and the simulator app connected to the PM5. A PM5 is *ready* only once the app has subscribed to its responses. |

### PM5 Remote

When the simulator app is connected to a real Concept2 PM5 through **Passthrough**, a **PM5 Remote** card appears in the panel. Switch it on to press the PM5's buttons — soft keys **A–E**, **Units**, **Display**, **Menu** — from the Mac while the app stays connected. The card also shows what the PM5 is doing — e.g. *Ready* in the menus, or *Workout · Workout row · Force velocity* while rowing — refreshed after each press. Agents get the same through `pm5_status`, `pm5_set_remote_enabled`, `pm5_press_key` (which returns the state after the press), `pm5_get_state`, `pm5_screen_command` (terminate, rearm, main screen, …), and `pm5_send_csafe` for any CSAFE command. The PM5 cannot report which menu page is shown, but its operational state, workout state, and display type together tell where it is.

The commands travel over the app's own connection as CSAFE frames, framed exactly like ErgData's. Apps like ErgData act on every CSAFE reply they receive, so ImpossiBLE keeps the PM5's replies to its own commands away from the app, holds the app's commands back for the moment one is in flight, and only sends when the app is between commands. The remote is off by default.

## Makefile Targets

| Target    | Description                                        |
|-----------|----------------------------------------------------|
| `mac`    | Build the Mac menu bar `.app` bundle              |
| `install` | Build and copy to `~/.local/bin/`                  |
| `mac-relaunch` | Rebuild a debug Mac app bundle and relaunch from the repo |
| `mac-run`| Install and start the Mac menu bar app            |
| `mac-stop` | Stop the running Mac menu bar app               |
| `mac-status` | Show whether the Mac app is running           |
| `mac-log` | Tail system log output from the Mac app          |
| `mac-assess` | Verify signing and Gatekeeper assessment       |
| `mac-notarize` | Notarize and staple the Mac menu bar app    |
| `clean`   | Remove local build artifacts                       |

For local development, the Mac app falls back to ad-hoc signing if no identity matches `MAC_CODESIGN_MATCH`. Gatekeeper will reject ad-hoc signed copies that are quarantined or distributed. For a distributable Mac app, build with a Developer ID Application certificate, for example:

```bash
make mac MAC_CODESIGN_MATCH="Developer ID Application"
make mac-notarize NOTARY_PROFILE="impossible-notary"
```

## Integration

Add ImpossiBLE as a **local Swift package** in your Xcode project pointing to the cloned directory. Then import it:

```swift
import ImpossiBLE
```

That is all. On simulator builds the library installs its CoreBluetooth swizzles at `+load`; the provider socket is opened on demand when your app instantiates its first `CBCentralManager`. On device builds, all ImpossiBLE code compiles to no-ops.

## Limitations

- **Central role only** — peripheral/broadcaster mode is not supported.
- **Single simulator app, last connection wins** — the provider serves one simulator app at a time, and a new connection *takes over*: the previous client is disconnected (its library stops auto-reconnecting, its scans, connections, and L2CAP channels are torn down) and the freshly launched app is served. This is what makes relaunching the app, or switching between simulators, "just work" — to use an older simulator again, relaunch its app. Multiple `CBCentralManager` instances within a single app are fully supported.
- **Provider must be running** — the library auto-reconnects every 2 seconds, so you can start the Mac app before or after your simulator app. Until connected, `CBCentralManager.state` reports `poweredOff`.

## Roadmap Beyond 2.0

The goal remains full CoreBluetooth API coverage in the simulator. Real-device testing is still required, but this tracks what remains after the 2.0 release:

- [ ] **Peripheral role support** (advertising, GATT server, write/notify from the peripheral side).
- [ ] **Multiple simulator clients** (concurrent apps connecting to the provider).
- [x] **Full descriptor support** (discover/read/write descriptors beyond characteristics).
- [ ] **Improved state/authorization fidelity** (authorization states, feature gating, and error codes matching device behavior). `CBManagerState` now tracks socket connectivity; remaining work is authorization edge cases.
- [ ] **State restoration parity** (`CBCentralManager` restoration flows).
- [x] **Pairing / security flows** (bonding, encryption-required characteristics, and relevant errors) in mock mode. Remaining work: passthrough parity for every macOS pairing edge case.
- [ ] **Performance + robustness** (larger payloads, stress testing). Auto-reconnect and Passthrough activity visibility are now implemented.
- [x] **Configurable mocking schemes** — the Mac menu bar app provides stock and user-defined device configurations with full control over services, characteristics, descriptors, and server availability. Remaining work: scripted fault injection and programmatic test automation.

## License

MIT — see [LICENSE](LICENSE) for details.
