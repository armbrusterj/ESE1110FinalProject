//! HTTP API. A line-for-line port of the router and handlers in
//! embedded/src/main.cpp, so clients see the same status codes, bodies and
//! validation rules as the real board. See embedded/API.md.

use std::io::Read;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Map, Value};
use tiny_http::{Header, Request, Response, Server};

use crate::state::*;

const MAX_BODY: usize = 4096;

pub struct Reply {
    pub status: u16,
    pub body: Option<String>,
}

fn ok(status: u16, v: Value) -> Reply {
    Reply { status, body: Some(v.to_string()) }
}

fn empty(status: u16) -> Reply {
    Reply { status, body: None }
}

fn err(status: u16, msg: &str) -> Reply {
    ok(status, json!({ "error": msg }))
}

/// Serve requests one at a time, like the board does. Blocks forever.
pub fn serve(server: Server, sim: Arc<Mutex<Sim>>, latency: Duration, on_change: impl Fn()) {
    for request in server.incoming_requests() {
        if !latency.is_zero() {
            std::thread::sleep(latency);
        }
        handle(request, &sim);
        on_change();
    }
}

fn handle(mut request: Request, sim: &Mutex<Sim>) {
    let method = request.method().as_str().to_string();
    let url = request.url().to_string();
    let (mut path, query) = match url.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (url.clone(), String::new()),
    };
    if path.len() > 1 && path.ends_with('/') {
        path.pop();
    }

    let reply = if request.body_length().unwrap_or(0) > MAX_BODY {
        err(413, "body too large")
    } else {
        let mut raw = Vec::new();
        let _ = request.as_reader().take(MAX_BODY as u64 + 1).read_to_end(&mut raw);
        if raw.len() > MAX_BODY {
            err(413, "body too large")
        } else {
            let body = String::from_utf8_lossy(&raw);
            let mut sim = sim.lock().unwrap();
            let reply = route(&mut sim, &method, &path, &query, &body);
            sim.log(format!("{method} {path} -> {}", reply.status));
            reply
        }
    };

    let _ = request.respond(to_response(reply));
}

fn to_response(reply: Reply) -> Response<std::io::Cursor<Vec<u8>>> {
    let body = reply.body.unwrap_or_default();
    let has_body = !body.is_empty();
    let mut resp = Response::from_data(body.into_bytes()).with_status_code(reply.status);
    let mut headers = vec![
        ("Access-Control-Allow-Origin", "*"),
        ("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS"),
        ("Access-Control-Allow-Headers", "Content-Type"),
        ("Connection", "close"),
    ];
    if has_body {
        headers.push(("Content-Type", "application/json"));
    }
    for (k, v) in headers {
        resp.add_header(Header::from_bytes(k.as_bytes(), v.as_bytes()).unwrap());
    }
    resp
}

pub fn route(sim: &mut Sim, method: &str, path: &str, query: &str, body: &str) -> Reply {
    if method == "OPTIONS" {
        return empty(204); // CORS preflight
    }

    match path {
        "/" => match method {
            "GET" => info(sim),
            _ => err(405, "use GET"),
        },
        "/fixture-types" => match method {
            "GET" => fixture_types(),
            _ => err(405, "use GET"),
        },
        "/fixtures" => match method {
            "GET" => ok(200, Value::Array(sim.sorted_fixtures().iter().map(|f| fixture_json(sim, f)).collect())),
            "POST" => create_fixture(sim, body),
            _ => err(405, "use GET or POST"),
        },
        "/dmx" => match method {
            "GET" => get_dmx(sim, query),
            "POST" => set_dmx(sim, body),
            _ => err(405, "use GET or POST"),
        },
        "/blackout" => match method {
            "POST" => {
                sim.universe = [0; UNIVERSE_SIZE];
                empty(204)
            }
            _ => err(405, "use POST"),
        },
        _ if path.starts_with("/fixtures/") => {
            let idx = parse_uint(&path[10..])
                .and_then(|id| u16::try_from(id).ok())
                .and_then(|id| sim.find_fixture(id));
            let Some(idx) = idx else { return err(404, "no such fixture") };
            match method {
                "GET" => ok(200, fixture_json(sim, &sim.fixtures[idx])),
                "PATCH" => update_fixture(sim, idx, body),
                "DELETE" => {
                    sim.remove_fixture(idx);
                    empty(204)
                }
                _ => err(405, "use GET, PATCH, or DELETE"),
            }
        }
        _ => err(404, "not found"),
    }
}

