// Photoframe firmware for the Waveshare ESP32-S3-PhotoPainter.
//
// Each wake: join WiFi, ask the server whether there is a new picture, paint
// it if there is, then go back to deep sleep for as long as the server says.
// Pressing BOOT or KEY wakes the frame early and asks for the next picture.

#include <Arduino.h>
#include <WiFi.h>
#include <Wire.h>
#include <Preferences.h>
#include <esp_http_client.h>
#include <esp_crt_bundle.h>
#include <esp_sleep.h>
#include <driver/rtc_io.h>

#define XPOWERS_CHIP_AXP2101
#include <XPowersLib.h>

#include "board.h"
#include "config.h"
#include "epd.h"

#define FW_VERSION "1"

static const uint32_t kWifiTimeoutMs   = 20000;
static const uint32_t kHttpTimeoutMs   = 20000;
static const uint32_t kDefaultSleepSec = 30 * 60;
static const uint32_t kMinSleepSec     = 5 * 60;
static const uint32_t kMaxSleepSec     = 24 * 60 * 60;
static const uint32_t kRetryBaseSec    = 15 * 60;
static const uint32_t kRetryMaxSec     = 6 * 60 * 60;

// Survives deep sleep, resets on power loss. Drives the retry backoff.
RTC_DATA_ATTR static uint8_t failCount = 0;

static XPowersPMU pmu;
static bool pmuOk = false;
static Preferences prefs;

struct FetchResult {
  int status = 0;              // HTTP status, or 0 if the request never completed
  size_t received = 0;
  uint32_t sleepSec = 0;
  char photoId[40] = {0};
};
static FetchResult fetched;

static void led(int pin, bool on) { digitalWrite(pin, on ? LOW : HIGH); }

static void setupPmu() {
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL);
  pmuOk = pmu.begin(Wire, AXP2101_ADDR, PIN_I2C_SDA, PIN_I2C_SCL);
  if (!pmuOk) {
    Serial.println("PMU not found; continuing without battery data");
    return;
  }
  // Same rail and charger setup as Waveshare's firmware.
  pmu.setVbusCurrentLimit(XPOWERS_AXP2101_VBUS_CUR_LIM_2000MA);
  if (pmu.getDC1Voltage() != 3300) pmu.setDC1Voltage(3300);
  if (pmu.getALDO1Voltage() != 3300) pmu.setALDO1Voltage(3300);
  if (pmu.getALDO2Voltage() != 3300) pmu.setALDO2Voltage(3300);
  if (pmu.getALDO3Voltage() != 3300) pmu.setALDO3Voltage(3300);
  if (pmu.getALDO4Voltage() != 3300) pmu.setALDO4Voltage(3300);
  pmu.setPrechargeCurr(XPOWERS_AXP2101_PRECHARGE_50MA);
  pmu.setChargerConstantCurr(XPOWERS_AXP2101_CHG_CUR_500MA);
  pmu.setChargerTerminationCurr(XPOWERS_AXP2101_CHG_ITERM_25MA);
  pmu.enableBattDetection();
  pmu.enableBattVoltageMeasure();
}

static bool connectWifi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED) {
    if (millis() - start > kWifiTimeoutMs) return false;
    delay(100);
  }
  return true;
}

static esp_err_t onHttpEvent(esp_http_client_event_t *evt) {
  if (evt->event_id != HTTP_EVENT_ON_HEADER) return ESP_OK;
  if (strcasecmp(evt->header_key, "X-Sleep-Seconds") == 0) {
    fetched.sleepSec = strtoul(evt->header_value, nullptr, 10);
  } else if (strcasecmp(evt->header_key, "X-Photo-Id") == 0) {
    strlcpy(fetched.photoId, evt->header_value, sizeof(fetched.photoId));
  }
  return ESP_OK;
}

// Asks the server for the next frame. On HTTP 200 the body is read into
// `frame`, which must hold EPD_FRAME_BYTES.
static void fetchFrame(const String &have, bool advance, uint8_t *frame) {
  fetched = FetchResult();

  char url[320];
  snprintf(url, sizeof(url),
           "%s/api/frame/next?have=%s&advance=%d&mv=%d&pct=%d&usb=%d&rssi=%d&fw=%s",
           SERVER_URL, have.c_str(), advance ? 1 : 0,
           pmuOk ? (int)pmu.getBattVoltage() : 0,
           pmuOk ? (int)pmu.getBatteryPercent() : -1,
           pmuOk && pmu.isVbusIn() ? 1 : 0,
           (int)WiFi.RSSI(), FW_VERSION);

  esp_http_client_config_t cfg = {};
  cfg.url = url;
  cfg.timeout_ms = kHttpTimeoutMs;
  cfg.event_handler = onHttpEvent;
  cfg.crt_bundle_attach = esp_crt_bundle_attach;
  cfg.buffer_size = 4096;

  esp_http_client_handle_t client = esp_http_client_init(&cfg);
  if (!client) return;
  esp_http_client_set_header(client, "Authorization", "Bearer " FRAME_TOKEN);

  if (esp_http_client_open(client, 0) == ESP_OK &&
      esp_http_client_fetch_headers(client) >= 0) {
    fetched.status = esp_http_client_get_status_code(client);
    if (fetched.status == 200) {
      while (fetched.received < EPD_FRAME_BYTES) {
        int n = esp_http_client_read(client, (char *)frame + fetched.received,
                                     EPD_FRAME_BYTES - fetched.received);
        if (n <= 0) break;
        fetched.received += n;
      }
    }
  }
  esp_http_client_close(client);
  esp_http_client_cleanup(client);
}

