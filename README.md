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

## iPhone app

`ios/` holds a native SwiftUI app that does what the web page does, through the same API and the same upload password: sign in, library grid, add a photo, crop, contrast and colour, a preview in the six inks, send, "Show next", delete, settings and frame status. It needs Xcode 16 or newer and iOS 17 or newer, and has no third-party packages.

Open `ios/Photoframe.xcodeproj`, pick an iPhone simulator, and press Run. From the command line:

```bash
cd ios
xcodebuild -project Photoframe.xcodeproj -scheme Photoframe \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build
```

To run it on your own iPhone, see "Signing for a real iPhone" below (signing is automatic with the owner's team set in the project).

### Send from the Photos app (share sheet)

The app includes a share extension, `PhotoframeShare`. Sign in to the app once first. Then, in Photos (or any app that shares a single picture), tap Share and choose **Photoframe**. It shows the picture cropped to the frame's current orientation in the six inks; drag to move and pinch to zoom, then tap **Send to frame**. It uses the app's defaults (contrast 1.15, colour 1.3) and the frame's flip setting, shows progress, and closes itself after "Sent". If sending fails it says why and offers Try Again or Cancel. If you have not signed in to the app, it says "Open Photoframe and sign in first" and does nothing else.

It is offered only for exactly one image (not several, not video, not web pages). The picture is read with ImageIO as a thumbnail no larger than 2400 pixels on the long side, so large HEIC photos stay well inside the share-extension memory limit.

How the extension gets the sign-in: the app and the extension both belong to the app group `group.com.matthuber.photoframe` (`ios/Config/*.entitlements`), and the Keychain items for the server address and password are stored with that app group as their access group. A sign-in saved by an earlier build of the app is moved into the shared group the next time the app opens, so nobody has to sign in again, but the app must be opened once after updating before the share sheet can see the sign-in.

Code layout: `ios/PhotoframeShare/` is the extension (loader, model, view). `ios/PhotoframeKit/` (API, Keychain, image pipeline) and `ios/PhotoframeUI/` (the crop view and its model, shared with the app's editor) are compiled into both the app and the extension; there is one copy of each file. `epd.js` is bundled into both from `server/public/epd.js`.

### Signing for a real iPhone

The simulator needs nothing. A real iPhone needs an Apple developer team, because app groups are a signed entitlement. The project has `DEVELOPMENT_TEAM = KA89MUNABZ` set on every target; to build it under a different account, change that value and the bundle ids, then:

1. In Xcode, select the project, and for **both** the `Photoframe` and `PhotoframeShare` targets choose your team under Signing & Capabilities (or set `DEVELOPMENT_TEAM` for both in the project's build settings). Leave signing automatic.
2. Check that both targets show the **App Groups** capability with `group.com.matthuber.photoframe` ticked. With automatic signing Xcode registers the group and the two bundle ids (`com.matthuber.photoframe`, `com.matthuber.photoframe.share`) for you. App group ids are unique across all Apple developers; if Xcode says the group is taken, pick another id and change it in both `.entitlements` files and in `KeychainStore.sharedAccessGroup` (`ios/PhotoframeKit/KeychainStore.swift`).
3. App Groups need a paid Apple Developer Program team; a free personal team cannot sign this entitlement.

No team-prefixed `keychain-access-groups` entitlement is needed: iOS accepts an app group as a Keychain access group.

How it relates to the web page:

- **Same image code.** The app bundles `server/public/epd.js` at build time (the Xcode project references the file; there is no copy) and runs it in JavaScriptCore, so dithering and packing are the web page's own code. A unit test checks the output is byte-identical to Node running the same file. After changing `epd.js`, run `node ios/tools/make-epd-fixture.mjs` to refresh the expected hashes, then run the tests.
- **Same API and password.** The server address and password are kept in the Keychain. The address defaults to the production Worker and can be changed on the sign-in screen.
- **Cropping differs slightly.** The crop is drawn with CoreGraphics instead of a browser canvas, so resampling can differ by a level or so per pixel. Everything after the crop matches.

Layout: `ios/Photoframe/` is the SwiftUI app. `ios/PhotoframeKit/` holds the API client, Keychain store and image pipeline with no SwiftUI dependency. `ios/PhotoframeUI/` holds the crop view shared by the app and the share extension, and `ios/PhotoframeShare/` is the share extension.

Tests (`Product > Test`, or `xcodebuild ... test`): unit tests run anywhere. The UI tests sign in, upload, use "Show next", change settings and delete, so they must point at a local dev server (see "Test without the hardware") with at least one photo in the simulator's library (`xcrun simctl addmedia booted photo.jpg`). They refuse to run against `workers.dev`. Plain `http://` is allowed only for local addresses. `ShareExtensionUITests` drives the real share sheet: it opens Photos, shares a photo to Photoframe, sends it and checks it appears in the app's library, and checks the "sign in first" message when signed out.

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

## Verified on hardware

Checked on a real ESP32-S3-PhotoPainter on 2026-11-24, powered over USB:

- **Display init and refresh.** Waveshare's register sequence works at 10 MHz SPI. A full refresh takes about 30 s.
- **Panel deep-sleep command** (`0x07 0xA5`). A second refresh after `epdSleep()` works; the reset in `epdShow()` wakes the panel.
- **Orientation.** The default came out the right way up with the frame as tested. The flip setting covers the other case.
- **WiFi, download and power chip.** The frame joins 2.4 GHz WiFi, fetches all 192,000 bytes over HTTPS, and finds the AXP2101.
- **Button wake.** A button press wakes the frame from deep sleep and fetches the next picture. A press with only one photo in the library gets a 304 and no refresh.

The serial port is the chip's built-in USB port, so it disappears while the frame sleeps. To flash a sleeping frame, put it in BOOT mode first (hold BOOT, tap power/reset, release BOOT). Some serial monitors reset the chip when they open the port, which makes a button wake look like a power-on.

## Not yet verified

- **Timer wake.** The frame was only woken by button and reset, never left for the full 30 minutes.
- **Running on battery.** All testing was on USB power.
- **Ink colours used for dithering** (`INKS` in `server/public/epd.js`). Approximate values for Spectra 6; tune them against the real panel if colours look off.
- **Battery life.** The firmware uses plain deep sleep and leaves the power chip's rails on, as the stock firmware does in its photo mode. Sleep current has not been measured.

## Security

Previews are served by photo id alone (128 random bits) so the page can show them in `<img>` tags; everything else needs the password or the frame token. WiFi credentials and the frame token are compiled into the firmware, so anyone with the frame and a USB cable can read them. There is no rate limit on password guesses, so use a long password.

## Next: text a photo to the frame

Planned as a second way in, using the same storage and frame API. The dithering code in `epd.js` has no browser dependencies so the Worker can reuse it for pictures that arrive by MMS.