// ---------------------------------------------------------------------------
// Helpers (same semantics as the firmware's)
// ---------------------------------------------------------------------------

/// Strict non-negative integer, at most 6 digits.
fn parse_uint(s: &str) -> Option<i64> {
    if s.is_empty() || s.len() > 6 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

fn query_param<'a>(query: &'a str, key: &str) -> &'a str {
    query
        .split('&')
        .find_map(|pair| pair.strip_prefix(key).and_then(|rest| rest.strip_prefix('=')))
        .unwrap_or("")
}

/// A JSON integer that fits in an int (ArduinoJson's `is<int>()`).
fn as_int(v: &Value) -> Option<i64> {
    v.as_i64().filter(|n| i32::try_from(*n).is_ok())
}

fn is_dmx_value(v: &Value) -> bool {
    matches!(as_int(v), Some(0..=255))
}

fn get<'a>(req: &'a Value, key: &str) -> &'a Value {
    req.get(key).unwrap_or(&Value::Null)
}

fn fixture_json(sim: &Sim, f: &Fixture) -> Value {
    let t = f.ty();
    json!({
        "id": f.id,
        "name": f.name,
        "type": t.key,
        "address": f.address,
        "channelCount": t.channel_count(),
        "channels": t.channels,
        "values": sim.fixture_values(f),
    })
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn info(sim: &Sim) -> Reply {
    ok(200, json!({
        "name": "DMXtra",
        "firmware": FIRMWARE_VERSION,
        "universeSize": UNIVERSE_SIZE,
        "maxFixtures": MAX_FIXTURES,
        "fixtureCount": sim.fixtures.len(),
    }))
}

fn fixture_types() -> Reply {
    let types: Vec<Value> = FIXTURE_TYPES
        .iter()
        .map(|t| {
            json!({
                "type": t.key,
                "label": t.label,
                "channelCount": t.channel_count(),
                "channels": t.channels,
            })
        })
        .collect();
    ok(200, Value::Array(types))
}

fn create_fixture(sim: &mut Sim, body: &str) -> Reply {
    let Ok(req) = serde_json::from_str::<Value>(body) else {
        return err(400, "body must be JSON like {\"name\":\"Wash 3\",\"type\":\"rgb\",\"address\":7}");
    };

    let name = get(&req, "name").as_str().unwrap_or("");
    if name.is_empty() || name.len() > MAX_NAME_LEN {
        return err(400, "name is required (1-31 characters)");
    }
    let Some(type_idx) = get(&req, "type").as_str().and_then(find_type) else {
        return err(400, "type must be one of the keys from GET /fixture-types");
    };
    let Some(address) = as_int(get(&req, "address")) else {
        return err(400, "address is required");
    };
    let count = FIXTURE_TYPES[type_idx].channel_count();
    if !address_fits(address, count) {
        return err(400, "fixture does not fit in the universe at that address");
    }
    let address = address as usize;
    if sim.overlaps(address, count, None) {
        return err(409, "address overlaps another fixture");
    }
    let Some(idx) = sim.add_fixture(name, type_idx, address) else {
        return err(507, "patch is full");
    };
    ok(201, fixture_json(sim, &sim.fixtures[idx]))
}

/// PATCH body may contain any of: name, address, values.
/// Everything is validated before anything is applied.
fn update_fixture(sim: &mut Sim, idx: usize, body: &str) -> Reply {
    let req: Map<String, Value> = match serde_json::from_str::<Value>(body) {
        Ok(Value::Object(m)) => m,
        _ => return err(400, "body must be a JSON object"),
    };
    let req = Value::Object(req);
    let f = sim.fixtures[idx].clone();
    let count = f.ty().channel_count();

    let mut new_name = None;
    if !get(&req, "name").is_null() {
        match get(&req, "name").as_str() {
            Some(n) if !n.is_empty() && n.len() <= MAX_NAME_LEN => new_name = Some(n.to_string()),
            _ => return err(400, "name must be 1-31 characters"),
        }
    }

    let mut new_address = None;
    if !get(&req, "address").is_null() {
        let Some(a) = as_int(get(&req, "address")) else {
            return err(400, "address must be an integer");
        };
        if !address_fits(a, count) {
            return err(400, "fixture does not fit in the universe at that address");
        }
        if sim.overlaps(a as usize, count, Some(f.id)) {
            return err(409, "address overlaps another fixture");
        }
        new_address = Some(a as usize);
    }

    let mut values = None;
    if !get(&req, "values").is_null() {
        match get(&req, "values").as_array() {
            Some(arr) if arr.len() == count => {
                if arr.iter().any(|v| !v.is_null() && !is_dmx_value(v)) {
                    return err(400, "values must be integers 0-255 or null");
                }
                values = Some(arr.clone());
            }
            _ => return err(400, "values must be an array with one entry per channel"),
        }
    }

    if new_name.is_none() && new_address.is_none() && values.is_none() {
        return err(400, "provide at least one of name, address, values");
    }

    // Apply
    if let Some(n) = new_name {
        sim.fixtures[idx].name = n;
    }
    if let Some(a) = new_address {
        // The fixture's current look and its light move with it; old channels go dark.
        sim.move_fixture(idx, a);
    }
    if let Some(vals) = values {
        let addr = sim.fixtures[idx].address;
        for (i, v) in vals.iter().enumerate() {
            if let Some(n) = as_int(v) {
                sim.universe[addr - 1 + i] = n as u8;
            }
        }
    }
    ok(200, fixture_json(sim, &sim.fixtures[idx]))
}

/// GET /dmx?start=1&count=512
fn get_dmx(sim: &Sim, query: &str) -> Reply {
    let s = query_param(query, "start");
    let c = query_param(query, "count");
    let start = if s.is_empty() { Some(1) } else { parse_uint(s) };
    let size = UNIVERSE_SIZE as i64;
    let count = match (c.is_empty(), start) {
        (true, Some(st)) => Some(size - st + 1),
        (true, None) => None,
        (false, _) => parse_uint(c),
    };
    let (Some(start), Some(count)) = (start, count) else {
        return err(400, "start/count out of range (channels are 1-512)");
    };
    if start < 1 || start > size || count < 1 || start + count - 1 > size {
        return err(400, "start/count out of range (channels are 1-512)");
    }
    let from = (start - 1) as usize;
    let values = &sim.universe[from..from + count as usize];
    ok(200, json!({ "start": start, "values": values }))
}

/// POST /dmx {"start":1,"values":[255,0,0]}
fn set_dmx(sim: &mut Sim, body: &str) -> Reply {
    let Ok(req) = serde_json::from_str::<Value>(body) else {
        return err(400, "body must be JSON like {\"start\":1,\"values\":[255,0,0]}");
    };
    let start = as_int(get(&req, "start")).unwrap_or(1);
    let values = match get(&req, "values").as_array() {
        Some(v) if !v.is_empty() => v,
        _ => return err(400, "values must be a non-empty array"),
    };
    if start < 1 || start + values.len() as i64 - 1 > UNIVERSE_SIZE as i64 {
        return err(400, "start/values out of range (channels are 1-512)");
    }
    if !values.iter().all(is_dmx_value) {
        return err(400, "values must be integers 0-255");
    }
    for (i, v) in values.iter().enumerate() {
        sim.universe[start as usize - 1 + i] = as_int(v).unwrap() as u8;
    }
    ok(200, json!({ "start": start, "count": values.len() }))
}