static void sleepFor(uint32_t seconds) {
  seconds = constrain(seconds, kMinSleepSec, kMaxSleepSec);
  Serial.printf("Sleeping %lu s\n", (unsigned long)seconds);
  Serial.flush();

  led(PIN_LED_RED, false);
  led(PIN_LED_GREEN, false);
  WiFi.disconnect(true);
  WiFi.mode(WIFI_OFF);

  // A button still held down would wake the frame again immediately.
  while (digitalRead(PIN_BTN_BOOT) == LOW || digitalRead(PIN_BTN_KEY) == LOW) delay(50);

  const uint64_t buttons = (1ULL << PIN_BTN_BOOT) | (1ULL << PIN_BTN_KEY);
  esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_PERIPH, ESP_PD_OPTION_ON);
  rtc_gpio_pulldown_dis((gpio_num_t)PIN_BTN_BOOT);
  rtc_gpio_pullup_en((gpio_num_t)PIN_BTN_BOOT);
  rtc_gpio_pulldown_dis((gpio_num_t)PIN_BTN_KEY);
  rtc_gpio_pullup_en((gpio_num_t)PIN_BTN_KEY);
  esp_sleep_enable_ext1_wakeup_io(buttons, ESP_EXT1_WAKEUP_ANY_LOW);
  esp_sleep_enable_timer_wakeup((uint64_t)seconds * 1000000ULL);
  esp_deep_sleep_start();
}

static void sleepAfterFailure(const char *why) {
  Serial.printf("Failed: %s\n", why);
  uint32_t wait = kRetryBaseSec;
  for (uint8_t i = 0; i < failCount && wait < kRetryMaxSec; i++) wait *= 2;
  if (failCount < 10) failCount++;
  sleepFor(min(wait, kRetryMaxSec));
}

void setup() {
  Serial.begin(115200);
  pinMode(PIN_LED_RED, OUTPUT);
  pinMode(PIN_LED_GREEN, OUTPUT);
  pinMode(PIN_BTN_BOOT, INPUT_PULLUP);
  pinMode(PIN_BTN_KEY, INPUT_PULLUP);
  led(PIN_LED_RED, false);
  led(PIN_LED_GREEN, true);

  bool buttonWake = esp_sleep_get_wakeup_cause() == ESP_SLEEP_WAKEUP_EXT1;
  Serial.printf("\nPhotoframe fw %s, wake: %s\n", FW_VERSION, buttonWake ? "button" : "timer/power");

  setupPmu();
  epdBegin();

  prefs.begin("frame", false);
  String have = prefs.getString("have", "");

  uint8_t *frame = (uint8_t *)ps_malloc(EPD_FRAME_BYTES);
  if (!frame) sleepAfterFailure("no memory for frame buffer");

  if (!connectWifi()) sleepAfterFailure("WiFi did not connect");

  fetchFrame(have, buttonWake, frame);
  WiFi.disconnect(true);
  WiFi.mode(WIFI_OFF);
  Serial.printf("HTTP %d, %u bytes, photo '%s'\n", fetched.status, (unsigned)fetched.received, fetched.photoId);

  uint32_t sleepSec = fetched.sleepSec ? fetched.sleepSec : kDefaultSleepSec;

  if (fetched.status == 200) {
    if (fetched.received != EPD_FRAME_BYTES) sleepAfterFailure("short download");
    if (!epdShow(frame, EPD_FRAME_BYTES)) {
      led(PIN_LED_RED, true);
      delay(2000);
      sleepAfterFailure("display did not respond");
    }
    epdSleep();
    prefs.putString("have", fetched.photoId);
  } else if (fetched.status != 304 && fetched.status != 204) {
    // 304: already showing the right picture. 204: nothing uploaded yet.
    sleepAfterFailure("server request failed");
  }

  failCount = 0;
  sleepFor(sleepSec);
}

void loop() {}
