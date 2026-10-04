# Scuba

Scuba is a menu bar app for macOS that arranges your windows into pools.
Any pool can hold a whole layout of its own, so you can zoom into a pool to
work at full size and zoom back out to see everything at once.

![Going from the desktop into Main, then into a pool, then into a pool inside that](docs/images/recording.gif)

**[⬇ Download the latest version](../../releases/latest)** · Apple silicon Macs, macOS 14 or newer

> **Early test build.** Expect rough edges. Saved pools and live portholes
> are **BETA**. Feedback and bug reports are welcome on the
> [Issues page](../../issues).

## What it does

- **Pools.** Each board is split into pools, and each pool holds one or
  more windows, filling it or floating inside it. Drag a window onto a pool,
  or press Hyper + a number.
- **Pools inside pools.** Any pool can hold a board of its own. Zoom in to
  work at full size, zoom out to see everything in miniature. The menu bar
  shows where you are, like `Main › 3 › 3`.
- **Zooming with the trackpad.** Swipe down with three fingers to zoom into
  the pool under the pointer, up to zoom out, sideways to move to the next
  board.
- **Your desktop stays as it is.** Scuba only arranges windows once you go
  in (Hyper + ↑). Hyper + Esc puts your normal desktop back.
- **Portholes.** On a nested board, a window too big for its pool shows as
  a picture of itself instead of spilling over its neighbours.
- **Breathing room, hiding, cut/copy/paste, spotlight** and more. See the
  [user guide](docs/USER_GUIDE.md).
- **Saved pools (BETA).** Save a pool with its apps and layout, close it,
  and open it again later. Browser tabs come back too.

![Main, then pool 3, then pool 3 inside that](docs/images/zoom-levels.jpg)

## Install

You need a Mac with Apple silicon (M1 or newer) on macOS 14 or newer.

1. Download **Scuba Test Build.zip** from the [latest release](../../releases/latest).
2. Unzip it, drag Scuba into Applications, and open it.
3. macOS will block the first launch because the app isn't from the App
   Store. Click **Done**, then go to **System Settings › Privacy & Security**
   and click **Open Anyway**.
4. In the Setup window, turn on **Accessibility** (required) and **Screen
   Recording** (optional, for animations and portholes).

The zip includes a **Start Here.txt** with the same steps and the basic
moves. The [user guide](docs/USER_GUIDE.md) covers everything else.

## Build from source

You need Xcode or the Xcode Command Line Tools.

```
git clone https://github.com/Canobiir/Scuba.git
cd Scuba
./build.sh
open build/Scuba.app
```

- `dev/setup-signing.sh` (run once) creates a local signing certificate,
  so macOS keeps Scuba's permissions across rebuilds.
- `./build.sh --share` also makes **Scuba Test Build.zip** on your Desktop,
  ready to attach to a release or send to someone.

## Documentation

- [User guide](docs/USER_GUIDE.md): installing, the main ideas, and how to
  use every feature, with screenshots
- [Feature reference](docs/REFERENCE.md): detailed notes on each feature
  and setting

## License

[MIT](LICENSE)
