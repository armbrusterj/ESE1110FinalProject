# Build the DMXtra controller app

Build a SwiftUI app in this `app/` directory that controls a DMX lighting controller over HTTP. The controller is an Arduino UNO R4 WiFi. Its firmware and API live in `../embedded/`.

## Read first
- `../embedded/API.md` is the full HTTP API: endpoints, JSON shapes, errors, and rate guidance. Treat it as the source of truth.
- `../embedded/src/main.cpp` is the firmware, if you need to confirm how something behaves. Don't change the firmware. If the API is missing something the app needs, stop and tell me what's missing and why.

## Context
- This is a university final project called **DMXtra**. The end goal is controlling a full DMX universe from a phone. The DMX hardware hasn't arrived yet, so for now the board drives two RGB LEDs that act as DMX receivers on channels 1–3 and 4–6.
- **The app must treat everything as DMX.** It deals only with fixtures, channels, addresses, and the universe. Never mention LEDs, pins, or Arduino anywhere in the UI or the model names. When real DMX hardware replaces the LEDs, the app should need no changes.
- **Support any number of fixtures.** Nothing about the patch may be hard-coded: not the fixture count, not their types, not their channel layout. Build every list and control from `GET /fixtures` and `GET /fixture-types`. A fixture type you've never seen should still work, shown as one generic fader per channel, labelled with its name from `channels`.

## Platform and project setup
- SwiftUI app with one multiplatform target for iOS 17+ and macOS 14+, so it can be tested on a Mac without a phone. Use Swift concurrency (`async`/`await`) and the `@Observable` macro. Add no third-party packages.
- Generate the Xcode project with **XcodeGen** from a `project.yml` that is checked into the repo. Don't hand-write the `project.pbxproj`. If `xcodegen` isn't installed, ask me before running `brew install xcodegen`.
- The board uses plain HTTP on the local network, so the Info.plist needs:
  - `NSAppTransportSecurity` → `NSAllowsLocalNetworking = YES`, plus `NSAllowsArbitraryLoads = YES`, because the board is reached by a raw IP address on campus WiFi (e.g. `10.103.210.50`)
  - `NSLocalNetworkUsageDescription`, with a short explanation that the app talks to the lighting controller
  - on macOS, the App Sandbox outgoing network connections (client) entitlement
- Keep the gitignore up to date for Xcode: `xcuserdata/`, `DerivedData/`, `*.xcuserstate`, `.build/`. The generated `.xcodeproj` may be committed or ignored. Pick one and note it in the README.

## Features
1. **Connect**
   - A field for the controller address (IP or hostname, with an optional port).
   - Save it in `UserDefaults`.
   - Check the connection with `GET /`, then show the controller's name and firmware version.
   - Show a clear status whether connected, connecting, or unreachable.
   - Make it easy to change the address later.
2. **Fixtures**
   - List every fixture with its name, type label, and address range (e.g. "RGB · 1–3"), plus a colour swatch for colour fixtures.
   - Pull to refresh.
   - While the screen is visible, poll `GET /fixtures` every 2 seconds so changes from other clients show up.
3. **Fixture control**
   - One fader per channel, labelled with the channel name, 0–255.
   - For fixtures whose channels include red, green, and blue, also show a colour picker. It should stay in sync with the faders in both directions.
   - Send changes with `PATCH /fixtures/{id}` and `values`, using `null` for channels that didn't change.
4. **Patch editing**
   - Add a fixture: a name, a type picked from `/fixture-types`, and a start address. Suggest the next free address by default.
   - Edit a fixture's name and address.
   - Delete a fixture (swipe to delete, with a confirmation).
   - Show the server's `error` message when it says no, e.g. 409 for an overlap or 507 when the patch is full.
5. **Universe view**
   - A grid of all 512 channels showing their values, from `GET /dmx`.
   - Shade each fixture's channels with a colour of its own and label it, so the patch is visible at a glance.
   - Tapping a channel lets you set its raw value with `POST /dmx`.
6. **Blackout**
   - A blackout button that's always within reach. It calls `POST /blackout`, then refreshes.

## Networking requirements (important: the board is fragile)
- Put all HTTP calls behind one `ControllerClient` actor, and send requests **one at a time**. The board handles only one connection at a time.
- Rate-limit fader and colour-picker changes per fixture to about **20 per second**. When an update is still waiting, replace it with the newer value instead of queuing both. After the user lets go, always send the final value.
- Don't let polling overwrite a control the user is touching: hold back poll updates for that fixture while it's being edited, and for a short time after.
- Use a 3-second request timeout. Decode errors into a type that carries the server's `error` message.
- Use `Codable` models that match API.md exactly: `Fixture`, `FixtureType`, `ControllerInfo`, `DmxRange`.

## Testing
- Write a mock server, `app/tools/mock_server.py`, using only the Python standard library. It should copy the API in `API.md` closely, including status codes, error bodies, overlap rules, the default patch, and closing the connection after every response. Use it to develop and test without the board: `python3 tools/mock_server.py --port 8080`.
- Add unit tests for model decoding, the rate-limiting logic, and the next-free-address calculation.
- Check that the app builds with `xcodebuild` for both the iOS Simulator and macOS. Run the tests.
- If the real board is reachable (I'll give you its IP), do a final check against it with `curl` and the app.

## Deliverables
- Working app, project.yml, mock server, and tests in `app/`.
- `app/README.md` covering how to generate the project, run it, point it at the mock server or the board, and the Info.plist settings and why each is needed.
- Don't commit or push unless I ask.
