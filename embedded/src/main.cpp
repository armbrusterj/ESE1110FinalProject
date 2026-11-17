#include <Arduino.h>
#include <ArduinoJson.h>
#include <WiFiS3.h>

#include "secrets.h"  // copy include/secrets.example.h -> include/secrets.h

// ---------------------------------------------------------------------------
// Hardware config
// ---------------------------------------------------------------------------
// PWM-capable pins on the UNO R4 WiFi: 3, 5, 6, 9, 10, 11
constexpr uint8_t PIN_R = 9;
constexpr uint8_t PIN_G = 10;
constexpr uint8_t PIN_B = 11;

// Common-cathode LED (long leg -> GND): false
// Common-anode LED   (long leg -> 5V):  true
constexpr bool LED_COMMON_ANODE = false;

// ---------------------------------------------------------------------------
// State: a DMX-style universe of 512 one-byte channels.
// The RGB LED is treated as a 3-channel fixture at DMX address 1 (channels
// 1-3). When the DMX hardware arrives, the same buffer just gets streamed out
// over the DMX line, and the HTTP API can grow to address any channel.
// ---------------------------------------------------------------------------
constexpr uint16_t DMX_UNIVERSE_SIZE = 512;
uint8_t universe[DMX_UNIVERSE_SIZE] = {0};  // index 0 == DMX channel 1

constexpr uint16_t LED_ADDRESS = 1;  // 1-based DMX start address

WiFiServer server(80);

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------
void writeLed() {
  const uint8_t r = universe[LED_ADDRESS - 1];
  const uint8_t g = universe[LED_ADDRESS];
  const uint8_t b = universe[LED_ADDRESS + 1];
  if (LED_COMMON_ANODE) {
    analogWrite(PIN_R, 255 - r);
    analogWrite(PIN_G, 255 - g);
    analogWrite(PIN_B, 255 - b);
  } else {
    analogWrite(PIN_R, r);
    analogWrite(PIN_G, g);
    analogWrite(PIN_B, b);
  }
}

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
    case 204: return "No Content";
    case 400: return "Bad Request";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 413: return "Payload Too Large";
    default:  return "Error";
  }
}

void sendResponse(WiFiClient& client, int code, const String& body = "") {
  client.print("HTTP/1.1 ");
  client.print(code);
  client.print(' ');
  client.println(statusText(code));
  // CORS so a browser app on another origin (e.g. your dev server) can call us
  client.println("Access-Control-Allow-Origin: *");
  client.println("Access-Control-Allow-Methods: GET, POST, PUT, OPTIONS");
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

void sendError(WiFiClient& client, int code, const char* message) {
  JsonDocument doc;
  doc["error"] = message;
  String out;
  serializeJson(doc, out);
  sendResponse(client, code, out);
}

String ledStateJson() {
  JsonDocument doc;
  doc["r"] = universe[LED_ADDRESS - 1];
  doc["g"] = universe[LED_ADDRESS];
  doc["b"] = universe[LED_ADDRESS + 1];
  String out;
  serializeJson(doc, out);
  return out;
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------
// GET  /led                          -> {"r":0,"g":0,"b":0}
// POST /led  {"r":255,"g":0,"b":128} -> new state (any subset of r/g/b)
void handleSetLed(WiFiClient& client, const String& body) {
  JsonDocument doc;
  if (deserializeJson(doc, body)) {
    sendError(client, 400, "body must be JSON like {\"r\":255,\"g\":0,\"b\":0}");
    return;
  }

  const char* keys[] = {"r", "g", "b"};
  int values[3];
  bool any = false;

  // Validate everything before applying anything
  for (int i = 0; i < 3; i++) {
    values[i] = -1;
    JsonVariant v = doc[keys[i]];
    if (v.isNull()) continue;
    if (!v.is<int>() || v.as<int>() < 0 || v.as<int>() > 255) {
      sendError(client, 400, "r, g, b must be integers 0-255");
      return;
    }
    values[i] = v.as<int>();
    any = true;
  }
  if (!any) {
    sendError(client, 400, "provide at least one of r, g, b");
    return;
  }

  for (int i = 0; i < 3; i++) {
    if (values[i] >= 0) universe[LED_ADDRESS - 1 + i] = values[i];
  }
  writeLed();
  sendResponse(client, 200, ledStateJson());
}

void route(WiFiClient& client, const String& method, const String& path,
           const String& body) {
  if (method == "OPTIONS") {  // CORS preflight
    sendResponse(client, 204);
    return;
  }

  if (path == "/led") {
    if (method == "GET") {
      sendResponse(client, 200, ledStateJson());
    } else if (method == "POST" || method == "PUT") {
      handleSetLed(client, body);
    } else {
      sendError(client, 405, "use GET or POST");
    }
    return;
  }

  if (path == "/" && method == "GET") {
    sendResponse(client, 200, "{\"device\":\"DMXtra\",\"endpoints\":[\"/led\"]}");
    return;
  }

  sendError(client, 404, "not found");
}

void handleClient(WiFiClient& client) {
  client.setTimeout(1000);  // ms, for readStringUntil / readBytes

  // Request line: "POST /led HTTP/1.1"
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
  int q = path.indexOf('?');  // ignore query string for now
  if (q >= 0) path = path.substring(0, q);

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

  constexpr int MAX_BODY = 1024;
  if (contentLength > MAX_BODY) {
    sendError(client, 413, "body too large");
    return;
  }

  String body;
  if (contentLength > 0) {
    char buf[MAX_BODY + 1];
    size_t n = client.readBytes(buf, contentLength);
    buf[n] = '\0';
    body = buf;
  }

  Serial.print(method);
  Serial.print(' ');
  Serial.println(path);

  route(client, method, path, body);
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

  pinMode(PIN_R, OUTPUT);
  pinMode(PIN_G, OUTPUT);
  pinMode(PIN_B, OUTPUT);
  writeLed();  // start off

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
