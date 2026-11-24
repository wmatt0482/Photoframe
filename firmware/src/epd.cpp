#include "epd.h"
#include "board.h"
#include <SPI.h>

// Init sequence and refresh flow follow Waveshare's display_bsp.cpp for this
// board. The register values are theirs; do not tune them without the panel
// datasheet in hand.

static SPIClass epdSpi(FSPI);
static const SPISettings kSpi(10000000, MSBFIRST, SPI_MODE0);
static const uint32_t kBusyTimeoutMs = 60000;

static void sendCommand(uint8_t reg) {
  digitalWrite(PIN_EPD_DC, LOW);
  digitalWrite(PIN_EPD_CS, LOW);
  epdSpi.transfer(reg);
  digitalWrite(PIN_EPD_CS, HIGH);
}

static void sendData(const uint8_t *data, size_t len) {
  digitalWrite(PIN_EPD_DC, HIGH);
  digitalWrite(PIN_EPD_CS, LOW);
  epdSpi.writeBytes(data, len);
  digitalWrite(PIN_EPD_CS, HIGH);
}

static void command(uint8_t reg, std::initializer_list<uint8_t> args = {}) {
  sendCommand(reg);
  for (uint8_t b : args) sendData(&b, 1);
}

static bool waitIdle() {
  uint32_t start = millis();
  while (digitalRead(PIN_EPD_BUSY) == LOW) {
    if (millis() - start > kBusyTimeoutMs) return false;
    delay(10);
  }
  return true;
}

static void reset() {
  digitalWrite(PIN_EPD_RST, HIGH); delay(50);
  digitalWrite(PIN_EPD_RST, LOW);  delay(20);
  digitalWrite(PIN_EPD_RST, HIGH); delay(50);
}

void epdBegin() {
  pinMode(PIN_EPD_BUSY, INPUT_PULLUP);
  pinMode(PIN_EPD_RST, OUTPUT);
  pinMode(PIN_EPD_DC, OUTPUT);
  pinMode(PIN_EPD_CS, OUTPUT);
  digitalWrite(PIN_EPD_CS, HIGH);
  digitalWrite(PIN_EPD_RST, HIGH);
  epdSpi.begin(PIN_EPD_SCK, -1, PIN_EPD_MOSI, -1);
}

bool epdShow(const uint8_t *frame, size_t len) {
  if (len != EPD_FRAME_BYTES) return false;

  epdSpi.beginTransaction(kSpi);
  reset();
  bool ok = waitIdle();
  delay(50);

  if (ok) {
    command(0xAA, {0x49, 0x55, 0x20, 0x08, 0x09, 0x18});
    command(0x01, {0x3F});
    command(0x00, {0x5F, 0x69});
    command(0x03, {0x00, 0x54, 0x00, 0x44});
    command(0x05, {0x40, 0x1F, 0x1F, 0x2C});
    command(0x06, {0x6F, 0x1F, 0x17, 0x49});
    command(0x08, {0x6F, 0x1F, 0x1F, 0x22});
    command(0x30, {0x03});
    command(0x50, {0x3F});
    command(0x60, {0x02, 0x00});
    command(0x61, {0x03, 0x20, 0x01, 0xE0});   // 800 x 480
    command(0x84, {0x01});
    command(0xE3, {0x2F});
    command(0x04);                             // power on
    ok = waitIdle();
  }

  if (ok) {
    sendCommand(0x10);                         // frame data
    const size_t kChunk = 4096;
    for (size_t off = 0; off < len; off += kChunk) {
      sendData(frame + off, min(kChunk, len - off));
    }

    command(0x04);                             // power on
    ok = waitIdle();
  }
  if (ok) {
    command(0x06, {0x6F, 0x1F, 0x17, 0x49});
    command(0x12, {0x00});                     // refresh
    ok = waitIdle();
  }
  if (ok) {
    command(0x02, {0x00});                     // power off
    ok = waitIdle();
  }

  epdSpi.endTransaction();
  return ok;
}

void epdSleep() {
  epdSpi.beginTransaction(kSpi);
  command(0x07, {0xA5});                       // deep sleep; reset wakes it
  epdSpi.endTransaction();
}
