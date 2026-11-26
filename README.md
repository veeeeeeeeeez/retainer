# Retainer

A small native macOS app for capturing something you are reading together with
what you say about it.

Hold **Left Option**. While holding it, drag over part of the screen. The
screenshot lifts to the centre of the display and you talk about it. Let go of
Left Option: recording stops and your words appear as editable Markdown under
the image. Fix anything, press **⌘↩**, and a card with the screenshot, the
note and a link back to where it came from appears on today's board.

Every day has a board of its own: an endless surface you pan and zoom. A
timeline across the top of the window goes back through the days, and can
show a week, a month or everything at once.

The app was first called Terminal. Three things still carry that name, on
purpose, because macOS and your notes are tied to them: the bundle identifier
(`blog.terminal.app`, which every permission the app has been given hangs
on), the signing identity ("Terminal Local Signing", likewise), and the
notes' folder (`~/Library/Application Support/Terminal`). Renaming any of
them would mean granting the permissions again or moving the notes, so they
were left. Everything else is Retainer.

Everything runs on this Mac. The app goes to the network for two things only:
the one-time download of a speech model, and the page of a link you paste, to
take a picture of it for the card.

## Read this first

This version was written and checked on a Mac running **macOS 15.7.7 with no
Xcode installed**. That shaped what could be verified:

- The code compiles against the macOS 26.5 SDK with Swift 6.3 in Swift 6
  language mode, and 242 unit tests pass.
- The app launches, renders, downloads the Parakeet model and transcribes
  recorded speech correctly on that Mac.
- The **gesture has had one hands-on session** (macOS 15.7, a 3440 × 1440
  external display). It found two bugs, both fixed since: the app crashed when
  the Speech Recognition prompt was answered, and any drag longer than a
  quarter of a second was cancelled. The fixes are covered by tests but have
  not been re-tried by hand at the time of writing. Everything else about the
  event tap, screen capture, microphone and overlay is still as the author
  reasoned it, not as someone watched it.
- **Everything added after that session has only been seen in offscreen
  renders**, never used: boards by day with the timeline over them, the week,
  month and all-time boards, cards that open on a click, the archive, the
  marker for new notes, automatic placement, the light on the window's edges
  and the orb,
  the settings panel and light mode, pasting into the input box or
  dropping on the board, projects with their canvases, and groups. The logic under them is tested; the clicking is
  not. Two things
  cannot be judged from renders at all: the frosted glass under the timeline
  and the input box (a system blur that an offscreen render leaves out), and
  how smoothly a month's board pans. The one exception is the link back to
  the source, whose lookup was run for real against Chrome and several other
  apps.
- **SpeechAnalyzer and the tidy pass (Foundation Models) have never run.**
  They need macOS 26; they are compiled against the real SDK but untested.
- **`xcodebuild` has never been run on the generated project.** There was no
  Xcode. The project generates; the build used the script route below.

