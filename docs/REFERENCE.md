# Scuba feature reference

Detailed notes on each feature and setting. For a walkthrough with
screenshots, start with the [user guide](USER_GUIDE.md).

## How it works

- **The Surface is your normal Mac desktop.** Scuba stays out of the
  way there: windows behave exactly as usual.
- **Dive in with Hyper + ↑** (or hold Hyper and scroll up). Your desktop
  windows step aside and your boards appear, right where you left off.
- **Come up for air with Hyper + Esc** from any depth (or keep zooming out).
  Boards tuck away and your desktop comes back exactly as it was.
- The deeper you go, the darker the background gets; the Surface is always clear.
- You start with **two pools**, 1 on the left and 2 on the right.
- **Every desktop numbers its own pools**, and a pool keeps its number when
  you add or delete others. Pool 2 inside pool 4 is always "4 › 2".
- **Zoom into a pool** and it becomes a desktop of its own, filling the
  screen. Add pools there, put windows in them, then zoom out: that whole
  layout sits inside the original pool.
- Windows that belong to other desktops are tucked into the bottom-right
  corner while you're elsewhere. Quitting the app brings them all back.

## Shortcuts  (Hyper = Ctrl + Option + Cmd)

| Keys | Does |
| --- | --- |
| Hyper + ↑ | Dive in from your desktop, or zoom into the pool you're working in |
| Hyper + ↓ | Zoom out one level (stops at Main; turn that off in Motion & feel to go on to your desktop) |
| Hyper + scroll up / down | Dive into the pool under the pointer / zoom out. From Main it goes on to your desktop, and from your desktop back in to Main |
| Hyper + Esc | Straight back to your desktop from any depth |
| Hold Hyper | See the board's pools, names and what's inside |
| Hyper + 1–9 (or U I J K for 1–4) | Put the focused window in that pool |
| Hyper + ← / → | Move to the previous / next pool |
| Hyper + Shift + 1–9 | Zoom into that pool |
| Hyper + Shift + U / I / J / K | Jump into top-level pool 1 / 2 / 3 / 4 from anywhere |
| Hyper + – | Zoom out one level (same as Hyper + ↓) |
| Hyper + 0 | Zoom to the top level |
| Hyper + H | Go Home |
| Hyper + Shift + H | Make the current desktop Home |
| Hyper + N | Add a pool to the right of the current one |
| Hyper + Shift + N | Add a pool below |
| Hyper + Delete | Delete the current pool (its windows move to the neighbor) |
| Hyper + Shift + Delete | Delete every empty pool on the board you're on |
| Hyper + T | Flip the pool's group: side by side ⇄ stacked |
| Hyper + F | Switch the focused window between floating and filling its pool |
| Hyper + Shift + arrow keys | Grow the current pool toward that side |
| Hyper + drag a gap between pools | Resize pools with the mouse |
| Hyper + G | Show pool numbers |
| Hyper + Shift + G | Tidy up and renumber pools in reading order |
| Hyper + R / Hyper + Shift + R | Name this pool / name this board |
| Hyper + Z | Undo the last layout change |
| Three-finger click on a window or porthole | Spotlight it; again to put it back |
| Hyper + click a window | Spotlight: blow it up over the board to work in it. Hyper + click it again (or Hyper + Return) to put it back; Hyper + click another window to switch |
| Hyper + Return | Spotlight the focused window, or end Spotlight |
| Hyper + D | Send the Spotlight window (or the focused one) to your desktop: it leaves your boards and is there when you go back to your desktop. On your desktop: pick a pool (named ones first) to send the focused window to; it fits in as best it can and is hidden from the view above |
| Pinch out / pinch in | Over empty space (desktop, a gap, an empty pool): dive into the pool under the pointer / come back up. Hold Hyper to pinch over windows too; with Hyper, pinching in from Main goes on to your desktop, and out from your desktop lands on Main |
| Double-click a title bar | If the window is on a board nested inside this one, dive straight to that board; on this board, Spotlight it (again to put it back) |
| Hyper + L | Show / hide the lobby in the breathing room |
| Hyper + [ / ] or Hyper + swipe sideways | Step to the previous / next board on this level (from Main: the next Main, or a new blank one) |
| Hyper + X | Cut the focused window (Hyper + X again puts it back) |
| Hyper + C | Copy the focused window: pasted, it's in both pools |
| Hyper + V | Put the cut or copied window in the pool under the pointer |
| Hyper + P | Hide the window under the pointer when you zoom out (again shows it) |
| Hyper + Shift + P | Hide the whole pool under the pointer when you zoom out (again shows it) |
| Hyper + O  or  Hyper + F3 | Overview of all boards: click a board, pool or window to jump there |
| Hyper + Shift + X | Stop managing the focused window (it won't rejoin on its own) |
| Hyper + / | Show these shortcuts |

The "current pool" is the one holding the window you're using.
Everything is also in the ⊞ menu.

## Dragging windows

Drag any window by its title bar. The pool under the pointer shows snap bars:

- **Fill** (the bar in the middle): the window snaps to fill that pool.
- **Edge bars**: a new pool is created on that side with the window in it.
- **Anywhere else** in a pool: the window floats right where you dropped it,
  as part of that pool, and scales with the pool when it resizes or zooms.
- Hold **Option** when letting go to leave the window alone.
- **Throw it.** Let go while the window is still moving fast and it carries
  on in that direction, landing in the pool it was heading for. An empty
  pool takes it whole; in a pool that's in use, it lands in the half where
  it came down and the windows there make room.

## Resizing

Drag the edge of a window that fills its pool and the gap on that side
follows: the pool next door gives way as you drag, and the window stays
filled. Edges along the outside of the board, and windows that float,
resize as usual (a filled window resized from an outside edge starts to
float). Hyper + Z puts the gap back.

## New windows

While you're inside, any new window you open joins the board you're on. If
the board has an empty pool (the breathing room, say), the window goes there
first and fills it, the nearest one if there are several. Otherwise it
opens in Spotlight, enlarged over the board, so you can drag it onto the
pool you want. Leave it unplaced (go back to another window, or move to
another board) and it goes to your normal desktop. Hyper + Return instead
leaves it floating on top of the pool it opened over (the windows already there stay as they are); drag it, or
press Hyper + F, to make it an ordinary window of its pool. Turn the
Spotlight part off in the menu: "When every pool is in use, new windows open
in Spotlight" (they float on top straight away instead). Turn either off in the ⊞ menu.

## A wallpaper for each board

Inside your boards, the background is your Mac's wallpaper exactly as it's
showing right now, dynamic and moving wallpapers included (with Screen
Recording on; without it, the wallpaper's picture file is used).

⊞ › **Wallpaper for this board…** picks a picture to show behind the board
you're on, and behind the boards inside it unless they have their own. Dive
in and the new wallpaper comes into view with the zoom. Your Mac's own
wallpaper is untouched and still shows on your desktop. **Use the wallpaper
from above here** goes back to the parent board's (or your Mac's).

## Pool boundaries

⊞ › **Show pool boundaries** draws a faint outline around each pool of the
board you're on, so a cluttered board reads at a glance. Only that board's
own pools are outlined: a pool holding a board of its own is one outline,
never a breakdown of what's inside. The outlines sit behind every window, so
they show in the gaps between windows and across open space and never cover
anything.

## Motion

Dives start the moment you ask: Scuba takes the screen's picture as soon as
you press Hyper or put three fingers down, instead of after. Zooms, glides
and sideways steps play at 120 Hz on ProMotion screens.

Rearrangements glide instead of jumping: when you drop or throw a window,
add, delete or flip a pool, close a window, tidy up or undo, the windows
slide to their new places. Like the zoom, this uses Screen Recording; without
it, things just move. Every one of these behaviours can be switched off
under ⊞ › **Motion & feel**.

## Mission Control and Cmd + Tab

Windows on other boards are tucked into the bottom-right corner. If **all** of
an app's windows are on other boards, Scuba also hides that app
(like Cmd + H), so it stays out of Mission Control. Apps with a window on the
board you're on stay visible.

When an app also has a window on the board you're on, its tucked-away
windows would still show in Mission Control. So a window that has been tucked
away for a few seconds is minimized in its corner as well, which takes it out
of Mission Control; going to its board brings it back. Turn it off in the
menu: "Keep tucked-away windows out of Mission Control". Tip: turn on
"Minimize windows into application icon" in System Settings › Desktop & Dock,
so these windows don't line up next to the Trash.

Switching to an app that lives on another board (Cmd + Tab, or clicking it in
the Dock) takes you to that board. Opening a new window instead (Cmd + N, or
New Window from the app's Dock menu) keeps you where you are, and the new
window joins the board you're on.

For a cleaner view of everything, use the Overview (Hyper + O): a map of every
board, with each window shown as its app icon and name.

## Filled windows make room

When a window floats in a pool, the pool's filled windows shrink into the
biggest open area beside it instead of sitting underneath. Move or resize the
floating window and they adjust; take it out and they fill the pool again.
If the open area would be too small to be useful, the filled windows take the
whole pool and the float sits on top. Turn it off in the menu: "Filled
windows make room for floating ones".

## Stacks turn side by side on wide screens

A board fits the shape it's shown in. Stack two windows in the tall left half
of Home, dive into that pool, and on the wide full screen they sit side by
side; come back up and they're stacked again. Each split remembers the shape
it was last shown in, so if you flip it yourself (Hyper + T) that choice holds
for that shape. Turn it off in the menu: "Stacks turn side by side on wide
screens".

## Cramped pools become app icons

A pool that's too small to be useful (narrower than about 340 points or
shorter than about 230, which happens with boards nested inside boards)
shows as a tile with its main app's icon and name, plus "+2" if more windows
are in there, instead of squashed windows. Click the tile to dive straight
into that pool. Turn it off in the menu: "Show cramped pools as app icons".

## Portholes

Some apps (Safari, for one) won't shrink below a certain size. On a board
nested inside the one you're on, such a window would spill over the pools
beside it. Instead it shows as a porthole: a frosted picture of the window,
cropped at its pool's edge, with its app's icon and name. Windows that fit
stay real and usable.

- **Click** a porthole to dive to its board, where the window is full size.
- **Hyper + click** it to spotlight the window right where you are. Hyper +
  click it again (or Hyper + Return) puts it back.
- Under ⊞ → Settings → Windows & pools → **Windows too big for a nested
  pool**, choose frosted portholes (the default), live portholes (BETA) or
  none (windows spill over).

**Live portholes (BETA)** show the whole window shrunk to fit its spot,
kept up to date as it changes, with its app's icon in the corner. They need
Screen Recording, and macOS shows its screen-recording icon while they're
on screen. An app with a live porthole isn't hidden by Scuba (macOS won't
show a hidden app's windows), so that window can show in Mission Control.

## Zooming and moving between boards

- **Steer the zoom with your fingers.** Hold Hyper and scroll on the trackpad:
  pull toward you to dive into the pool under the pointer, push away to come
  back up. The zoom follows your fingers; let go past about a third of the way
  and it finishes, otherwise it floats back. A mouse wheel still zooms one
  step per flick.
- **Flight paths.** Going somewhere that isn't directly above or below you
  (from the Overview, Cmd + Tab, Home, a top-level jump), the camera rises to
  the board both places share, then dives down to the new one.
- **Wallpaper parallax.** Your desktop picture zooms in a little with each
  level you dive and back out as you rise. Turn it off in the menu:
  "Wallpaper zooms as you dive".
- **The camera.** Zooms play between pictures of the screen: the pool grows
  to fill the screen (or shrinks back into its board) while the rest of the
  board dims, and the real windows move underneath out of sight. Pictures of
  places you've just been are remembered, so coming back up shows the board
  you're returning to from the first frame. Needs Screen Recording permission;
  without it zooms snap.
- **Breathing room.** Press **Hyper + B** to open a quarter of the screen
  as an empty pool on the board you're on, in the bottom corner on the side
  facing the middle of the screen. Press it again to fold it away. It's
  private: the room, and anything you put in it, only shows on this board.
  A quarter has the screen's own shape, so it reads as a little desktop of
  its own: swipe down over it and you dive straight in. What's on the board
  makes way: the pool nearest that corner moves into the quarter above the
  room and the rest share the other half. A board that's a single pool
  splits its windows the same way (Claude keeps the left half, Safari takes
  the quarter above the room); with only one window (or none), the window
  keeps one half and the room takes the other, so Hyper + B always adds just
  one pool.
  Leave the room empty and it folds away when you go back up, and the board
  goes back exactly as it was. Diving in doesn't add room by itself, so you
  arrive to your windows filling the screen (stacks turned side by side).
  In the menu under **Breathing room** you can have it open every time you
  dive in, pick the side (toward the middle of the screen, always left or
  always right), choose the top or bottom corner, or use a narrow, medium or
  wide strip along the side instead, and switch the lobby on or off
  (Hyper + L). Shape changes apply right away to a room that's open.
- **The lobby.** When a board has breathing room, the empty pool becomes a
  lobby: a "↑ Main" button to float back up, a little map of the board above
  with your spot lit up, and a door card for each neighbouring board (its
  apps' icons and names). Click a door, or a cell on the map, to step across.
- **Stepping sideways.** Hyper + [ / ], or Hyper + a sideways swipe on the
  trackpad, steps to the previous / next board on the same level. The camera
  eases back until both boards are in view, drifts across and settles into
  the new one — no trip up to Home and back.
- **See where a window will land.** While you drag a window over a pool,
  that pool's filled windows make room for it live, so you see the layout
  you're about to drop into. Over an edge bar, the pool's windows slide into
  the half they'll keep. Let go outside a pool (or hold Option) and they go
  back where they were.
- **Three-finger swipes.** No keys needed: swipe down with three fingers to
  dive into the pool under the pointer and up to come back up (both follow
  your fingers and finish or float back when you lift), and swipe left /
  right to step to the next / previous board on this level. Sideways swipes
  follow your fingers too: swipe slowly and you see the next board coming
  in; let go early, or swipe back, and it floats back. A quick flick goes
  straight across. macOS uses
  three-finger swipes for Mission Control and Spaces by default, so set those
  to four fingers in System Settings › Trackpad › More Gestures. Turn it off
  in the menu: "Three-finger swipes".
- **Inside-only pools.** A breathing-room pool you put something in (a
  third app beside your two, say) only shows on its own board: from Main it
  folds away and the board shows its original arrangement; dive in and it
  opens back up. Hyper + Shift + P over a pool hides it the same way (or
  shows it again). Seen from above, a board also folds away its
  empty pools, and what's left spreads out to fill the space. Menu:
  Breathing room → "Fold inside-only and empty pools away from above".
- **Pools grow to fit apps that won't shrink.** Some apps (Apple Music, for
  one) have a minimum window size. When a pool on the board you're on is
  smaller than that, it grows along its row or column just enough to hold
  the window, taking the space evenly from its neighbours (up to 80% of the
  row). Menu: "Pools grow to fit apps that won't shrink".
- **Inside-only windows.** Hyper + P on the window you're using makes it
  only show on its own board, like a breathing-room pool but for one
  window. From above it's tucked away and the windows sharing its pool
  spread into its space (a pool left with nothing showing folds away). It
  stays inside-only wherever you move it; Hyper + P again shows it
  everywhere. Also in the menu under Breathing room.
  When a hidden window leaves the rest of its pool all floating (Music
  above Messages, say), what's left stretches as a group to fill the pool
  from above, keeping its arrangement; on its own board everything returns.

## More than one Main

From Main, swipe sideways with three fingers (or Hyper + [ / ]) and a new,
blank Main slides in beside it, like a fresh Space: one empty pool to build
in. Keep swiping to move between your Mains. Leave a blank one without
putting anything in it and it folds away; put something in it and it stays
as "Main 2" (Hyper + Shift + R names it). Switching to an app whose windows
are on another Main slides you over there. Home remembers which Main it's
on. The Overview shows the Main you're on.

## Zooming out past Main: the Overview

Zooming out from Main (a three-finger swipe up, a pinch in, Hyper + ↓)
keeps going: Main shrinks into its place on the Overview, with your other
Mains side by side around it, each showing its boards, pools and windows.
Click anything on it, or swipe down or pinch out over it, and the camera
dives straight into it (onto another Main too). Hyper + ↑ goes back into
where you were; Esc closes it. The Overview is as far out as zooming goes:
Hyper + Esc (or Hyper + a swipe up) takes you to your desktop. Hyper + O
opens it from anywhere. Turn it off under Motion & feel: "Zooming out past
Main shows all your boards" (then zooming out stops at Main, as below).

## Stepping through to your desktop

Your normal desktop sits behind your boards. A three-finger swipe down with
the pointer on bare background (a gap between windows, or wallpaper a pool
leaves showing, but not an empty pool) dives through that spot and lands on
your desktop. A three-finger swipe up on your desktop then takes you back out
through the same spot, to where you were. Turn it off under Motion & feel:
"Swipe down on the gaps between windows to step through to your desktop".

## Smooth rearranging

Every rearrangement plays over pictures: the windows glide to their new
places while the real ones move out of sight underneath. The pictures stay
until each real window has reached its spot (or stopped moving), so an app
that's slow to resize never shows half-done. A window that turns out not to
fit its spot glides away into its porthole, and portholes and app-icon tiles
fade in and out instead of popping.

## Zooming out stops at Main

Three-finger swipes, pinches and Hyper + ↓ stop at Main instead of dropping
you on your desktop: a swipe up gives a little and floats back. Hyper + Esc
(or "Back to desktop" in the menu) still takes you there. Hold Hyper and
swipe up with three fingers to go straight to your desktop from anywhere;
Hyper + a three-finger swipe down from your desktop lands on Main. Hyper +
scroll and Hyper + pinch also go on past Main to your desktop, and back in
to land on Main. Turn it off under
Motion & feel: "Zooming out stops at Main".

## Cut, copy and paste windows

- **Hyper + X cuts** the window you're using. Its pool carries on without
  it, and a chip at the bottom of the screen shows what you're holding.
  Go anywhere (another board, another Main), point at a pool and press
  **Hyper + V**: an empty pool takes it whole; in a pool that's in use it
  takes the half you're pointing at. Hyper + X on it again, or a click on
  the chip, puts it back where it was.
- **Hyper + C copies** it instead. Pasted, the same window is in both pools:
  live in one (the shallowest) and a porthole with a two-squares badge in
  the other. Click the porthole to go to that board, where it's live.
  Dragging a copy somewhere moves just that copy.
- One window at a time: cutting or copying another puts the first one back.

## Hiding windows and pools when you zoom out

Some things only belong at their own depth. **Hide** them and they get out of
the way when you zoom out: from the board above they're gone, and what's
beside them spreads into their space. Dive back down and they're right there.

- **Hyper + P** hides the window under the pointer. Again shows it.
- **Hyper + Shift + P** hides the whole pool under the pointer: a pool on the
  board you're on hides from the view above; one on a board inside it hides
  from this view.
- Each time, a small before-and-after map shows how the view from above
  changes (turn it off under ⊞ → Hiding windows & pools).
- Hyper + Z undoes it.

Under ⊞ → **Hiding windows & pools** you can also have hidden things show from
above as frosted portholes or app icons instead of disappearing. Click one to
go down to it; Hyper + P (or Hyper + Shift + P) over it shows it again.

## Saved pools (BETA)

Save a pool's whole setup and open it again later in any empty pool, on any
board: the pools inside it (if it holds a board), their sizes, which apps
live in each, where their windows sit, and what's hidden from above.

- **Hyper + Shift + S** saves the pool under the pointer (on the board you're
  on). To save a board of pools, zoom out one level and point at the pool
  that holds it. Give it a name.
- **Hyper + Shift + W** saves it and closes it: its windows close, and apps
  left with no windows anywhere quit. The pool goes away.
- **Hyper + Shift + O** over an empty pool picks a saved pool to open there.
  Its pools are rebuilt, each app opens, and its window takes the spot it
  had. Open a breathing room (Hyper + B), dive in and press it there, and the
  saved pools become that board's own. From there it's all normal pools
  until you close them.
- Apps that were closed are opened. Browser windows (Safari, Chrome, Brave,
  Edge) come back with their tabs; macOS asks once whether Scuba may control
  the browser. Other apps open a fresh window (Scuba can't reopen a
  particular document or chat inside them).
- Everything is also under ⊞ → Saved pools (BETA), including forgetting one.

## Breathing room in the corner you point at

Hyper + B opens breathing room in the corner of the screen nearest the
pointer. The other choices are still under Breathing room in the menu.

## Delete empty pools

Hyper + Shift + Delete (or "Delete empty pools here" in the menu) clears
every empty pool off the board you're on, and the pools left share the
space. Hyper + Z brings them back.

## New windows on nested boards

A window that opens over a board nested inside the one you're on (a tab
pulled out of Chrome, say) takes a proper spot in its pool, the whole pool
or the half it opened over, instead of floating over its neighbours. Its
size is checked out of sight first, so a window that won't shrink that far
is a porthole from the start.

