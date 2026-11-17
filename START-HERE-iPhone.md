# Light Media for iPhone — start here

This is the iPhone version of Light Media 3.12, rewritten in Swift from the Android source.
It is built in the cloud by GitHub, so you do not need a Mac.

**Status: first build, not yet compiled.** It was written without access to Apple's compiler.
Expect the first cloud build to report some errors. Step 2 below shows where they appear;
send them back and they can be fixed quickly.

## What is in this build

- Opening ident, the same layout (logo, programme details, preview window, section menu, categories, footer pager and clock) and the same colour themes
- Live TV with the two-hour programme guide, Previous / Now / Next, and the preview window with Stop
- Films and Series with poster pages, search, details, seasons, episodes, resume and "Play from beginning"
- Favourites with groups, Continue watching, watched marks, hide a station
- Full-screen player: centred live controls (previous, play/pause, next, last channel, channel list, playback settings), Back to menu, Next episode, audio / subtitle / speed choices, the stalled-playback panel with Restart playback
- Settings: Appearance, Profiles, Customise browsing (sections, categories, titles, duplicates), Screensaver, Account (connect, live format M3U8/TS, refresh catalogues, sign out), clear watch history
- Demo catalogue and demo clip when no provider is connected
- The provider login is kept in the iPhone Keychain

## What is not in this build yet

- My Media, My Music and the NAS / UPnP library
- Downloads
- Catalogue and channel-list import / export, phone transfer
- Speed test

These sections are left out of the menu rather than shown half-working.

## What cannot exist on an iPhone

Apple does not allow these, so they are dropped: the Apps panel (launching other apps), in-app
APK updates, the Fire TV shortcut, TV-remote and game-controller navigation, and the
Standard / Compatibility video output switch (the iPhone has one video path).
On-screen hints say "Tap" and "Hold" instead of "OK" and "Hold OK".

## Step 1 — put the code on GitHub (free, 5 minutes)

1. Sign in at github.com and create a new **private** repository, for example `light-media-ios`.
2. Unzip this folder on any computer. On the repository page choose **Add file → Upload files**
   and drag in everything inside the folder, including the hidden `.github` folder.
   If your computer hides it, upload from a phone or create the file
   `.github/workflows/ios.yml` on GitHub and paste its contents.
3. Commit to the `main` branch.

## Step 2 — check it compiles (no Apple account needed)

Open the **Actions** tab. A run called **Build iPhone app** starts by itself.

- Green tick: the code compiles.
- Red cross: open the run, open **Compile check → Compile**, and copy the lines under
  "Compiler errors". Send those back to be fixed. The full log is also attached to the run as `compile-log`.

## Step 3 — Apple setup (once)

You need the paid Apple Developer Program membership.

1. **Team ID**: developer.apple.com → Account → Membership details. Copy the 10-character Team ID.
2. **App ID**: developer.apple.com → Account → Certificates, IDs & Profiles → Identifiers → **+** →
   App IDs → App. Give it a Bundle ID that is yours alone, for example `com.yourname.lightmedia`.
3. **App record**: appstoreconnect.apple.com → Apps → **+** → New App → iOS. Pick the Bundle ID from
   step 2, any SKU, and a name nobody else is using (for example "Light Media RG").
4. **API key**: appstoreconnect.apple.com → Users and Access → Integrations → App Store Connect API →
   Team Keys → **+**. Role: **Admin**. Download the `.p8` file (it can be downloaded once) and
   note the **Key ID** and the **Issuer ID** shown on that page.

## Step 4 — give GitHub the Apple details

In the repository: **Settings → Secrets and variables → Actions → New repository secret**. Add five:

| Name | Value |
| --- | --- |
| `APPLE_TEAM_ID` | the Team ID |
| `BUNDLE_ID` | the Bundle ID, e.g. `com.yourname.lightmedia` |
| `ASC_KEY_ID` | the API Key ID |
| `ASC_ISSUER_ID` | the Issuer ID |
| `ASC_KEY_P8` | the whole text of the `.p8` file, including the BEGIN and END lines |

## Step 5 — build and install

1. **Actions → Build iPhone app → Run workflow** (leave "Sign and upload to TestFlight" ticked).
2. When it finishes, wait for Apple to process the build (usually 5 to 30 minutes).
3. In App Store Connect open the app → **TestFlight** → Internal Testing → create a group and add yourself.
4. Install the **TestFlight** app on the iPhone, accept the invitation, and install Light Media.

Each later run uploads a new build number; TestFlight offers it as an update. A TestFlight build
lasts 90 days, so run the workflow again before then.

## Good to know

- The signing step is the part most likely to need one adjustment on its first run, because it
  depends on your Apple account. If it fails, the run attaches `signing-logs`; send the error lines.
- GitHub gives private repositories a monthly allowance of free build minutes and counts Mac
  minutes at a higher rate. A build takes roughly 10 to 15 minutes. Check GitHub's current
  pricing page if you build often; public repositories are not charged.
- Your provider login is never in the code or on GitHub. It is typed into the app and stored on the iPhone.
- The app allows plain HTTP because many providers require it, the same as the Android app.
- Playback uses VLCKit (see `THIRD-PARTY-NOTICES.txt`).
- Favourites and settings do not transfer from the Android app in this build.

## Layout of the code

| Folder | What it holds | Android counterpart |
| --- | --- | --- |
| `LightMedia/Core` | provider API, guide parsing, saved data, themes, profiles | `Provider`, `Media`, `Epg`, `LocalStore`, `Theme`, `Profiles`, `MainSections` |
| `LightMedia/Playback` | the shared player, preview window, full-screen player, playback settings | `PlaybackSession`, `LivePreview`, `PlayerActivity`, `PlaybackOptions`, `PlaybackMonitor` |
| `LightMedia/UI` | main browser, guide, poster grid, settings screens, drawing | `MainActivity`, `LiveGuide`, `TileBoard`, `Ui`, `Icons`, `BrandView`, the settings activities |
| `LightMedia/App` | start-up, ident, screensaver | `SplashActivity`, `IdleActivity`, `ScreensaverDialog` |
| `project.yml`, `Podfile` | project definition; the cloud build turns these into an Xcode project | `build.gradle` |
| `.github/workflows/ios.yml` | the cloud build | — |
