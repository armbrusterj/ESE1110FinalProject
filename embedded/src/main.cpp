#include <Arduino.h>
#include <ArduinoJson.h>
#include <WiFiS3.h>

#include "secrets.h"  // copy include/secrets.example.h -> include/secrets.h

// HTTP API reference: embedded/API.md
constexpr const char* FIRMWARE_VERSION = "0.2.0";

// ---------------------------------------------------------------------------
// DMX universe: 512 one-byte channels. This is the single source of truth.
// Fixtures are just named views onto ranges of it, and outputs read from it.
// When the DMX hardware arrives, the universe gets streamed out over RS-485.
// ---------------------------------------------------------------------------
constexpr uint16_t DMX_UNIVERSE_SIZE = 512;
uint8_t universe[DMX_UNIVERSE_SIZE] = {0};  // index 0 == DMX channel 1

// ---------------------------------------------------------------------------
// Outputs: simulated DMX receivers.
// The physical test LEDs behave like real DMX fixtures with a hard-set start
// address (like DIP switches): they read their channels from the universe and
// know nothing about the patch. If you patch a fixture at a different address,
// these LEDs won't respond, just like real hardware wouldn't.
// PWM-capable pins on the UNO R4 WiFi: 3, 5, 6, 9, 10, 11
// ---------------------------------------------------------------------------
struct RgbReceiver {
  uint16_t address;  // 1-based DMX start address
  uint8_t pins[3];   // R, G, B
};

const RgbReceiver receivers[] = {
    {1, {9, 10, 11}},  // test LED 1 listens on channels 1-3
    {4, {3, 5, 6}},    // test LED 2 listens on channels 4-6
};

void renderOutputs() {
  for (const RgbReceiver& rx : receivers) {
    for (int i = 0; i < 3; i++) {
      analogWrite(rx.pins[i], universe[rx.address - 1 + i]);
    }
  }
  // TODO(DMX hardware): send `universe` over the DMX line here.
}

// ---------------------------------------------------------------------------
// Patch: the controller's list of fixtures (id, name, type, start address).
// Held in RAM, so it resets to the defaults on reboot.
// ---------------------------------------------------------------------------
struct FixtureType {
  const char* key;
  const char* label;
  uint8_t channelCount;
  const char* channels[4];
};

const FixtureType FIXTURE_TYPES[] = {
    {"dimmer", "Dimmer", 1, {"intensity"}},
    {"rgb", "RGB", 3, {"red", "green", "blue"}},
    {"rgbw", "RGBW", 4, {"red", "green", "blue", "white"}},
};
constexpr int NUM_FIXTURE_TYPES = sizeof(FIXTURE_TYPES) / sizeof(FIXTURE_TYPES[0]);

constexpr int MAX_FIXTURES = 32;
constexpr int MAX_NAME_LEN = 31;

struct Fixture {
  bool used;
  uint16_t id;
  char name[MAX_NAME_LEN + 1];
  uint8_t type;      // index into FIXTURE_TYPES
  uint16_t address;  // 1-based DMX start address
};

Fixture fixtures[MAX_FIXTURES];
uint16_t nextFixtureId = 1;

const FixtureType& typeOf(const Fixture& f) { return FIXTURE_TYPES[f.type]; }

int findTypeByKey(const char* key) {
  if (!key) return -1;
  for (int i = 0; i < NUM_FIXTURE_TYPES; i++) {
    if (strcmp(FIXTURE_TYPES[i].key, key) == 0) return i;
  }
  return -1;
}

Fixture* findFixture(int id) {
  for (Fixture& f : fixtures) {
    if (f.used && f.id == id) return &f;
  }
  return nullptr;
}

int fixtureCount() {
  int n = 0;
  for (const Fixture& f : fixtures) n += f.used;
  return n;
}

// Returns true if [address, address+count) collides with any fixture other
// than `ignoreId`.
bool overlaps(uint16_t address, uint8_t count, int ignoreId) {
  uint16_t end = address + count;  // exclusive
  for (const Fixture& f : fixtures) {
    if (!f.used || f.id == ignoreId) continue;
    uint16_t fEnd = f.address + typeOf(f).channelCount;
    if (address < fEnd && f.address < end) return true;
  }
  return false;
}

bool addressFits(int address, uint8_t count) {
  return address >= 1 && address + count - 1 <= DMX_UNIVERSE_SIZE;
}

