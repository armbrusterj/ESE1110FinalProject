# DMXtra HTTP API

Firmware `0.2.0`. The controller runs on port 80 over plain HTTP. All bodies are JSON.

## Model

- **Universe**: 512 DMX channels, numbered 1–512, each holding a value from 0 to 255. The universe is the only place values are stored.
- **Fixture**: a patched device with an `id`, a `name`, a `type`, and a start `address`. A fixture uses `channelCount` consecutive channels starting at `address`. A fixture's `values` are a view of those channels in the universe, so writing to the universe through `/dmx` changes fixture values too, and the reverse.
- **Fixture type**: decides how many channels a fixture uses and what each one is called. The list of types comes from the server (`GET /fixture-types`). Clients should not hard-code it.
- The patch is held in RAM. On reboot it goes back to the defaults: two RGB fixtures, "Wash 1" at address 1 and "Wash 2" at address 4. All channels start at 0.
- Fixtures cannot overlap. Patching a fixture onto channels another fixture already uses returns `409`.
- At most `maxFixtures` fixtures can be patched (currently 32).

## Errors

Any 4xx or 5xx response has the body `{"error": "human-readable message"}`.

| Code | Meaning |
|---|---|
| 400 | Invalid body or parameters |
| 404 | Unknown path or fixture id |
| 405 | Method not allowed on this path |
| 409 | Address overlaps another fixture |
| 413 | Body larger than 4096 bytes |
| 507 | Patch is full |

## Endpoints

### `GET /`
Returns information about the controller.
```json
{"name":"DMXtra","firmware":"0.2.0","universeSize":512,"maxFixtures":32,"fixtureCount":2}
```

### `GET /fixture-types`
```json
[
  {"type":"dimmer","label":"Dimmer","channelCount":1,"channels":["intensity"]},
  {"type":"rgb","label":"RGB","channelCount":3,"channels":["red","green","blue"]},
  {"type":"rgbw","label":"RGBW","channelCount":4,"channels":["red","green","blue","white"]}
]
```

### `GET /fixtures`
Returns all fixtures, sorted by address.
```json
[
  {"id":1,"name":"Wash 1","type":"rgb","address":1,"channelCount":3,
   "channels":["red","green","blue"],"values":[255,0,128]},
  {"id":2,"name":"Wash 2","type":"rgb","address":4,"channelCount":3,
   "channels":["red","green","blue"],"values":[0,0,0]}
]
```

### `POST /fixtures`
Patches a new fixture.

Request body:
```json
{"name":"Wash 3","type":"rgb","address":7}
```
Rules:
- `name` must be 1–31 characters.
- `type` must be a `type` key from `/fixture-types`.
- `address` must be a whole number, and the fixture must fit inside channels 1–512.

Returns `201` with the new fixture object. A fixture's id never changes and is never reused while the board is running.

### `GET /fixtures/{id}`
Returns one fixture object.

### `PATCH /fixtures/{id}`
Send any combination of the fields below. All of them are checked before any change is applied.
```json
{"name":"Stage Left","address":10,"values":[255,null,0]}
```
- `values`: one entry per channel. Each entry is 0–255, or `null` to leave that channel unchanged.
- `address`: moves the fixture. Its current values move with it, and the channels it leaves are set to 0.
- `type` cannot be changed. To change it, delete the fixture and create a new one.

Returns `200` with the updated fixture.

### `DELETE /fixtures/{id}`
Unpatches the fixture and sets its channels to 0. Returns `204`.

### `GET /dmx?start=1&count=512`
Returns raw channel values. Both parameters are optional. By default it returns every channel from `start` to 512.
```json
{"start":1,"values":[255,0,128,0,0,0, ...]}
```

### `POST /dmx`
Writes raw channel values, starting at channel `start` (default 1).
```json
{"start":1,"values":[255,0,0]}
```
Returns `{"start":1,"count":3}`.

### `POST /blackout`
Sets every channel to 0. Returns `204`.

## Client guidance

- The board handles **one connection at a time** and closes it after every response. Send requests one after another, not in parallel.
- Don't flood the board while a slider is being dragged. Send updates at most about 20 times a second, and always send the newest value instead of queuing every intermediate one.
- Other clients, including `curl`, can change the state too. Re-fetch `GET /fixtures` every few seconds to stay in sync.
- Use timeouts of about 3 seconds. Each request blocks the board for a few milliseconds.
