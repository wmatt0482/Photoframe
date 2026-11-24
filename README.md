# Photoframe

Replacement software for the Waveshare ESP32-S3-PhotoPainter (7.3" Spectra 6 colour e-paper frame). Add a picture from your phone and it shows up on the frame.

- `server/` is a small Cloudflare Worker that serves a phone-friendly upload page. It stores pictures and decides what the frame shows next.
- `firmware/` replaces the stock firmware. The frame wakes on a timer, asks the server for a picture, paints it, and goes back to sleep.

## How it works

```
phone browser                      Cloudflare Worker + D1            frame (ESP32-S3)
-------------                      ----------------------            ----------------
crop, dither to 6 inks,   POST     store 192,000-byte frame   GET    wake, join WiFi,
pack for the panel      -------->  and a small preview      <------  paint, deep sleep
```

The browser does all the image work: cropping, dithering to the panel's six inks, and packing into the exact bytes the panel wants. The frame never decodes an image; it streams 192,000 bytes straight to the display. That keeps the firmware small and the time awake short.

The frame cannot be pushed to while it sleeps. A new picture appears at the next check-in (every 30 minutes by default), or right away if you press the BOOT or KEY button on the frame.

## Set up the server

You need a free Cloudflare account and Node.js 20 or newer.

```bash
cd server
npm install
npx wrangler login
npx wrangler d1 create photoframe
```

Copy the `database_id` that command prints into `wrangler.toml`, then:

```bash
npm run migrate
npx wrangler secret put UPLOAD_PASSWORD
npx wrangler secret put FRAME_TOKEN
npm run deploy
```

`UPLOAD_PASSWORD` is what you (and anyone you share the frame with) type into the web page. `FRAME_TOKEN` is what the frame sends; make it long and random, for example with `openssl rand -hex 24`. Both must be at least 8 characters. The server refuses all requests until both are set.

Open the URL that `deploy` prints, sign in, and add a photo. On a phone, use "Add to Home Screen" to get an app icon.

## Flash the frame

You need [PlatformIO](https://platformio.org/install/cli) and a USB-C cable.

```bash
cd firmware
cp src/config.example.h src/config.h
```

Edit `src/config.h` with your WiFi name and password, the server URL, and the same `FRAME_TOKEN`. Then plug in the frame and run:

```bash
pio run -t upload
pio device monitor
```

If the upload cannot find the board, hold BOOT, tap the power/reset button, release BOOT, and try again.

The frame only supports 2.4 GHz WiFi.

To go back to the stock firmware, flash the image in Waveshare's repository (`03_Firmware/`) following [their wiki](https://www.waveshare.com/wiki/ESP32-S3-PhotoPainter).

## Using it

| Action | Result |
| --- | --- |
| Add a photo | Shown at the frame's next check-in, ahead of the regular rotation |
| Tap a photo, "Show next" | Jumps the queue |
| Press BOOT or KEY on the frame | Checks in now and moves to the next picture |
| Settings, "Check for new photos" | How often the frame wakes. More often costs battery |
| Settings, "Change picture when nothing is new" | Rotation through the library |
| Settings, orientation and flip | Applies to photos added afterwards |

If pictures come out upside down, tick "flip them" in Settings and re-add the photo.

## Test without the hardware

```bash
cd server
cp .dev.vars.example .dev.vars
npm run migrate:local
npm run dev
```

In another terminal:

```bash
npm test
node test/api.integration.mjs http://127.0.0.1:8787 dev-password dev-frame-token
node tools/fake-frame.mjs http://127.0.0.1:8787 dev-frame-token --out frame.png
```

`fake-frame.mjs` makes the same request the firmware makes and saves what the panel would show as a PNG.

## Frame API

`GET /api/frame/next?have=<photo id>&advance=0|1&mv=&pct=&usb=&rssi=&fw=` with `Authorization: Bearer <FRAME_TOKEN>`.

| Status | Meaning |
| --- | --- |
| 200 | Body is 192,000 bytes: 800x480, 4 bits per pixel, left pixel in the high nibble. `X-Photo-Id` names it |
| 304 | Keep showing the current picture |
| 204 | Nothing uploaded yet |

`X-Sleep-Seconds` is always present and says when to ask again. Ink codes: 0 black, 1 white, 2 yellow, 3 red, 5 blue, 6 green.

## Hardware notes

Taken from [Waveshare's source](https://github.com/waveshareteam/ESP32-S3-PhotoPainter); see `firmware/src/board.h`.

| Function | GPIO |
| --- | --- |
| Display DC / CS / SCK / MOSI / RST / BUSY | 8 / 9 / 10 / 11 / 12 / 13 |
| I2C SDA / SCL (AXP2101 power chip at 0x34) | 47 / 48 |
| BOOT / KEY buttons (active low) | 0 / 4 |
| Red / green LED (active low) | 45 / 42 |

## Not yet verified

The server and web page are tested. The firmware compiles but has not run on a real frame, so expect to check these on first power-up:

- **Display init and refresh.** The register sequence is copied from Waveshare's driver for this board, at 10 MHz SPI instead of their 40 MHz.
- **Panel deep-sleep command** (`0x07 0xA5` in `epd.cpp`). Standard for Waveshare's 7.3" E6 panels but not in this board's stock driver. If the second refresh misbehaves, remove the `epdSleep()` call first.
- **Orientation.** Defaults mirror the stock firmware's rotation. The flip setting covers the other case.
- **Ink colours used for dithering** (`INKS` in `server/public/epd.js`). Approximate values for Spectra 6; tune them against the real panel if colours look off.
- **Battery life.** The firmware uses plain deep sleep and leaves the power chip's rails on, as the stock firmware does in its photo mode. Sleep current has not been measured.

## Security

Previews are served by photo id alone (128 random bits) so the page can show them in `<img>` tags; everything else needs the password or the frame token. WiFi credentials and the frame token are compiled into the firmware, so anyone with the frame and a USB cable can read them. There is no rate limit on password guesses, so use a long password.

## Next: text a photo to the frame

Planned as a second way in, using the same storage and frame API. The dithering code in `epd.js` has no browser dependencies so the Worker can reuse it for pictures that arrive by MMS.