## More than one display

Each extra display can be set under ⊞ → **Displays**:

- **Own boards** (the default): the display has its own Main, Home and
  nested boards, saved separately. Shortcuts, gestures, the menu and drags
  act on whichever screen the pointer is on, so you can be deep in a board on
  one screen and at the top level on the other. Dragging a window from one
  screen's board onto the other's moves it across.
- **Live map of where you are**: the display shows the board one level above
  where you are on the main screen (all your boards when you're at the top),
  with your spot lit up, and follows you as you dive and rise. Click a board,
  pool or window on it to go there. App windows you put on that screen sit
  on top of it.

  The map is also a place to arrange the main screen:
  - **Drag a gap** between two pools to resize them. The main screen follows
    as you drag.
  - **Drag a window tile** to move that window. Drop it in another pool to
    move it there, even onto another board.
  - **Drag a tile's edge or corner** to resize the window. Within its own
    pool, the real window follows as you drag.
  - A click without dragging still takes you there, and ⌃⌥⌘Z undoes an edit.
- **Left alone**: Scuba doesn't touch that display.

The main display (the one with the menu bar) always has its own boards.
Unplug a display and its windows come back to a screen you can see; plug it
back in and its boards return.

## Uninstall

Quit it from the ⊞ menu, delete the app and this folder, remove it from
Accessibility and Screen Recording in System Settings, and optionally delete
`~/Library/Application Support/Scuba`.

## Formerly Fractal Windows

Scuba used to be called Fractal Windows. The first time it runs on a Mac that
had Fractal Windows, it copies the boards and settings across. Fractal
Windows' own files are left alone, so delete them once you're happy. What
used to be called panels are now pools; only the name changed. Quit
Fractal Windows before opening Scuba, because the two would fight over your
windows. Permissions are asked for again under the new name.
