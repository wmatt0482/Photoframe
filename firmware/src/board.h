// Pin map for the Waveshare ESP32-S3-PhotoPainter, taken from Waveshare's
// own firmware (github.com/waveshareteam/ESP32-S3-PhotoPainter).
#pragma once

#define PIN_EPD_DC    8
#define PIN_EPD_CS    9
#define PIN_EPD_SCK   10
#define PIN_EPD_MOSI  11
#define PIN_EPD_RST   12
#define PIN_EPD_BUSY  13   // high = idle, low = busy

#define PIN_I2C_SDA   47
#define PIN_I2C_SCL   48
#define AXP2101_ADDR  0x34

#define PIN_BTN_BOOT  0    // active low
#define PIN_BTN_KEY   4    // active low

#define PIN_LED_RED   45   // active low
#define PIN_LED_GREEN 42   // active low

#define EPD_WIDTH     800
#define EPD_HEIGHT    480
#define EPD_FRAME_BYTES (EPD_WIDTH * EPD_HEIGHT / 2)   // 4 bits per pixel
