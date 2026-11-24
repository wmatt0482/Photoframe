#pragma once
#include <Arduino.h>

// Minimal driver for the 7.3" Spectra 6 (E6) panel. It takes a frame that is
// already packed for the panel (800x480, 4 bits per pixel, high nibble first)
// so the microcontroller never has to decode or dither an image.

void epdBegin();

// Sends the frame and runs a full refresh (roughly 20-30 s). Returns false if
// the panel never released BUSY, which usually means a cable or power problem.
bool epdShow(const uint8_t *frame, size_t len);

// Puts the panel controller into deep sleep. epdShow() wakes it with a reset.
void epdSleep();
