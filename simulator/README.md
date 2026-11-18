# DMXtra simulator

A desktop stand-in for the DMXtra board. It serves the same HTTP API as the firmware in
[`../embedded`](../embedded) (documented in [`../embedded/API.md`](../embedded/API.md)), with the
same status codes, error messages and validation rules, and opens an egui window showing what each
light is putting out.

## Run it

Needs a Rust toolchain ([rustup.rs](https://rustup.rs)).

```bash
cd simulator && cargo run --release
```

The API is then at `http://127.0.0.1:8080`. In the DMXtra app, enter `127.0.0.1:8080` on the
**Controller** tab.

To reach it from a phone on the same WiFi, bind every interface and use your computer's IP address:

```bash
cargo run --release -- --host 0.0.0.0 --port 8080
```

Options:

| Flag | Default | Meaning |
|---|---|---|
| `--host` | `127.0.0.1` | Interface to bind |
| `--port` | `8080` | TCP port |
| `--latency` | `0` | Extra delay per request, in ms, to feel more like the board |

## Lights vs. fixtures

Like the firmware, the simulator keeps two separate ideas:

- **Fixtures** are the controller's patch: what `GET /fixtures` returns and what clients edit.
- **Lights** are the simulated hardware on the DMX line. Each one has a type and a fixed start
  address (like DIP switches) and simply reads its channels from the universe. It knows nothing
  about the patch, so if you patch a fixture at a different address, the light won't respond, just
  like the real test LEDs.

It starts in the same state as the board: fixtures "Wash 1" (address 1) and "Wash 2" (address 4),
plus two RGB lights on channels 1–3 and 4–6 standing in for the test LEDs.

## The window

- **Lights**: one card per light with its output colour, channel values, start address (drag or
  type to re-address it) and whether a matching fixture is patched.
- **Add light**: name, type and address. Leave **Also patch it on the controller** ticked to create
  the matching fixture too, so clients see it in `GET /fixtures`.
- **Controller patch**: the fixtures as the API reports them.
- **Universe**: all 512 channels; patched channels are outlined in blue. Hover a cell for its value.
- **Requests**: a log of recent API calls and their status codes.
- **Blackout** sets every channel to 0, same as `POST /blackout`.

State is held in memory and resets when you quit, just as the board resets on reboot.

## Code

- `src/state.rs`: universe, patch and lights.
- `src/api.rs`: the HTTP server and a port of the firmware's router and handlers. Requests are
  handled one at a time, like the board.
- `src/ui.rs`: the egui window.