Fixture* addFixture(const char* name, int type, uint16_t address) {
  for (Fixture& f : fixtures) {
    if (f.used) continue;
    f.used = true;
    f.id = nextFixtureId++;
    strncpy(f.name, name, MAX_NAME_LEN);
    f.name[MAX_NAME_LEN] = '\0';
    f.type = type;
    f.address = address;
    return &f;
  }
  return nullptr;
}

void loadDefaultPatch() {
  int rgb = findTypeByKey("rgb");
  addFixture("Wash 1", rgb, 1);
  addFixture("Wash 2", rgb, 4);
}

WiFiServer server(80);

// ---------------------------------------------------------------------------
// WiFi
// ---------------------------------------------------------------------------
void connectWiFi() {
  if (WiFi.status() == WL_NO_MODULE) {
    Serial.println("ERROR: WiFi module not found");
    while (true) delay(1000);
  }

  if (String(WiFi.firmwareVersion()) < WIFI_FIRMWARE_LATEST_VERSION) {
    Serial.println("Note: WiFi firmware update available (Arduino IDE > Tools > Firmware Updater)");
  }

  while (WiFi.status() != WL_CONNECTED) {
    Serial.print("Connecting to ");
    Serial.println(WIFI_SSID);
    WiFi.begin(WIFI_SSID, WIFI_PASS);  // blocks for up to ~10s
    if (WiFi.status() != WL_CONNECTED) {
      Serial.print("  failed (status ");
      Serial.print(WiFi.status());
      Serial.println("). Scanning for networks...");
      int n = WiFi.scanNetworks();
      bool found = false;
      for (int i = 0; i < n; i++) {
        if (String(WiFi.SSID(i)) == WIFI_SSID) {
          found = true;
          Serial.print("  found ");
          Serial.print(WIFI_SSID);
          Serial.print(" RSSI ");
          Serial.print(WiFi.RSSI(i));
          Serial.print(" dBm, encryption type ");
          Serial.println(WiFi.encryptionType(i));
        }
      }
      if (!found) {
        Serial.print("  ");
        Serial.print(WIFI_SSID);
        Serial.print(" not visible. ");
        Serial.print(n);
        Serial.println(" networks seen.");
      }
      Serial.println("  retrying in 5s...");
      delay(5000);
    }
  }

  // DHCP can take a moment after association before the IP is valid.
  while (WiFi.localIP() == IPAddress(0, 0, 0, 0)) delay(100);

  Serial.print("Connected! Server at http://");
  Serial.println(WiFi.localIP());
  Serial.print("Signal strength (RSSI): ");
  Serial.print(WiFi.RSSI());
  Serial.println(" dBm");
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------
const char* statusText(int code) {
  switch (code) {
    case 200: return "OK";
    case 201: return "Created";
    case 204: return "No Content";
    case 400: return "Bad Request";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 409: return "Conflict";
    case 413: return "Payload Too Large";
    case 507: return "Insufficient Storage";
    default:  return "Error";
  }
}

void sendResponse(WiFiClient& client, int code, const String& body = "") {
  client.print("HTTP/1.1 ");
  client.print(code);
  client.print(' ');
  client.println(statusText(code));
  // CORS so a browser-based client on another origin can call us too
  client.println("Access-Control-Allow-Origin: *");
  client.println("Access-Control-Allow-Methods: GET, POST, PATCH, DELETE, OPTIONS");
  client.println("Access-Control-Allow-Headers: Content-Type");
  client.println("Connection: close");
  if (body.length() > 0) {
    client.println("Content-Type: application/json");
  }
  client.print("Content-Length: ");
  client.println(body.length());
  client.println();
  client.print(body);
}

void sendJson(WiFiClient& client, int code, JsonDocument& doc) {
  String out;
  serializeJson(doc, out);
  sendResponse(client, code, out);
}

void sendError(WiFiClient& client, int code, const char* message) {
  JsonDocument doc;
  doc["error"] = message;
  sendJson(client, code, doc);
}

// Strict non-negative integer parse; returns -1 if `s` isn't one.
long parseUInt(const String& s) {
  if (s.length() == 0 || s.length() > 6) return -1;
  for (unsigned i = 0; i < s.length(); i++) {
    if (!isDigit(s[i])) return -1;
  }
  return s.toInt();
}

// Value of `key` in a query string like "start=1&count=16", or "" if absent.
String queryParam(const String& query, const char* key) {
  String prefix = String(key) + "=";
  int pos = 0;
  while (pos < (int)query.length()) {
    int amp = query.indexOf('&', pos);
    if (amp < 0) amp = query.length();
    String pair = query.substring(pos, amp);
    if (pair.startsWith(prefix)) return pair.substring(prefix.length());
    pos = amp + 1;
  }
  return "";
}

// A JSON value that must be an integer 0-255.
bool isDmxValue(JsonVariantConst v) {
  return v.is<int>() && v.as<int>() >= 0 && v.as<int>() <= 255;
}

// ---------------------------------------------------------------------------
// JSON serialization
// ---------------------------------------------------------------------------
void fixtureToJson(JsonObject obj, const Fixture& f) {
  const FixtureType& t = typeOf(f);
  obj["id"] = f.id;
  obj["name"] = f.name;
  obj["type"] = t.key;
  obj["address"] = f.address;
  obj["channelCount"] = t.channelCount;
  JsonArray channels = obj["channels"].to<JsonArray>();
  JsonArray values = obj["values"].to<JsonArray>();
  for (int i = 0; i < t.channelCount; i++) {
    channels.add(t.channels[i]);
    values.add(universe[f.address - 1 + i]);
  }
}

// ---------------------------------------------------------------------------
// Route handlers
// ---------------------------------------------------------------------------
void handleInfo(WiFiClient& client) {
  JsonDocument doc;
  doc["name"] = "DMXtra";
  doc["firmware"] = FIRMWARE_VERSION;
  doc["universeSize"] = DMX_UNIVERSE_SIZE;
  doc["maxFixtures"] = MAX_FIXTURES;
  doc["fixtureCount"] = fixtureCount();
  sendJson(client, 200, doc);
}

void handleFixtureTypes(WiFiClient& client) {
  JsonDocument doc;
  JsonArray arr = doc.to<JsonArray>();
  for (const FixtureType& t : FIXTURE_TYPES) {
    JsonObject obj = arr.add<JsonObject>();
    obj["type"] = t.key;
    obj["label"] = t.label;
    obj["channelCount"] = t.channelCount;
    JsonArray ch = obj["channels"].to<JsonArray>();
    for (int i = 0; i < t.channelCount; i++) ch.add(t.channels[i]);
  }
  sendJson(client, 200, doc);
}

void handleListFixtures(WiFiClient& client) {
  JsonDocument doc;
  JsonArray arr = doc.to<JsonArray>();
  // Sorted by address so the list reads like a patch sheet.
  int lastAddr = 0;
  int lastId = 0;
  for (int n = fixtureCount(); n > 0; n--) {
    const Fixture* next = nullptr;
    for (const Fixture& f : fixtures) {
      if (!f.used) continue;
      bool after = f.address > lastAddr || (f.address == lastAddr && f.id > lastId);
      if (!after) continue;
      if (!next || f.address < next->address ||
          (f.address == next->address && f.id < next->id)) {
        next = &f;
      }
    }
    if (!next) break;
    fixtureToJson(arr.add<JsonObject>(), *next);
    lastAddr = next->address;
    lastId = next->id;
  }
  sendJson(client, 200, doc);
}

void handleCreateFixture(WiFiClient& client, const String& body) {
  JsonDocument req;
  if (deserializeJson(req, body)) {
    sendError(client, 400, "body must be JSON like {\"name\":\"Wash 3\",\"type\":\"rgb\",\"address\":7}");
    return;
  }

  const char* name = req["name"];
  if (!name || strlen(name) == 0 || strlen(name) > MAX_NAME_LEN) {
    sendError(client, 400, "name is required (1-31 characters)");
    return;
  }
  int type = findTypeByKey(req["type"]);
  if (type < 0) {
    sendError(client, 400, "type must be one of the keys from GET /fixture-types");
    return;
  }
  if (!req["address"].is<int>()) {
    sendError(client, 400, "address is required");
    return;
  }
  int address = req["address"];
  uint8_t count = FIXTURE_TYPES[type].channelCount;
  if (!addressFits(address, count)) {
    sendError(client, 400, "fixture does not fit in the universe at that address");
    return;
  }
  if (overlaps(address, count, -1)) {
    sendError(client, 409, "address overlaps another fixture");
    return;
  }

  Fixture* f = addFixture(name, type, address);
  if (!f) {
    sendError(client, 507, "patch is full");
    return;
  }

  JsonDocument res;
  fixtureToJson(res.to<JsonObject>(), *f);
  sendJson(client, 201, res);
}

// PATCH body may contain any of: name, address, values.
// Everything is validated before anything is applied.
void handleUpdateFixture(WiFiClient& client, Fixture& f, const String& body) {
  JsonDocument req;
  if (deserializeJson(req, body) || !req.is<JsonObject>()) {
    sendError(client, 400, "body must be a JSON object");
    return;
  }
  const FixtureType& t = typeOf(f);

  const char* newName = nullptr;
  if (!req["name"].isNull()) {
    newName = req["name"];
    if (!newName || strlen(newName) == 0 || strlen(newName) > MAX_NAME_LEN) {
      sendError(client, 400, "name must be 1-31 characters");
      return;
    }
  }

  int newAddress = -1;
  if (!req["address"].isNull()) {
    if (!req["address"].is<int>()) {
      sendError(client, 400, "address must be an integer");
      return;
    }
    newAddress = req["address"];
    if (!addressFits(newAddress, t.channelCount)) {
      sendError(client, 400, "fixture does not fit in the universe at that address");
      return;
    }
    if (overlaps(newAddress, t.channelCount, f.id)) {
      sendError(client, 409, "address overlaps another fixture");
      return;
    }
  }

  // values: array of channelCount entries; null entries are left unchanged.
  JsonArrayConst values = req["values"];
  if (!req["values"].isNull()) {
    if (values.isNull() || (int)values.size() != t.channelCount) {
      sendError(client, 400, "values must be an array with one entry per channel");
      return;
    }
    for (JsonVariantConst v : values) {
      if (!v.isNull() && !isDmxValue(v)) {
        sendError(client, 400, "values must be integers 0-255 or null");
        return;
      }
    }
  }

  if (newName == nullptr && newAddress < 0 && values.isNull()) {
    sendError(client, 400, "provide at least one of name, address, values");
    return;
  }

  // Apply
  if (newName) {
    strncpy(f.name, newName, MAX_NAME_LEN);
    f.name[MAX_NAME_LEN] = '\0';
  }
  if (newAddress >= 0 && newAddress != f.address) {
    // The fixture's current look moves with it; old channels go dark.
    uint8_t current[4];
    for (int i = 0; i < t.channelCount; i++) {
      current[i] = universe[f.address - 1 + i];
      universe[f.address - 1 + i] = 0;
    }
    f.address = newAddress;
    for (int i = 0; i < t.channelCount; i++) universe[f.address - 1 + i] = current[i];
  }
  if (!values.isNull()) {
    for (int i = 0; i < t.channelCount; i++) {
      if (!values[i].isNull()) universe[f.address - 1 + i] = values[i].as<int>();
    }
  }
  renderOutputs();

  JsonDocument res;
  fixtureToJson(res.to<JsonObject>(), f);
  sendJson(client, 200, res);
}

void handleDeleteFixture(WiFiClient& client, Fixture& f) {
  // Unpatched channels go dark.
  for (int i = 0; i < typeOf(f).channelCount; i++) universe[f.address - 1 + i] = 0;
  f.used = false;
  renderOutputs();
  sendResponse(client, 204);
}

// GET /dmx?start=1&count=512
void handleGetDmx(WiFiClient& client, const String& query) {
  String s = queryParam(query, "start");
  String c = queryParam(query, "count");
  long start = s.length() ? parseUInt(s) : 1;
  long count = c.length() ? parseUInt(c) : DMX_UNIVERSE_SIZE - start + 1;
  if (start < 1 || start > DMX_UNIVERSE_SIZE || count < 1 ||
      start + count - 1 > DMX_UNIVERSE_SIZE) {
    sendError(client, 400, "start/count out of range (channels are 1-512)");
    return;
  }

  // Built by hand: a 512-entry JsonDocument is wasteful on this board.
  String out;
  out.reserve(32 + count * 4);
  out += "{\"start\":";
  out += start;
  out += ",\"values\":[";
  for (long i = 0; i < count; i++) {
    if (i) out += ',';
    out += universe[start - 1 + i];
  }
  out += "]}";
  sendResponse(client, 200, out);
}

// POST /dmx {"start":1,"values":[255,0,0]}
void handleSetDmx(WiFiClient& client, const String& body) {
  JsonDocument req;
  if (deserializeJson(req, body)) {
    sendError(client, 400, "body must be JSON like {\"start\":1,\"values\":[255,0,0]}");
    return;
  }
  int start = req["start"] | 1;
  JsonArrayConst values = req["values"];
  if (values.isNull() || values.size() == 0) {
    sendError(client, 400, "values must be a non-empty array");
    return;
  }
  if (start < 1 || start + (int)values.size() - 1 > DMX_UNIVERSE_SIZE) {
    sendError(client, 400, "start/values out of range (channels are 1-512)");
    return;
  }
  for (JsonVariantConst v : values) {
    if (!isDmxValue(v)) {
      sendError(client, 400, "values must be integers 0-255");
      return;
    }
  }

  int i = start - 1;
  for (JsonVariantConst v : values) universe[i++] = v.as<int>();
  renderOutputs();

  JsonDocument res;
  res["start"] = start;
  res["count"] = values.size();
  sendJson(client, 200, res);
}

void handleBlackout(WiFiClient& client) {
  memset(universe, 0, sizeof(universe));
  renderOutputs();
  sendResponse(client, 204);
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------
void route(WiFiClient& client, const String& method, const String& path,
           const String& query, const String& body) {
  if (method == "OPTIONS") {  // CORS preflight
    sendResponse(client, 204);
    return;
  }

  if (path == "/") {
    if (method == "GET") return handleInfo(client);
    return sendError(client, 405, "use GET");
  }

  if (path == "/fixture-types") {
    if (method == "GET") return handleFixtureTypes(client);
    return sendError(client, 405, "use GET");
  }

  if (path == "/fixtures") {
    if (method == "GET") return handleListFixtures(client);
    if (method == "POST") return handleCreateFixture(client, body);
    return sendError(client, 405, "use GET or POST");
  }

  if (path.startsWith("/fixtures/")) {
    Fixture* f = findFixture(parseUInt(path.substring(10)));
    if (!f) return sendError(client, 404, "no such fixture");

    if (method == "GET") {
      JsonDocument res;
      fixtureToJson(res.to<JsonObject>(), *f);
      return sendJson(client, 200, res);
    }
    if (method == "PATCH") return handleUpdateFixture(client, *f, body);
    if (method == "DELETE") return handleDeleteFixture(client, *f);
    return sendError(client, 405, "use GET, PATCH, or DELETE");
  }

  if (path == "/dmx") {
    if (method == "GET") return handleGetDmx(client, query);
    if (method == "POST") return handleSetDmx(client, body);
    return sendError(client, 405, "use GET or POST");
  }

  if (path == "/blackout") {
    if (method == "POST") return handleBlackout(client);
    return sendError(client, 405, "use POST");
  }

  sendError(client, 404, "not found");
}

void handleClient(WiFiClient& client) {
  client.setTimeout(1000);  // ms, for readStringUntil / readBytes

  // Request line: "PATCH /fixtures/1 HTTP/1.1"
  String requestLine = client.readStringUntil('\n');
  requestLine.trim();
  int sp1 = requestLine.indexOf(' ');
  int sp2 = requestLine.indexOf(' ', sp1 + 1);
  if (sp1 < 0 || sp2 < 0) {
    sendError(client, 400, "malformed request");
    return;
  }
  String method = requestLine.substring(0, sp1);
  String path = requestLine.substring(sp1 + 1, sp2);
  String query;
  int q = path.indexOf('?');
  if (q >= 0) {
    query = path.substring(q + 1);
    path = path.substring(0, q);
  }
  if (path.length() > 1 && path.endsWith("/")) path.remove(path.length() - 1);

  // Headers: only Content-Length matters to us
  int contentLength = 0;
  while (true) {
    String line = client.readStringUntil('\n');
    line.trim();
    if (line.length() == 0) break;  // blank line ends headers
    line.toLowerCase();
    if (line.startsWith("content-length:")) {
      contentLength = line.substring(15).toInt();
    }
  }

  // Big enough for a full-universe POST /dmx (512 values * up to 4 chars).
  constexpr int MAX_BODY = 4096;
  static char bodyBuf[MAX_BODY + 1];
  if (contentLength > MAX_BODY) {
    sendError(client, 413, "body too large");
    return;
  }

  String body;
  if (contentLength > 0) {
    size_t n = client.readBytes(bodyBuf, contentLength);
    bodyBuf[n] = '\0';
    body = bodyBuf;
  }

  Serial.print(method);
  Serial.print(' ');
  Serial.println(path);

  route(client, method, path, query, body);
}

// ---------------------------------------------------------------------------
// Arduino entry points
// ---------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  // Wait briefly for USB serial, but don't hang forever when running off a
  // wall adapter with no computer attached.
  unsigned long start = millis();
  while (!Serial && millis() - start < 3000) {}

  for (const RgbReceiver& rx : receivers) {
    for (uint8_t pin : rx.pins) pinMode(pin, OUTPUT);
  }
  renderOutputs();  // start dark

  loadDefaultPatch();

  connectWiFi();
  server.begin();
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("WiFi lost, reconnecting...");
    connectWiFi();
  }

  WiFiClient client = server.available();
  if (client) {
    handleClient(client);
    delay(1);  // let the response flush
    client.stop();
  }
}