The full list, and what to try by hand first, is in
[What was and was not verified](#what-was-and-was-not-verified).

## Requirements

| | |
|---|---|
| Hardware | Apple Silicon |
| macOS, full feature set | 26 or later |
| macOS, minimum | 15.0, with Parakeet only: no SpeechAnalyzer, no tidy |
| To build | Xcode 26 or later, or the fallback toolchain described below |

The brief says "macOS 26+ only". The deployment target is set to 15.0 instead,
with the two macOS 26 features behind availability checks, because the Mac this
was built on runs 15.7 and would otherwise have been unable to launch it at
all. On macOS 26 and later nothing is different. To make the build strictly
26+, change `deploymentTarget` in `project.yml` and `platforms` in
`RetainerKit/Package.swift` to 26.0; the code compiles unchanged at that target
(checked).

## Build and run

There are two routes. Use one and stay with it: macOS ties privacy permissions
to how the app is signed, and the two routes can sign differently.

### Route A: scripts, no Xcode needed (this is the one that was run)

```sh
./scripts/setup-signing.sh     # once: creates the local signing identity
./scripts/build.sh             # builds and signs build/Retainer.app
open build/Retainer.app
```

`build.sh` builds the Swift package in release mode, assembles the app bundle
from `App/Info.plist` and `App/AppIcon.icns`, and signs it.

To build and launch in one step:

```sh
./scripts/run.sh               # add --no-build to relaunch the existing build
```

`run.sh` stays in the foreground while the app runs and prints the app's log
lines. Stopping it (Ctrl-C) quits the app, and quitting the app ends it. If a
copy of the app is already running it is replaced, so what starts is always
the build just made.

#### From Conductor

The Run button can call the same script. Conductor keeps this setting on each
Mac rather than in the repository; on the Mac this was built on it is already
set, in `.conductor/settings.local.toml` in the repository's root directory:

```toml
"$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

[scripts]
run_mode = "nonconcurrent"

[scripts.run.run]
available_in = [ "local" ]
command = "./scripts/run.sh"
default = true
icon = "play"
```

Run mode is nonconcurrent because only one copy of the app can run at a time:
there is one global event tap and one note store. Stop sends the script
SIGTERM, and the script quits the app.

It needs Swift 6.2 or later and a macOS 26 SDK. If Xcode 26+ is installed and
selected, that is used. If not (for example on macOS 15, where Software Update
offers neither Xcode 26 nor its Command Line Tools):

```sh
./scripts/fetch-toolchain.sh   # about 1 GB down, 5 GB on disk, nothing installed system-wide
```

This downloads Apple's own "Command Line Tools for Xcode 26" packages from
Apple's update server, verifies Apple's signature on each, and unpacks them
into `~/Library/Caches/terminal-build-toolchain/CLT26`. The build scripts pick
that folder up automatically when the system's SDK is older than 26. To use a
toolchain somewhere else, set `TERMINAL_TOOLCHAIN` to its path. Delete the
folder to remove it.

### Route B: XcodeGen and Xcode (not verified, see above)

```sh
brew install xcodegen
xcodegen generate
open Retainer.xcodeproj        # then Run
```

or from the command line:

```sh
xcodebuild -project Retainer.xcodeproj -scheme Retainer -configuration Release \
    -derivedDataPath build/xcode build
open build/xcode/Build/Products/Release/Retainer.app
```

`Retainer.xcodeproj` is generated and not checked in. Signing for this route
is set in `Config/Signing.xcconfig`; see [Signing](#signing) before the first
build.

### Tests

```sh
./scripts/test.sh
```

or Product > Test in Xcode. The tests use Swift Testing and need no
permissions, microphone or display.

## Signing

macOS remembers Accessibility, Screen Recording, Microphone and Speech
Recognition permissions per signing identity. An ad-hoc signature is different
on every build, so every rebuild would silently lose all four. Every build is
therefore signed with the same certificate.

**What you must set: for Route A, nothing beyond running
`./scripts/setup-signing.sh` once.** It creates a self-signed certificate named
"Terminal Local Signing" (the app's first name, kept) in a dedicated keychain at
`~/Library/Application Support/blog.terminal.signing/`. It needs no Apple
account, asks for no password, and does not touch the login keychain.
`build.sh` puts that keychain on the search list only for the moment it signs,
then restores the list.

If the identity does not exist, `build.sh` still produces a working app but
signs it ad-hoc and warns that permissions will not survive a rebuild.

**For Route B, choose one of:**

- *Your Apple Development certificate.* Create `Config/Local.xcconfig`
  (git-ignored) with:

  ```
  CODE_SIGN_STYLE = Automatic
  CODE_SIGN_IDENTITY = Apple Development
  DEVELOPMENT_TEAM = <your 10-character team id>
  ```

- *The local identity.* Run
  `./scripts/setup-signing.sh --add-to-search-list` so Xcode can see it. After
  a restart the keychain is locked again; run the same command to unlock it.
  Whether Xcode accepts a self-signed, untrusted certificate for manual
  signing is one of the unverified items.

Switching identity, or between routes with different identities, makes macOS
treat the app as a different one. Reset and grant again:

```sh
tccutil reset All blog.terminal.app
```

To remove the local identity: `./scripts/setup-signing.sh --remove`.

## Releases and the downloads page

Builds for other people to try are on a small downloads page,
<https://veeeeeeeeeez.github.io/retainer/>: one row for each release, as a
disk image and as a zip.

**Releases make themselves.** A push to `main` that changes the app (`App/`,
the sources in `RetainerKit/`, or the scripts that build and package it) runs
`.github/workflows/release.yml` on a macOS 26 runner. It builds and packages
the app, unpacks the zip again and starts the app from it, publishes the two
files as a GitHub release called "Retainer <version> (<build>)", and
redeploys the page with the new release on top. `<version>` is
`CFBundleShortVersionString` in `App/Info.plist`; `<build>` is the number of
the workflow run, also written into the app as its `CFBundleVersion`. A push
to any other branch releases nothing, and neither does one that changes only
the tests, this README or the page. A push that changes `website/` redeploys
the page without a release. To make a release by hand: Actions ▸ Release ▸
Run workflow.

**To package the copy you are working on:**

```sh
./scripts/package.sh    # builds; writes website/downloads/Retainer-<version>-local.dmg and .zip
./scripts/site.sh       # the page on http://localhost:3000, with that package above the releases
```

`site.sh` can sit beside Run in Conductor, as a second action in the same
`.conductor/settings.local.toml`:

```toml
[scripts.run.site]
available_in = [ "local" ]
command = "./scripts/site.sh"
icon = "globe"
```

**What whoever downloads it will meet.** There is no Apple Developer account
behind this app, so nothing here is notarised:

- *The first time it is opened, macOS refuses* ("Apple could not verify…").
  System Settings ▸ Privacy & Security ▸ Open Anyway lets it through, once.
  The page's last line says so.
- *Releases built on GitHub are signed ad hoc*, there being no certificate
  there to sign with. To macOS each release is therefore a different app:
  after replacing one with the next, the four permissions have to be given
  again (if System Settings still shows them as on, `tccutil reset All
  blog.terminal.app` clears the old ones first). For the same reason a
  downloaded release and a build made on your own Mac do not share
  permissions. A package made with `package.sh` is signed with the local
  identity, like any other build made here.
- Apple silicon only, macOS 15 or later: see [Requirements](#requirements).

## Permissions

On launch the window shows a checklist of four permissions, each with live
status and a button. Capture stays off, and the status bar says why, until all
four are granted.

| Permission | Used for | Notes |
|---|---|---|
| Microphone | Recording while Left Option is held | System prompt on first request |
| Speech Recognition | On-device transcription | System prompt on first request |
| Screen Recording | Capturing the rectangle you drag over | **Takes effect after a relaunch**; the checklist has a relaunch button |
| Accessibility | The global event tap that watches for Left Option and the drag | Takes effect immediately |

The first press of a button shows the system prompt (which also adds the app
to the list in System Settings); after that the button opens the right pane.
If Accessibility is granted and the tap still cannot be installed, the
checklist says so and offers the Input Monitoring pane.

Two things to know:

- **The app used to be called Terminal**, like Apple's, and System Settings
  may go on listing it under that name for a while (it has the dark icon
  with a square pane of clear glass in it; Apple's has the `>_` prompt). It
  is the same app to macOS, with the same identifier, so permissions granted
  under the old name still hold.
- macOS periodically re-asks whether an app may keep recording the screen.
  That prompt is the system's and cannot be suppressed.

## Using it

**Capture**

1. Hold Left Option, alone.
2. Press the mouse and drag. Past 4 points the screen dims lightly outside the
   rectangle, and the rectangle becomes a pane of clear glass: a bright
   hairline round the edge, a soft shadow under it, nothing changed in the
   middle. Its size is shown beneath it. The selection stays up for as long
   as the mouse is held, however slowly you drag. A small pill with a live
   waveform sits at the bottom centre. Recording has started.
3. Release the mouse. The rectangle is captured at full resolution and moves
   to the centre over a dimmed backdrop, still under its glass, with "What do
   you think about this?" and the pill beneath it. Keep holding and talk.
   Pauses are fine: nothing stops on silence. Your words appear under the
   pill as you speak.
4. Release Left Option. The pill reads "transcribing" and is replaced by an
   editor holding your note with the cursor at the end. The editor is the
   same pane of frosted glass as the input box in the main window, here
   frosting the screen behind it: the note, and under it the two keys and
   the save button (and, with a canvas in front, where the card is going).
   It says nothing about the speech engine or the tidy pass. Beside the save
   button is a **microphone**: click it to say more. What you say is written
   after what the note already says, as you say it; click the square (the
   same button) to stop, and the words stay, tidied if tidy is on. Escape
   while it is listening takes back what was just said and leaves the note;
   ⌘↩ while it is listening keeps it and saves.
5. Edit, then **⌘↩** or the save button. The card closes, focus returns to
   the app you were in, and the note appears on today's board, whichever
   board the window happens to be showing.

**Cancelling.** Releasing Left Option before the mouse cancels. Escape cancels
during the drag, while speaking, and while the transcript is processing. In
the editor, Escape discards at once if you have not changed the text; if you
have, it asks first ("esc again to discard, any other key keeps editing").

**Boards by day.** Nothing is filed anywhere. A note belongs to the day it
was saved on, and each day has its own board. The window opens on **Today**.
While today's board is empty it says what to do, with three small tiles in
the sentence in place of more words: the Option key, a crop for the capture
and a waveform for the voice. They light up one after another, in the order
the gesture goes, to catch the eye (and hold still if the Mac is set to
reduce motion).

**The bar at the top** is a small switch, `timeline | projects`, over a strip
of frosted glass floating in the middle of the board's top edge. The switch
says what the strip's tiles are (View ▸ Show Timeline, ⌘5; Show Projects,
⌘6).

**The timeline.** In timeline mode the strip has a tile for every day that has notes, oldest
on the left, Today on the right. A tile is a little collage of that day's
newest screenshots; its tooltip says how many notes it holds, and a dot marks
a day with notes you have not looked at. Click a tile to open that day's
board. The strip is as wide as its tiles, so it grows by one each new day you
save something, up to seven; after that it stays that width, and earlier
days are reached by scrolling it with two fingers or with the arrows that
appear at its ends. View ▸ Earlier (⌘[), Later (⌘]) and Today (⌘T) step along
it from the keyboard.

**Day, week, month, all.** The small switch under the timeline (View ▸ Day,
Week, Month, All Time; ⌘1 to ⌘4) changes how much time one board covers, and
the timeline's tiles change with it: a tile per week, per month, or one for
everything. A week's board is that week's days brought together on one
surface. Each day keeps its own arrangement and is set down as a block in a
place of its own, in date order, under a header with its date; click a
header to open that day. A month and all time work the same way, zoomed
further out. Zoomed out far enough that the words could not be read, a card
is drawn as its screenshot alone. A wider board is fitted to the window the
first time you open it and then stays as you leave it. Cards can be dragged
about on a day's board; on the wider ones they stay put, and dragging one
pans.

**Projects and canvases.** Days are one way of keeping cards together;
projects are another, for things that belong together whenever they were
saved. In projects mode the strip's tiles are your projects, with a dashed
`+` tile at the end to make one (View ▸ New Project, ⇧⌘N). Click a project
and the same strip shows its **canvases**: boards you make and name, with
another `+` (New Canvas, ⌘N) and the project's name at the left as the way
back to the list (a long name wraps there, to three rows, before it is cut
short). A new project comes with a first canvas, already open,
and its name ready to be typed; Return keeps a name, Escape leaves the old
one. Right-click a tile to rename or delete it; delete turns the tile to
"delete?" and takes a second click.

- **A card on a canvas is still on its day.** A canvas is a second
  arrangement of the same notes. Right-click any card and choose Add to
  Canvas; it appears on that canvas with a position of its own there, and
  stays exactly where it was on its day's board. Dragging it on one does not
  move it on the other. Remove from Canvas takes it off that canvas only.
  Deleting the note removes it everywhere; archiving it hides it on its
  canvases until it is restored, when it is back in the same place.
- **Captures land on the canvas in front.** While a canvas is on screen, a
  capture, a paste or a dropped picture goes onto it (where it was dropped,
  or in the middle of the window) as well as onto today's board, and the
  editor says so under the note ("to Thesis / Outline"). With the list of
  projects showing and a day still in front, it goes to today as usual: it
  is the board in front that decides, not the strip.
- **Moving about.** Each canvas remembers its own pan and zoom. Switching to
  the timeline brings back the day you were on; switching back to projects
  brings back the canvas. ⌘1 to ⌘4 and Today (⌘T) from a canvas go back to
  the timeline. "N new" and Next New Note (⌘J) look on the canvas in front
  first. Deleting the canvas in front shows its neighbour, or the day when it
  was the last. Deleting a project deletes its canvases; the notes are
  untouched. A canvas has no archive of its own.
- The window always opens on Today, in timeline mode.

**Groups.** Cards on a day's board or on a canvas can be put together as one
tile. Drag a card until its middle is over another card: both go grey and a
"Group" sign appears over them; let go and the two become a group in the
second card's place. Drag a card over a group the same way ("Add to group")
to put it in. Let go anywhere else and the card just moves, as before. A
new group asks for its name straight away, on its tile: type it and press
Return, or Escape to leave it unnamed.

- **The tile** is a little larger than a card and has no captions: it is
  made of the pictures of everything in the group, set out in rows that fill
  it, each picture kept close to its own shape (the first nine, with "+N" on
  the last when there are more). A card of words has no picture, so it is a
  small square chip marked "Aa", in a row under the pictures (or in the
  middle of the tile, in a group of nothing but words). Under them is the
  group's name and how many cards it holds. Drag it to move it.
- **Click a group** to open it: every card in it, each of which can be
  opened as usual, and the name at the top, which can be typed and changed
  there. **Edit** turns the cards into a selection: click the ones to take
  out, then "remove from group". Ungroup, there or from the tile's
  right-click menu, ends the group and sets its cards down round where the
  tile was. A group left with one card ends by itself and the card takes
  its place.
- A group belongs to the board it was made on. On a canvas, the same cards
  are still separate on their days; a group made on a day's board shows on
  the week, month and all-time boards too, where it can be opened but not
  dragged. Nothing about the notes themselves changes, and an archived card
  is hidden from its group until it is restored.

**Finding the cards again.** A board has no edges, so it is possible to
scroll away from everything and lose it. Something always shows which way the
cards are, and Settings ▸ Mini map chooses what:

- **Edges** (the default) has no map at all. The window is the map, and its
  own edges light up. A card that is out of view lights the edge it lies
  beyond, at the place along that edge where it is and in its own colour: a
  card above the window lights the top edge over where the card is, and one
  off to the left lights the left edge level with it. A card beyond a corner
  lights the two edges that meet there, close to the corner, each by as much
  as the card lies that way, so one far above and only just to the left is a
  light on the top. **An edge with nothing beyond it is dark, and a card any
  part of which can be seen gives no light**: light on an edge always means
  there is something to scroll to that way. The light is a quiet band about
  fifty points deep, brightest at the very edge and fading inwards, with no
  line. It comes up as a card goes out of sight rather than all at once, and
  fades the further off the card is without ever going out. Along the edge it
  is as wide as the card and a quarter as much again either side, and stops
  there: several cards in one place are a brighter light, never a wider one.
  In light mode there is nothing to glow against, so the light is a stain of
  the same colours instead, laid on about twice as heavily as the glow so
  that it shows as well.
- **The orb** is a small ball of frosted glass in the top right-hand corner,
  centred on where you are: the
  frame is always in its middle, and the cards are drawn round it where they
  lie. At rest it is plain dark glass with no highlight of its own, so that
  any light on it means cards. It zooms out to take in every card of the board, but only so far: to
  four times the distance from the middle of the window to its corner. A card
  beyond that is not drawn. It lights the rim of the glass instead, on the
  side it lies, in its own colour, so the edge of the orb says which way the
  cards are and roughly what they are. Cards that lie the same way add up to
  a brighter light. A card close to the range gives a wide, strong light and
  one a long way off a narrower, fainter one, but never none. A card's colour
  is the hue there is most of in its screenshot (the colour of the chart, not
  the white of the page round it). Seen from far enough away a whole cluster
  lies in one direction, and its colours laid over one another would come to
  white, so they are fanned out along the rim by hue instead, red at one end
  and violet at the other, centred on the way the cluster lies. A card on its
  own is not moved, and cards of one hue stay together. As the board is
  scrolled, cards melt into the edge of the glass as they leave the range
  and their light comes up as they go.

On the orb each card is a few blocks of its screenshot's colours, enough to
tell a cluster from empty space and one cluster from another, and the frame
is what you are looking at. Click it, or drag on it, to move the window to
that spot. The light on the window's edges is only light: it shows the way
and is not clicked. (There was a third kind, an overview of the whole board
with an arrow to the nearest card; it has been taken out. A setting saved as
"overview" is read as the edges.)

**With nothing in view at all**, the middle of the board says so, whichever
is chosen: "Stuff's over there.", in the same quiet type as the
prompt on an empty board, with a thin chevron beside it on the side the cards
are, pointing that way. Cards that lie the same way get one chevron, towards
the middle of them and leaning to the nearer ones; cards with a gap between
them (some off to the left, some below) get one each, three at the most. It
appears only when every card is wholly out of view: one sliver of one card
showing and it is gone. It fades in a moment after the last card leaves, so
that scrolling across a gap between cards does not flash it, and fades out
quickly when a card comes back. The chevrons come and go as the keys in the
empty board's prompt do, at the same pace and to the same dimness: with
several, each is lit in its turn; one on its own comes up and fades back.
They hold still when the Mac is set to reduce motion. Under the words is a
small underlined link, **recenter**, which brings the cards back.

**Recenter** puts the cards of the board in front back in the window from
wherever it has been scrolled or zoomed to: all of them between the timeline
and the input box, at 100% if they fit at that and smaller if not (a board of
several days is fitted as it is when first opened; an empty board goes back
to its own middle at 100%). It is the link under "Stuff's over there.", the
small round-arrow button to the right of the zoom in the status bar, and
View ▸ Recenter (⌘9).

**Sample days.** So that there is something to look at while this way of
arranging things is being tried, the timeline is filled with about sixty
made-up past days. They are generated, not stored: nothing is written among
your notes, anything done to them is forgotten at the next launch, and
Settings ▸ Sample days switches them off. Today never gets any.

**Pasting and dropping.** A note does not have to start as a screenshot.

- **Paste a link or a picture** into the box at the bottom of the board (⌘V
  there, or anywhere in the window while no note is being written). It waits
  in the box as a small picture, with a cross to take it out again; backspace
  in the empty box takes out the last one. Several can wait at once. A copied
  picture file works the same as a copied picture. A link can also be typed.
- **Press Return.** What was waiting comes up in the middle of the screen
  exactly as a screenshot does after the drag, with "What do you think about
  this?" and the pill under it, and the microphone is on. Nothing is being
  held this time, so **Return again** (or a click on the pill) says you have
  finished talking; then it is the same transcribing, tidying and editor, and
  ⌘↩ puts the card on today's board. Escape drops it. With several waiting,
  each takes its turn.
- **Drop a picture on the board** and it goes straight to the middle of the
  screen and the microphone, without waiting in the box. Its card is put
  where it was dropped, or as near as there is room. A picture dropped on the
  box itself waits there like a pasted one.

A link's card is a picture of the page it leads to. Once the link is saved
the app loads the page, out of sight, and takes a picture of the top of it;
the picture is softened and dimmed a little and given a link sign in its top
left corner, so that it reads as a link and not as a screenshot of yours.
**Click the picture to open the link** in the browser; the link is also the
card's source, under the picture. Until the page's picture arrives, and for a
page that does not load within 18 seconds, the card is drawn from the address
alone, in words and nothing else: the site's name, and under it the rest of
the address. That
is also what waits in the box and what is on screen while you talk about the
link; only the saved card gets the page. Loading the page is the one thing
the app fetches besides the speech model. It happens only for a link you
paste or type, asks for that page and what the page itself loads, and uses a
private web view that keeps no cookies or history and is thrown away
afterwards. A pasted or dropped picture file has its path there, and a
picture copied out of a web page the address it was copied with. Pictures
larger than 4,096 pixels on their longest side are brought down to that. The
Option-drag gesture is switched off while something pasted or dropped is on
screen. If the speech model is not ready, the card goes straight to the
editor to be typed about.

**Writing, dictating and attaching in the box.** The box at the bottom is
also the quickest way to make a note without capturing anything.

- **Write** in it and press Return: the words are saved as a note on the
  board in front (today's, or the canvas you are on). A note made of words
  alone has a card of words alone: no picture, and room for more lines.
- **Dictate** with the microphone button: the same pill a capture shows
  appears over the box, what you say is written into the box as you say it,
  and clicking the button again stops and leaves the tidied text there to
  edit or send. It adds to what was already in the box.
- **Attach** with the paperclip: choose any files. A picture goes in as
  itself; anything else by its preview (the first page of a PDF, say). The
  file's path is kept as the card's source, so the line under the picture
  opens the file or shows it in the Finder.
- **Return with words** saves them as the note of everything waiting in the
  box, one card each, with no talking step. **Return with no words** shows
  what is waiting in the middle of the screen to be spoken about, as before.

**Boards.** Scroll to pan, pinch or ⌘-scroll to zoom (10% to 200%; ⌘0, ⌘+
and ⌘− also work), drag the background to pan, drag a card to move it. Each
board remembers its own pan and zoom. ⌘9 (View ▸ Recenter) brings the cards
back into view.

**Cards.** On a board a card is kept small: the screenshot, the first
three lines of the note, where it came from and the time. Only the time: the
day is the board's own, and the full date is on the card once it is opened. If the capture has a
link back to its source, it sits directly under the screenshot as one quiet
line (**↗** and the address, or a document mark and the path); click it to go
there. Pointing at a card dims its screenshot a touch and brightens that line.

**Click a card to open it.** The opened card shows the screenshot as large as
fits, the link under it, the whole note, the source, and a row of everything
that can be done:

- *edit*: or just click the note, and type, in Markdown. Changes save as you
  type; click "done", press Escape or click away to finish.
- *archive*: the card leaves its board but nothing is lost. "N archived" in
  the status bar (View ▸ Show Archive, ⇧⌘A) shows the archive of the day,
  week or month in front, where the same button reads "restore". A restored
  card goes back where it was on its day's board, or beside whatever has
  taken that place since.
- *delete*: asks for a second click, then removes the note and moves its image
  to the Trash. There is no undo; archive is the reversible one.
- *full size*: the screenshot alone, filling the window.
- *open page* or *open file*, *copy link* or *copy path*, and for a file
  *show in finder*, when the capture has a link.

Escape, "close" or a click outside puts the card away. All of these are also
in a card's right-click menu on the board, without opening it.

**Where new cards go.** Always on today's board. With Today on screen, a new
card is put in the middle of what the window is showing if that is clear. If
not, it goes in the nearest clear place beside the cards already there, lined
up with one of them and one grid step away, preferring somewhere you can see
without scrolling; if the only room is out of view, the board scrolls just
far enough to show it. With another board on screen, it goes beside what is
already on today's.

**New notes.** A note saved while you were not looking at its board is marked
**● new** on its card, with a brighter edge, until the card has been in view
in the active window for a second or so (opening or dragging it also
counts). The status bar counts them all ("● 2 new"); click that, or View ▸
Next New Note (⌘J), to be taken to each in turn, on the board of the day it
was saved. The timeline marks the days that have some, and the Dock icon
carries the total.

**Where it came from.** If the app you captured from can say what its window
was showing, the capture keeps a link to it: the page's address for a browser
(a YouTube video links to the video, an article to the article), the file's
path for a document window. It is the small line under the screenshot, on
the card and in the opened card alike; a click opens the page or the file.
See [Source links](#source-links) for which apps this works with.

**Settings.** The gear at the bottom left of the window (Retainer ▸ Settings…,
⌘,) opens a panel with five things: **Light mode**, tidy on or off, sample
days on or off, how the board shows where its cards are (the window's edges
or the orb), and the speech
engine. Light mode switches the window to the light version of the palette. The capture overlay stays dark in both: it is laid over whatever is
on your screen, and a bright one would be a flash of white every time.

**Status bar.** Along the bottom: the gear, which board is in front ("Today",
"Monday 16 November", "This week"), how many notes it has, how many are new,
how many archived, and the zoom, with a round-arrow button after it that
recenters the board on its cards. The
right-hand end speaks only when capture is off, to say why (a permission is
missing, the speech model is still downloading). When capture is ready it is
empty.

**Menu bar.** Open the window, see whether capture is on and each
permission's status (clicking one requests it or opens its pane), open the
settings, quit. Closing
the window does not quit the app; capture keeps working from the menu bar.

**The speech engine and the tidy pass are named in one place only: the
settings.** They are chosen there, and their state is shown there. Not on
cards, not in the capture editor, not in the menus. A note still records
which engine heard it and what the tidy pass did (`engine`, `tidyOutcome` in
the index); nothing shows them.

The same entries are also in the **Capture** menu of the app's own menu bar.
That is deliberate: when the menu bar is full, macOS hides the newest items
behind the display notch, and on the Mac this was built on the item did land
there. If you cannot see it, use the Capture menu, or make room in the menu bar.

### How Left Option is treated

The app must never get in the way of ordinary uses of Option. The rules, all
covered by tests in `GestureRecognizerTests`:

- Only Left Option (key code 58) arms the gesture, and only when it goes down
  with no other modifier held. Right Option never does.
- Any key pressed while Option is held (a shortcut, an Option character such
  as `é` or `π`) passes through and disarms the gesture until Option is
  released. So does adding another modifier.
- A mouse press while armed is **held back, not consumed**. If the pointer
  travels more than 4 points it becomes a selection and the app underneath
  never sees it. If the button comes up first, the press and release are
  delivered exactly as they were and the app underneath gets a normal
  Option-click.
- While a capture card is open, a new Option-drag is ignored and passes through.

Two consequences worth knowing:

- An Option-click reaches the app underneath when you *release* the mouse, not
  when you press it. This is the price of not letting the app underneath react
  to a press that turns out to be a selection.
- **Option-drag in other apps is taken over** while this app is running: copy
  by Option-drag in Finder, duplicate in design tools, column selection in
  editors. That is inherent in the gesture. Use Right Option for those.

If the event tap ever misses the release of Option (macOS disables taps during
secure text entry, for instance), mouse events are cross-checked against the
modifier flags they carry, and a watchdog checks the Option key itself four
times a second during a capture. A lost event cannot leave the overlay up or
the microphone on. The watchdog looks only at the key, never at the mouse
button: the button's state cannot be read back while its events are being
swallowed, and an earlier version that tried cancelled every slow drag.

## Source links

When a capture begins, the app asks the app in front what its front window is
showing, through the Accessibility API it already has permission for. Nothing
is fetched and nothing is sent anywhere; the link is stored with the note and
only opened when you click it.

- **Browsers** (any app the system would open a web link with): the address
  of the page in the front tab. Chrome and Safari report it as the window's
  document; for other browsers the app looks for the page inside the window.
- **Document windows** (Preview, TextEdit, Pages, Xcode and so on): the file
  the window has open, shown as its path.
- **Everything else**: no link. Many apps are built from web pages and report
  an internal address that leads nowhere (Spotify and Slack both do), so a web
  address is believed only when it comes from a browser. A file that is part
  of an app is ignored for the same reason.

The lookup runs to one side of the capture and gives up after 0.4 seconds, so
an app that is slow to answer costs nothing but the link. Like the source app
and window title, it describes the app in front, which is not necessarily the
window you dragged over. The Finder offers nothing to read this way, so a file
selected there gets no link. `--source-link` (below) shows what a given app
would give.

## Transcription

Two on-device engines sit behind one protocol (`TranscriptionEngine`). Switch
between them in the settings; the choice persists. Each note records which
engine produced it.

**Parakeet TDT v2** (default), through
[FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.3. English.
The Core ML model, about 450 MB, is downloaded from Hugging Face on first
launch into `~/Library/Application Support/FluidAudio/Models/`. Progress shows
in the status bar, the checklist and the menu; capture is off until it is
ready. After that the only thing the app asks the network for is the page of
a link you paste, to picture it on the card. Parakeet is a batch
model: the final transcript is one pass over the whole recording, made when
you release Option (0.11 s for a 17-second recording on an M4 Pro). The words
shown while you speak come from re-decoding the most recent 15 seconds about
once a second.

**Apple SpeechAnalyzer** with `SpeechTranscriber`. macOS 26 or later. The
language model for your locale is installed by the system through
`AssetInventory` if it is not already there. Interim words are its volatile
results. On macOS 15 it appears in the menu as unavailable.

Parakeet transcribes fillers faithfully: "um" and "uh" appear in its output.
Removing them is the tidy pass's job.

## Tidy

On by default; toggle in the settings. After transcription, one pass with
Apple's on-device Foundation Models framework (macOS 26, Apple Intelligence
switched on). No cloud model is involved under any circumstances.

The model is instructed to do only this: remove filler words and false starts,
fix punctuation and capitalisation, add paragraph breaks, and format a spoken
list as a simple Markdown list. It is told not to change word choices,
summarise, shorten, add anything, add headings, or answer questions in the
transcript. The instruction is in `Tidy/Tidier.swift`.

The model's output is not trusted. `TidyGuard` checks it, and the **raw
transcript is used instead** when:

- the model is unavailable (macOS 15, Apple Intelligence off, model still
  downloading);
- it takes longer than 3 seconds (a hard limit: the result is abandoned even
  if the model ignores cancellation);
- the result is markedly shorter than the input minus fillers, or longer than
  the input;
- more than a few of its words were never in the transcript (a rewrite, or an
  answer to a question you asked aloud);
- it added a heading, or returned an error.

The editor's footer says what happened, for example
`parakeet-tdt-v2 · tidied` or `… · tidy timed out, raw transcript`. The raw
transcript is always stored with the note. With tidy off, the saved note is
the raw transcript unless you edit it.

One limit to expect: at the model's speed, 3 seconds is enough for a few
sentences. Longer notes will usually time out and arrive untidied.

## Storage

Local only. No accounts, no sync.

```
~/Library/Application Support/Terminal/
    index.json
    images/<note id>.png
```

`index.json` is a single file, rewritten atomically:

```json
{
  "version": 4,
  "projects": [{ "id": "…", "name": "Thesis", "createdAt": "2026-11-19T10:00:00Z" }],
  "canvases": [
    {
      "id": "…",
      "projectID": "…",
      "name": "Outline",
      "createdAt": "2026-11-19T10:00:05Z",
      "cards": [{ "noteID": "…", "position": { "x": 120, "y": -80 } }]
    }
  ],
  "groups": [
    {
      "id": "…",
      "name": "Pricing pages",
      "board": "day:2026-11-19",
      "noteIDs": ["…", "…"],
      "position": { "x": 600, "y": 40 },
      "createdAt": "2026-11-19T12:00:00Z"
    }
  ],
  "notes": [
    {
      "id": "…",
      "imagePath": "images/….png",
      "imagePixelSize": { "width": 1520, "height": 720 },
      "imageScale": 2,
      "note": "The note as saved and since edited.",
      "rawTranscript": "what the engine heard, before tidy and edits",
      "engine": "parakeet-tdt-v2",
      "tidy": true,
      "tidyOutcome": "applied",
      "timestamp": "2026-11-18T19:21:02Z",
      "sourceApp": "Safari",
      "windowTitle": "An article",
      "sourceURL": "https://example.org/an-article",
      "position": { "x": -200, "y": -310 },
      "seen": true,
      "archivedAt": "2026-11-19T09:30:00Z"
    }
  ]
}
```

`engine` is `parakeet-tdt-v2`, `apple-speechanalyzer`, or `none` for a note
typed without a microphone. `tidy` is whether tidy was switched on;
`tidyOutcome` is what it did (`off`, `applied`, `empty`, `unavailable`,
`timed-out`, `rejected`, `failed`). `sourceURL` is the link back to the
source and is absent when there was none. `seen` is false until the card has
been looked at. `archivedAt` is present only while the note is archived.
A note's own `position` is its place on its day's board; each canvas keeps a
separate position for every note on it, in `cards`. Files of versions 1 to 3
are read and rewritten as version 4, with no projects. (Version 2 had keys
called `projects` and `canvases` in a different shape, from the left bar that
did not last; they are ignored, not read as these.) A group's `board` is
the day's board (`day:` and the date) or the canvas (`canvas:` and its id)
it was made on.
`timestamp` is when the note was saved, and so which day's board it is on:
there is nothing else that files a note anywhere. `position` is where its
card sits on that day's board (or, while archived, in that day's archive).
`imagePixelSize` and `imageScale` let a card be laid out before its image
has loaded. `tidyOutcome` records what the tidy pass did; nothing shows it.

Earlier shapes of the index are read as they are and rewritten in this one:
version 1 (notes only) and version 2 (which for a short while filed notes
into projects and canvases; those two lists are ignored). Notes that would
now sit on top of one another on a day's board, because they were on
different canvases or because the first builds stepped each new card a
little off the last, are moved apart once, when the older file is read.

If `index.json` cannot be parsed it is renamed to `index.unreadable-<date>.json`
rather than overwritten. Deleting a note moves its PNG to the Trash. The app
treats SIGTERM and SIGINT as an ordinary quit, so `kill` and `run.sh` do not
skip the final write of the index.

The engine choice, the tidy, light-mode and sample-days switches, each
board's pan and zoom, and the window frame are in the `blog.terminal.app`
defaults domain. The sample days' pictures are in
`~/Library/Caches/blog.terminal.app/sample-days-1/`.

## Configuration

The trigger key and every threshold are in one file,
`RetainerKit/Sources/RetainerKit/Config/CaptureConfig.swift`: trigger key code
and modifier bit, drag threshold (4 pt), minimum selection (20 × 20 pt), lift
duration (0.3 s), the fraction of the display the lifted capture may fill
(60%), the tidy timeout (3 s) and the tidy length and fidelity limits.

Colours, type and spacing are in `Design/Theme.swift`. Every colour there has
a dark and a light value, written side by side; the dark ones are a warm
near-black palette (background `151110`, panels `1B1917`, text `EAE8E6`,
accent `DDC1B1`) and the light ones are the same hues turned over. Type is
the Mac's own system face, SF Pro, and nothing else: notes, labels, buttons,
metadata and status are all set in it. The gap kept between
cards is `CanvasLayout.gap`, the room between days on a wider board is
`ClusterLayout.gap`, and how long a card must be in view to count as seen is
`CanvasModel.seenAfter`. The glass under the timeline, the mini map and the
input box is `GlassStyle.floating` in `Design/FloatingGlass.swift`; the map's
size is `MiniMap.diameter` and its distance from the right-hand edge of the
window `MiniMap.edgeSpace`. How far the orb sees is `OrbGeometry.sight`, and
the width, strength and fan of the light on its rim are the constants at the
top of `RimLight`, both in `Canvas/RimLight.swift`. The light on the window's
edges is `Canvas/EdgeGlow.swift`: how deep the band is (`depth`), how bright
it can get (`ceiling`) and how wide a card's light is along the edge
(`spread`) are at the top and in `light(cards:viewport:samples:)`.

The selection glass is a short list of numbers in `GlassStyle`, at the top of
`Overlay/GlassPanel.swift`. Six are named after the sliders of the
[LiquidGlass playground](https://liquid-glass.ybouane.com) they were chosen
on: corner radius, edge highlight, opacity, Z-radius, shadow opacity and
shadow spread. Two more set how deep the glow may reach and how strongly it
is laid on. Change them there, then look at the result with `--glass` (below)
before running the app.

## Layout

```
project.yml                 XcodeGen spec for the app target
App/                        entry point, Info.plist and icon for the app bundle
Config/Signing.xcconfig     signing for the Xcode build
scripts/                    build, test, signing, toolchain and packaging scripts
website/                    the downloads page and the script that renders it
.github/workflows/          the release and the page's deployment
RetainerKit/                Swift package holding all app code and the tests
  Sources/RetainerKit/
    Config/                 CaptureConfig
    Input/                  GestureRecognizer (pure state machine), EventTap
    Capture/                ScreenCaptureKit capture, source app, window and link
    Audio/                  microphone to 16 kHz mono
    Transcription/          engine protocol, Parakeet, SpeechAnalyzer, manager
    Tidy/                   Foundation Models pass and its guard
    Session/                CaptureCoordinator: the whole gesture, end to end
    Overlay/                selection overlay, capture card, pill, editor
    Canvas/                 boards, periods and the timeline's tiles, cards, finding room, the mini map, Markdown
    Store/                  notes, JSON index, PNG files, sample days
    Permissions/            status and requests
    App/                    app delegate, window, timeline, settings, menu bar item
    Dev/                    developer switches (below)
  Tests/RetainerKitTests/
```

All code is in a package so it can be built and tested with `swift build` and
`swift test`; the Xcode target is a two-line entry point that links it. The
package also carries the FluidAudio dependency, pinned to an exact version and
built with `traits: []` (speech recognition only, no text-to-speech or
diarisation). If Xcode's package resolution objects to the traits argument,
delete it from `RetainerKit/Package.swift`; the only cost is a longer build.

## Developer switches

Run the binary inside the bundle with one of these. None of them installs the
event tap or asks for a permission.

```sh
BIN=build/Retainer.app/Contents/MacOS/Retainer

$BIN --snapshot <directory>          # render every screen to PNG with sample content
     [--scale 1|2]                   #   at 1 or 2 pixels per point (default 2)
$BIN --maps <directory>              # render the mini map alone, large, in each of its states
     [--scale 1|2|3|4]               #   pixels per point (default 3)
$BIN --edges <directory>             # render a wide window with the cards out of view each way
     [--scale 1|2]                   #   pixels per point (default 1)
$BIN --motion <directory>            # measure what moves by itself, moment by moment
$BIN --transcribe <audio file>       # run an engine over a recording, print the transcript
     [--engine parakeet-tdt-v2|apple-speechanalyzer] [--realtime]
$BIN --tidy "<text>"                 # run the tidy pass and its guard on some text
$BIN --glass <picture> <output.png>  # draw the selection glass over any picture
     [--rect x,y,width,height]       #   where (default: the middle half)
     [--scale 1|2]                   #   at 1 or 2 pixels per point (default 2)
$BIN --source-link <bundle id>       # the link a capture of that app's front window would get
```

`--transcribe --realtime` feeds the file at speaking pace and prints the
interim results as they arrive. `--tidy` is the quickest way to see how the
on-device model behaves on macOS 26 without making a capture. `--glass` shows
the selection glass over a picture of your choosing, one point per pixel of
the picture: a screenshot of a dark app, a white page and a photograph cover
the cases that differ. `--source-link com.apple.Safari` (or any running app's
bundle identifier) prints whether the app counts as a browser, the link found
and how long it took; it needs Accessibility to be granted to whatever runs it.
`--maps` draws the mini map on its own: the orb with everything
in view, with cards at its edge, far from them one way and the other, in the
middle and at the corner of a month, and in light mode. `--edges` draws the
whole window, 1,720 points wide, with the cards above it, only just above it,
beyond a corner, off to each side, below, and all round in the middle of a
month: the pictures to look at when changing the light on the window's edges,
where what matters is which edges stay dark, and the words and chevron in
the middle that go with it when no card is in view.

`--motion` is for what a still cannot show. It keeps the "Stuff's over there."
words in one hidden window, changes which way the cards are as the board
would, and looks again every few hundredths of a second, printing how bright
the words, the link and each chevron are at each moment (0 is the board, 1 is
white). Read down a column to see the fade in, a chevron coming up and going
down, three taking turns, and a chevron being in its new place at once when
the direction changes. It also saves a few of the moments as pictures.

Run `--snapshot`, `--maps`, `--edges` and `--motion` with the Mac awake and
unlocked. They draw in
windows that are never shown, and with the screen locked macOS draws those
very slowly: a `--snapshot` that takes a minute can take half an hour, and a
screen can be caught before its screenshots have loaded.

## What was and was not verified

### Verified

| What | How |
|---|---|
| Compiles in Swift 6 mode against the macOS 26.5 SDK, at deployment targets 15.0 and 26.0, with no warnings | `scripts/build.sh` with Swift 6.3.3 |
| The pass-through rules: Option-click, Option with keys, Option with other modifiers, Right Option, hold without drag; lost key events; long drags | 44 tests on the gesture state machine |
| Handlers the system calls on background threads (permission prompts, menu bar icon drawing) do not trap | 2 tests that call them off the main thread |
| The capture flow from drag to saved note; Escape in every phase; discard confirmation; tidy on, off, unavailable and rejected; no microphone; early release; failed screenshot; saving to today's board whichever board is on screen, with and without a source link; a capture and a dropped picture landing on the canvas in front as well as on today; something pasted shown in the middle with the microphone on, Return (not a held Return repeating) or a click on the pill ending the talking, Escape dropping it, several taking their turns, a drag not starting a capture over one, no speech engine, a dropped picture saved where it was dropped; words from the input box saved as a note with nothing spoken, attached things saved with what was written onto the canvas in front, and dictation handing over what is heard and the tidied whole ; the microphone in the editor adding what is said after the note, Escape taking it back, saving while it listens | 35 tests that drive `CaptureCoordinator` with stand-ins for screen, microphone, engine and overlay |
| Pasted and dropped things: what counts as a link; a copied link, a copied picture with the page it came from, copied picture files and files that are not pictures, plain text left alone, all read from a private clipboard; pictures keeping their density and brought down to size; a link's card from its address being words on the panel and nothing else; things waiting in the input box, taken out again, sent on with Return; typed words saved as a note, alone or with what is waiting, and a typed link going on to be spoken about | 11 tests |
| Tidy guard and the 3-second limit | 21 tests |
| Storage: round trip, edits and moves persisting across a reopen, deletion, unreadable index, PNG round trip; notes by day, week and month; archive, restore and seen; sample notes never written to disk; indexes in the older shapes, with overlapping cards moved apart in the oldest and left alone in version 3; projects and canvases surviving a relaunch; one note with a place on its day and another on each canvas; archive, delete and rename rules; a made-up note's place on a canvas never written | 20 tests |
| Projects and canvases in the bar: starting on the timeline; a new project with its first canvas in front and its name being typed; a new canvas in the project being looked at; going to the timeline and back; delete in two clicks, the canvas in front giving way to its neighbour or the day; a pan and zoom per canvas that leaves a day's alone; adding existing cards clear of one another; the next new note looked for on the canvas in front first | 9 tests |
| Groups: the pictures of a group tiling its tile exactly, none overlapping, none squeezed far out of shape, nine at most; a card of words as a small square chip under the pictures, or in the middle when there are none; a group needing two notes and surviving a relaunch; one group per note per board; a canvas's groups going with the canvas; grouped cards sitting where their group is, on a day and on its week; what a dragged card is over; letting go over a card or a group; ungrouping and taking a card out, with nothing left overlapping | 11 tests |
| Finding room for a card (never touching another, nearest first, in view when possible, the same every time); the height estimate against cards as really drawn, and kept until the note changes; seen after a moment in view; opening and closing a card; a pan and zoom per board; fitting a wide board between the timeline and the input box; a new note going on today's board from anywhere; archive and restore; recentering from anywhere, at 100% when the cards fit and smaller when they do not, on a day and on a month, and on an empty board | 29 tests |
| The mini map as an orb: the window's view always at its middle, every card within range drawn and the glass used to its edge, the range limited however far away the cards are; cards in range give no light, a card out of range lights the rim exactly on its own side in its own colour, the light comes up as a card leaves the range, more cards make it brighter and never more than full, a far card's light is fainter and narrower but never out; different hues that lie the same way are fanned out round that direction and not mixed to white, one hue stays together; a screenshot's colour is that of its colourful part; a screenshot reduces to a few blocks of its own colours; the choice of edges or orb is kept, and one this version does not have is read as the edges | 19 tests, and `--maps` renders in dark and light, reviewed by eye |
| The window's edges as the map: a card lights only the edges it lies wholly beyond, where it is along them and in its own colour; the other edges stay dark; its light is a little wider than the card and ends there, and a pile of cards is brighter but no wider; a card beyond a corner lights the two edges that meet there, more on the one it is further beyond, and one far above and only just past the corner hardly lights the side; the light comes up as a card goes out of sight, is fainter far off but never out; a card that can be seen, even partly, gives none; the same light whatever number of samples the edge is drawn with | 1 test, and `--edges` renders on a wide window, reviewed by eye |
| Every card out of view, and which way they are: nothing said while any part of a card can be seen or there are no cards; one card pointed at, straight up when it is above the middle and on the slant when off to a side; cards lying the same way one direction, towards the middle of them; cards with a gap between them a direction each, the fuller first, and a cluster across the place where angles wrap not cut in two; never more than three; ringed all round, the nearest; a name for each direction to be read out | 6 tests, the same `--edges` renders, and `--motion` for the fade in and out (nothing for 0.15 s, then up over half a second; gone in 0.2 s), the chevrons' turns, and a chevron moving at once when the direction changes |
| Undo and redo: delete (the card back on its canvases and in its groups, its picture kept on disk until quit), moves, archive and restore, renames, project deletion, newest first; nothing recorded for changes that change nothing; typing into a card one step however many keys, with changes made meanwhile kept apart; a card's new marker and a link's picture not taken back; what an undo puts back saved | 7 tests |
| Time: where a day, week and month start and end, stepping across month and year ends, how periods are named; the timeline's tiles at each scale; several days set out as blocks that keep their shape, never touch and read in date order; sample days the same every time, never today, stable as days pass | 13 tests |
| Source links: what is kept and what is ignored, and how a link is shown | 5 tests; the lookup itself run against Chrome (found, 29 ms) and Spotify, Slack, Notes, Finder and Conductor (correctly nothing) |
| The palette in both appearances, text contrast on every surface, the light-mode switch | 4 tests |
| Microphone resampling to 16 kHz mono (48, 44.1, 24 and 16 kHz, mono and stereo) | 2 tests with synthetic audio |
| `scripts/fetch-toolchain.sh` downloads, verifies and unpacks a working toolchain | Ran it into an empty folder |
| `scripts/run.sh` builds, launches, quits the app when stopped, ends when the app quits, replaces a copy that is already running, tries again when macOS refuses to open the app, and fails with an error if it never opens | Ran a copy of the script against an invisible stand-in app with its own bundle identifier: launch and stop, ten replacements in a row, a launch made to fail twice, a launch made to fail always |
| Parakeet: model download with progress, load, interim results, final transcript | `--transcribe` on synthesised speech, macOS 15.7 |
| The app launches and idles at 0% CPU; window, status item and store directory are created | Launched the signed bundle on macOS 15.7 |
| The selection glass: its brightness across the edge against a screenshot of the LiquidGlass playground at the chosen settings, against the library's shader arithmetic, and as actually drawn at 1x and 2x | 10 tests, and `--glass` over the playground's own photograph compared with the screenshot |
| Every screen's layout and styling in dark and light: the timeline and its switch, a day's board, a week's, a month's and all time, cards with their links and new marker, an opened card, the archive, the settings panel, the selection glass over light and dark content, at 1x and 2x | `--snapshot` renders, reviewed by eye. The frosted blur under the timeline and input box does not appear in them |
| Signing with the local identity; the designated requirement is the same on every build | `codesign -d -r-` |
| `xcodegen generate` produces a project with the package dependency, the app target and a shared scheme | Inspected the generated project |

### Not verified: needs you

Roughly in the order worth trying.

1. **The event tap.** That it installs once Accessibility is granted, sees
   Left Option, and that held mouse events replay correctly into real apps.
   The decision logic is tested; the plumbing to `CGEventTap` is not. Try
   first: Option-click a link in Safari, Option-click in Finder, type `é` and
   `π`, use ⌥⌘ shortcuts. All should behave exactly as without the app.
2. **The overlay window.** That it appears on the right display without
   activating the app, sits above the menu bar and Dock, shows over full-screen
   apps, and that the lift animation is smooth. Also that the glass looks on
   a real display as it does in the offscreen renders, and keeps up with a
   fast drag across a large display (redrawing it measured about 2 ms
   offscreen).
3. **Screen capture.** That the rectangle is exactly what was selected, at
   full resolution, without the overlay's dim or border in it, and with no
   cursor. Check a second display and a scaled resolution if you have them.
4. **Keyboard focus.** That the editor takes the keyboard without bringing
   this app forward, that ⌘C, ⌘V and ⌘Z work in it, and that focus returns to
   the app you were in after saving or discarding.
5. **The microphone.** Start-up delay (the first fraction of a second after
   the drag begins may be lost while the input starts; longer with Bluetooth),
   the waveform's response, and changing input device mid-recording.
6. **Permission prompts.** The request flow for each of the four, the System
   Settings links (they use the long-standing `com.apple.preference.security`
   addresses), and whether permissions really do survive a rebuild with the
   self-signed identity.
7. **SpeechAnalyzer.** Never run. Asset download, interim results, final text.
8. **Tidy.** Never run against the real model. Whether it removes "um" from
   two sentences within about 2 seconds, how often the guard rejects its
   output, and whether the instruction needs tuning. `--tidy` helps here.
9. **Xcode.** `xcodebuild` on the generated project, and signing there.
10. **The window, by hand.** None of this has been clicked: the timeline's
    tiles, scrolling it back with two fingers and with its arrows, and the
    day / week / month / all switch under it; the `timeline | projects`
    switch, making, naming, renaming and deleting projects and canvases
    (typing a name in a tile needs the keyboard to go to it, which no render
    can show), adding a card to a canvas from its right-click menu, dragging
    cards on a canvas, and capturing onto one; dragging one card over another
    to group them (the greying and the sign while it is held there, which
    only a still render has shown), naming a new group on its tile, opening a
    group, selecting cards in it and removing them, and ungrouping; writing a
    note in the input box, dictating into it (nothing has listened through
    that path on a real microphone), and attaching files with the paperclip; the words and chevrons
    in the middle of a board with nothing in view, in the real window (their
    fade and their turns were measured moment by moment in a hidden one with
    `--motion`, which is not the same as watching them while scrolling);
    the microphone in the capture editor on a real microphone (the path
    is tested with a stand-in; nothing has listened through it), and the
    frosted glass of that editor, which blurs the screen behind the overlay
    and so is in no render;
    clicking **recenter** under them, the round-arrow button in the status
    bar and ⌘9, and how the board looks as it glides back; the light on the
    window's edges while the board is actually being scrolled (stills show
    which edges light and where; whether it comes and goes smoothly, and how
    it sits against real screenshots and a real window's rounded corners, is
    unseen); the picture of a pasted link's page, which has never been taken
    from a real site (the code that loads the page and composes the card
    compiles and is not covered by a test or a render), and clicking it to
    open the link; clicking and dragging on the
    mini map, the map settling round the new view when the drag ends, and
    whether it keeps up while the board is being scrolled; the orb's rim
    lighting up and its cards melting into the edge as the board is scrolled
    away, on real screenshots rather than the sample ones; switching between
    edges and orb in the settings; the three tiles in an empty board's
    prompt lighting up in turn; a week's board fitting itself to the window, its date headers
    opening their days, and how smoothly a month's or all time's board pans
    and zooms; the frosted glass under the timeline and the input box (a
    system blur of the board behind them, which no offscreen render shows);
    a card's screenshot dimming under the pointer and the link under it
    opening the source; opening a card, editing its note there, and edit,
    archive, restore and delete on it and in the right-click menu; Escape
    closing the card but only ending the edit while one is in progress;
    "N new" and "N archived" in the status bar; the new marker clearing
    after a second in view; the Dock badge; ⌘Z and ⇧⌘Z on the board, and
    the names in the Edit menu ("Undo Delete Card"); the settings panel, and the whole
    window changing colour when light mode is switched; pasting a link and a
    picture into the input box from real apps (Safari, Chrome, Finder,
    Preview, a screenshot on the clipboard), Return bringing each up with the
    microphone on, Return again ending the talking, and the keyboard going
    back to the window afterwards; dragging a picture onto the board from
    Finder and from a browser.
11. **Source links from Safari and from document apps.** Only Chrome was open
    to try. Safari and apps such as Preview are expected to report their page
    or file the same way; `--source-link` will show whether they do.
12. **Timing.** "Centred in well under a second" and "editor within about 2
    seconds" are designed for but unmeasured outside the Parakeet numbers above.

### The acceptance list

| # | Criterion | State |
|---|---|---|
| 1 | Builds from a clean checkout with the documented commands | Route A: yes. Route B: project generates, build unverified |
| 2 | Drag, release: selection centred with prompt and moving waveform in well under a second | Logic tested; needs a real session |
| 3 | Two sentences with an "um", release: editor within about 2 s, without the "um" | Transcription measured at about 0.1 s. Removing "um" needs tidy, so **macOS 26 with Apple Intelligence**; on macOS 15 the "um" stays |
| 4 | Edit a word, ⌘↩: node with the image and edited note | Tested with stand-ins; needs a real session |
| 5 | Edit a note on a node, click away: persists after relaunch | Store persistence tested. Editing now happens in the opened card; that path needs a real session |
| 6 | Escape at any phase leaves no node | Tested in every phase |
| 7 | Option-click, Option shortcuts and Option characters unaffected | Decision logic tested; needs a real session in Finder and Safari |
| 8 | With tidy off, the saved note equals the raw transcript | Tested |

## Decisions that differ from, or go beyond, the brief

- **Deployment target 15.0**, not 26. See [Requirements](#requirements).
- **Option-clicks are delivered on mouse-up**, and Option-drag in other apps
  is taken over. See [How Left Option is treated](#how-left-option-is-treated).
- **The permission checklist appears whenever something is missing**, not only
  on the very first launch, and can be hidden.
- **Source app, window title and link** are those of the frontmost app and
  its frontmost window, as the brief says of the first two. If you drag over
  a window that is not frontmost, the card names the frontmost app, not the
  one you captured. The link is an addition, asked for later; see
  [Source links](#source-links).
- **Boards by day, and a timeline.** The brief describes one window with one
  canvas. On request each day now has its own board, reached from a timeline
  floating at the top of the window, and a switch brings a week, a month
  or all time together on one board with each day as a headed block. A
  capture always goes onto today's. (For an hour in between, notes were
  filed into projects and canvases in a left bar; that was dropped on
  request, and an index from then still loads.) The timeline is padded out
  with made-up sample days for now, which can be switched off in the
  settings.
- **Projects and canvases, in the top bar.** Asked for again later, this
  time beside the timeline and in its style, not instead of it. Chosen with
  the user from four mocked layouts: one strip with a `timeline | projects`
  switch over it, a card on a canvas staying on its day as well, and
  captures landing on the canvas in front. The author's own choices within
  that: a new project comes with a first canvas so it is never empty to
  start with; names are typed in the tile, not in a dialog; a canvas has
  no archive of its own; and the window always opens on Today, not on the
  canvas last open.
- **Pasting and dropping.** Not in the brief, which has the screenshot as
  the only way in. Asked for: links and pictures pasted into the box at the
  bottom wait there, Return takes them through the same voice step as a
  capture, and a picture dragged onto the board does the same at once. Three
  things here are the author's reading. Since no key is held, Return (or a
  click on the pill) ends the talking, where letting go of Left Option does
  for a capture. A link's card was at first drawn from its address with
  nothing fetched, because the app made no network calls; a picture of the
  page was then asked for, and that lifts the rule for this one case (the
  page of a link you paste) and no other. And several things pasted together
  become one card each, one after another, not one card between them.
- **Finding the cards: the window's edges, or an orb.** Not
  in the brief; asked for once boards could be scrolled without limit. The
  first was a map of the whole board with an arrow to the nearest card. The
  orb was asked for in its place ("colorize the edges of the map
  directionally where there is content... should really look like an orb")
  and then as an option beside it. Last came the window itself as the map
  ("treat the window as the map itself, instead of having a dedicated mini
  map"), then quieter and stricter ("only glow in direction where there is
  stuff off screen, don't let it bleed too much"). That is the default, being
  the one asked for last. The overview was later asked to be deleted, with
  the line of description under the setting; the orb stays as the other
  choice. The author's reading of the edge light: a
  card any part of which is in view gives none; a card beyond a corner is
  shared between the two edges by how far beyond each it is; the light comes
  up over a short distance as a card leaves, so nothing pops; and a crowd of
  cards is capped not far above one card, so the middle of a full board is
  not ringed with bright light. The first version worked out direction as a
  bearing from the middle of the window, which on a very wide window put
  cards that were above it on the left edge; it is now a straight projection
  onto each edge, and a test holds it to that. Then, for when no card is in
  view at all, words in the middle ("kinda like the hold and record
  instruction, that says 'stuff's over there'") with "just the chevron
  pointed directionally", fading in. The author's reading there: the chevron
  sits beside the words on the side the cards are, not after them in the
  line; separate directions get a chevron each, three at most; a direction is
  the way to the middle of the cards that lie that way, from the middle of
  the window (a bearing is right for a pointer in the middle, as it was wrong
  for the edges); the fade waits a moment so that it does not flash over
  gaps; and the words are cased like the prompt they are modelled on. The
  chevrons were then asked to "phase in and out opacity like the keys in the
  instructions", which they do in turn, and for a "recenter" link under the
  words and a reset button with a refresh icon beside the zoom. Recenter
  fits the cards rather than only scrolling to them, since being lost is as
  often a matter of zoom as of place; the menu item and ⌘9 were added so
  that it can be done from the keyboard.
  Three things about the orb are the author's reading of that request. It is
  centred on the window's view and has a limited range, because light on the
  rim only means a direction if you are in the middle and the cards can be
  out of sight. Colours are "from a few" cards side by side, fanned out by
  hue, not averaged, because the average of any three differently coloured
  cards is white. The orb can be clicked and dragged to move about, which goes a little
  beyond the "visual effect" asked for, because until there is a search it is
  the only way back to a cluster that has been scrolled away from.
- **Frosted glass under the timeline and the input box.** Asked for "in the
  traditional sense, using that repo". The rim light and shadow follow the
  LiquidGlass shader at close to its default settings. The body is the
  system's blur of the board behind, not the library's refraction: bending
  the picture behind the glass needs a shader run over the window's own
  contents, which the script build here cannot compile.
- **Cards are small and open on a click.** The brief has the note edited in
  place on the canvas and the image opening at full size on a click. On
  request a card on a board now shows only the screenshot and the first
  lines of the note, and a click opens it into a larger card where the note
  is edited and every action is laid out, archiving among them (also asked
  for later). Full size is one of those actions.
- **A new card goes in the nearest clear space**, not always "the centre of
  the current view" as the brief says. It is the centre when the centre is
  free.
- **Notes not yet looked at are marked**, on the card, on the timeline, in
  the status bar and on the Dock icon. Not in the brief; asked for later.
- **A warm dark palette, and a light mode.** The brief specifies dark only on
  `#0A0A0A`. On request the palette was changed to the warm near-blacks of a
  reference screenshot, with a sand accent in place of amber, and a
  light-mode switch was added in a settings panel opened from a gear at the
  bottom left. The engine and tidy switches, which the brief puts in the
  menu bar, were first repeated in the panel and then, on request ("only
  place parakeet and tidy should show up are in the settings"), left there
  alone: the menus, the capture editor and the opened card no longer name
  either. The capture overlay stays dark in
  both modes.
- **System typefaces only.** Notes were first set in Charter; on request
  everything is now SF Pro, the system face, and nothing else.
- **This app's own windows are excluded from captures**, as the brief says. A
  drag over the canvas window captures what is behind it.
- **A notice appears at the bottom of the screen** if you Option-drag while
  capture is off, saying why.
- **The menu bar item's entries are repeated in a Capture menu** in the app's
  menu bar, so they stay reachable when the item is hidden behind the notch.
- **The selection is clear glass, not an accent border.** The brief asked for
  a crisp 1 px accent border and no gradients or shadows; this was changed on
  request after the first hands-on session, to the look of the
  [LiquidGlass playground](https://liquid-glass.ybouane.com) at Edge
  Highlight 1, Corner Radius 7, Z-Radius 54, Opacity 0.94, Shadow Opacity 0.5,
  Shadow Spread 20 and everything else off. `GlassPanel` follows that
  library's shader for those settings: a one-point bright stroke just inside
  the edge, strongest along the top; a short glow inside it; a faint
  darkening of the glass towards its edge; a soft shadow outside; nothing at
  all in the middle. It is drawn by the app rather than with a system
  material, so it is the same on macOS 15 and 26, and it is in the overlay
  window, so none of it reaches the saved image. The accent now colours only
  the recording waveform. Three things differ from the library:
  - The library adds light to the page. A window laid over other apps can
    only put white on top of them, so the stroke and glow come out a little
    brighter than the library's over dark content and a little dimmer over
    photographs, by up to a tenth of full scale. `overlayGain` sets the
    balance.
  - The glow is at most 16 points deep, as on the playground's sample panel.
    The library's grows with the panel, which on a large selection would
    haze over what you are selecting.
  - Sizes are in points, so the stroke is as thick on a Retina display as on
    an ordinary one. The library's is fixed in pixels.
- **Zoom scales the layout and type** rather than applying a transform, so
  text stays sharp at any zoom. Every card on a board is a live view; there
  is no culling of the ones out of sight. Small cards load thumbnails rather
  than full screenshots and, below a certain size, draw nothing but their
  picture, which keeps a month or all time affordable for now. With many
  hundreds of notes on one board, panning and zooming will get slower.
- **No hardened runtime and no sandbox.** A global event tap and the plain
  `~/Library/Application Support/Terminal` path both need the app unsandboxed.
  This is a local build, not something to distribute as it stands.

Not built, as the brief asked: voice commands, automatic cropping, OCR, any
cloud or third-party model, links between nodes, search, tags,
recommendations, summaries, accounts, sync, sharing and other platforms. The
settings beyond the brief's engine and tidy switches are light mode, sample
days and the kind of mini map.
