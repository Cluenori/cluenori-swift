# Cluenori for Swift

The SDK that runs inside your iPhone app and reports to your own Cluenori: sessions, events,
screens and how fast each shows its data, hitches and hangs on each screen, its CPU time, launches,
memory and MetricKit's reports, and the update gate that blocks a release you no longer support. Apple's frameworks only, MIT-licensed.

## Add it to your app

It is one Swift package with a small core and opt-in libraries. It needs iOS 26 or later and Swift
6.2 tools (Xcode 26 or later); it is built and checked with Xcode 27.2.

In Xcode, File > Add Package Dependencies, and enter `https://github.com/Cluenori/cluenori-swift`.
Or, in a `Package.swift`:

```swift
.package(url: "https://github.com/Cluenori/cluenori-swift", from: "0.2.1"),
// and in your target:
.product(name: "Cluenori", package: "cluenori-swift"),
.product(name: "CluenoriUpdateGate", package: "cluenori-swift"),
```

`Cluenori/cluenori-swift` is a read-only mirror of `sdks/swift` in
[Cluenori/cluenori](https://github.com/Cluenori/cluenori), published on every change; open issues
and pull requests there. A version is published by pushing a `swift-v<version>` tag there, such as
`swift-v0.1.0`, which the mirror carries as `0.1.0`. To work on the SDK inside an app, add this
folder by local path instead (File > Add Package Dependencies > Add Local).

Then link the libraries you want:

| Library | What it adds | Why it is opt-in |
|---|---|---|
| `Cluenori` | Start, the installation, sessions, identify, consent, features, the manifest and the update gate's decision, the queue, and headers for your API | Every app needs it |
| `CluenoriUpdateGate` | The gate's views: "Update to continue", the update sheet, the device notice | App size |
| `CluenoriAnalytics` | `track` and `cluenoriScreen` | It changes your app's privacy label |
| `CluenoriPerformance` | Launch times, how fast each screen shows its data, hitches and hangs, CPU time and memory, MetricKit's daily reports | It subscribes to MetricKit, and watches the main thread |

## Quick start

```swift
import Cluenori
import CluenoriPerformance
import CluenoriUpdateGate
import SwiftUI

@main
struct NotesApp: App {
    init() {
        Cluenori.start(
            key: "<the component's SDK key>",
            environment: "production",
            deployment: URL(string: "https://cluenori.example.com")!)
        Cluenori.measurePerformance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .cluenoriUpdateGate()  // on the root view: shows the gate when the manifest says so
        }
    }
}
```

The release Cluenori sees is your app's own, `<CFBundleShortVersionString>+<CFBundleVersion>`,
such as `0.3.0+20`.

## The API

```swift
// The person
Cluenori.identify(userID: user.id)         // your opaque ID, never an email or a name; kept between launches
Cluenori.reset()                           // on sign-out: the session ends, the next starts without them;
                                           // the installation's ID stays (see "What it collects")
Cluenori.consent(analytics: .none)         // or .full, the default; kept between launches

// The feature the person is in: signals and requests made meanwhile belong to it
CardView().cluenoriFeature("cards.flip")   // while the view shows; the last one shown wins
let mark = Cluenori.begin(feature: "cards.flip")   // the same for a UIKit screen
mark.end()
Cluenori.feature("cards.export") { … }     // work done for a feature, across awaits too

// Your own API's requests
var request = URLRequest(url: url)
request.addCluenoriHeaders()               // or Cluenori.requestHeaders() for other HTTP clients

// CluenoriAnalytics
Cluenori.track("autograph.requested", properties: ["card_id": .string(card.id), "photos": 2, "first": true])
ProfileView().cluenoriScreen("profile")    // or Cluenori.screen("profile") from UIKit

// CluenoriPerformance
Cluenori.measurePerformance()              // once, right after start
FeedView(model: model)
    .cluenoriScreen("feed")
    .cluenoriScreenReady(.kept, when: !model.posts.isEmpty)    // its first content from what the phone kept
    .cluenoriScreenReady(.fresh, when: model.loadedFromNetwork) // and from the network
Cluenori.screenReady(.fresh)               // the same from UIKit, for the screen shown now
Cluenori.appReady()                        // the launch is timed to it; the first screenReady does it too

// The update gate, headless, for apps that draw their own
switch Cluenori.updatePrompt {             // observable: a SwiftUI view reading it follows each manifest
case .none: break
case .recommended(let offer): …           // a sheet the person can close: Cluenori.dismissUpdatePrompt()
case .required(let offer): …              // "Update to continue": can't be dismissed; open offer.storeURL
case .deviceUnsupported(let offer): …     // required, but this device's OS is too old to install it
}
UpdateRequiredView(offer: offer, appName: "Notes") { openURL(offer.storeURL) }   // the views take plain values
```

Every call returns at once and never throws. Files are read and the network used off the main
thread. A mistake in a call, such as a feature key that isn't one (`Cards Flip`), stops a debug
build at the call with what is wrong, and is logged and ignored in a release build.

Names follow Cluenori's rules: a feature key is lowercase keys joined by dots (`cards.flip`); an
event or screen name is 1 to 256 characters; a property key is snake_case (`card_id`) and a value
is a string of at most 256 characters, a number, or a boolean, at most 32 per event.

### What your API receives

`addCluenoriHeaders()` adds:

- `Cluenori-Release: 0.3.0+20`, so your API can apply the same version policy;
- `traceparent`, a new W3C trace for each request, unless the request has one;
- `baggage: cluenori.feature=cards.flip,cluenori.origin.component=notes-ios,cluenori.origin.release=0.3.0+20`,
  after any baggage the request has: the feature in effect, the component your SDK key names, and
  the release, the same keys in the same order as the web SDK's, so your backend can split its work
  by the client that called it.

Add them to requests to your own API only, never to a third party's.

### The update gate

At launch and on each return to the foreground, the SDK asks your Cluenori for the release's
manifest, unless the one it has is younger than the manifest's `maxAgeSeconds`.

- **Required:** `cluenoriUpdateGate()` replaces the app with "Update to continue" and a button to the
  App Store. It can't be dismissed.
- **Recommended:** a sheet the person can close; closed, it stays away for a day for that version.
- **A device too old for the update** is never blocked: it sees a notice it can close.
- **Fail open:** offline, the last manifest of this release is used; with none, the app is never
  blocked. A manifest of the release before an update is never used.

The words are the project's when its manifest has them, else the SDK's, in English, Ukrainian and
Russian. iOS picks the language your app runs in, so the SDK's words follow your app's
localizations.

## What it collects

| Signal | When | What it holds |
|---|---|---|
| `session.started`, `session.ended` | The app starts in or comes to the foreground; 30 s after it leaves it, or at the next launch if it was terminated | The session, its foreground time |
| `screen`, `event` (CluenoriAnalytics) | `cluenoriScreen`, `track` | The name, the properties you gave |
| `app.launched` (CluenoriPerformance) | Once a launch's first frame is drawn, and `appReady()` called or 30 s passed | Cold or warm, prewarmed or not, ms to the first frame and to ready |
| `screen.ready` (CluenoriPerformance) | `cluenoriScreenReady`, `screenReady`, once of each kind per visit | `kept` or `fresh`, ms since the screen appeared |
| `screen.left` (CluenoriPerformance) | The next screen shows, or the session ends while it shows | ms in sight, CPU ms the app used meanwhile, ms scrolled and ms of hitches while scrolling |
| `app.hang` (CluenoriPerformance) | The main thread answers 250 ms or more late, in the foreground | How long |
| `app.memory` (CluenoriPerformance) | Each minute in the foreground, on memory warnings, and as a session ends | `phys_footprint` now, and its peak |
| `metrickit` (CluenoriPerformance) | When iOS delivers MetricKit's reports, about daily | The report's JSON |

Each signal of a session carries its session, the user ID if `identify` was called, the feature in
effect, and the screen shown (with CluenoriAnalytics, which names screens): so a person's signals
read as their journey, screen by screen. Each batch carries the installation's ID, the environment, the release, the SDK, and the
device: its model (`iPhone18,1`), OS version, locale and time zone. Your Cluenori reads the country
from the request's address and doesn't keep the address.

It never collects typed text, the advertising ID, `identifierForVendor`, or anything from the
Keychain. The installation's ID is a UUIDv7 the SDK makes on the first launch and keeps in the app's
container, excluded from backups: a new install, or a restore to another device, is a new
installation. `reset()` keeps it: after a sign-out, signals carry no user ID but the same
installation, and Cluenori counts an installation's signals without a user ID for the last person
who signed in on it. `consent(analytics: .none)` stops all of it and drops what wasn't sent; the update
gate keeps working.

Each library brings its own `PrivacyInfo.xcprivacy`, so Xcode's privacy report lists what your
build includes: the core declares the user ID, the device ID (the installation's), product
interaction (sessions) and coarse location (the country), all linked to the person and used for
analytics; CluenoriAnalytics adds product interaction and other usage data, for analytics;
CluenoriPerformance adds performance, crash and other diagnostic data, for the app's functionality.
None is used for tracking. It uses none of the APIs
that need a stated reason: no UserDefaults and no file timestamps; `sysctl`, which reads the
process's start and the hardware model, isn't on Apple's list.

## Limits and failures

- **Never in the way.** Calls take a lock for microseconds at most and hand their work to a queue
  of their own. When Cluenori can't be reached, signals wait on disk and the app carries on.
- **Bounded.** At most 1,000 signals wait in memory to be recorded, and past that a new one is
  dropped; a call such as `reset` or a consent never is. The queue keeps at most 4 MB on disk,
  dropping the oldest signals past it. A batch has at most 500 signals and about 800 KB.
- **Sending.** Every 30 s while there is something to send, at once after 50 new signals, and as the
  app leaves the foreground, with a few seconds iOS gives for it. A batch leaves the queue only once
  your Cluenori has it; sent again after a failure, it has the same IDs and is counted once.
- **Failures.** No answer or a server error, such as a 503 when your Cluenori couldn't keep the
  batch, waits 5 s, doubling to 15 minutes, spread at random. A
  429 waits as long as it says. A 413 sends the batch in halves, and batches grow back as they get
  through; a signal refused alone is dropped. A 401 with your Cluenori's word that the key was
  refused means this release sends nothing more and records nothing more, and an update with a new
  release tries again; any other 401, such as a captive portal's, is tried again later.
- **Files it can't read yet,** as before the first unlock after a restart, are waited for, never
  taken as missing, so the person's consent and the installation stay as they were.

## Develop it

```
./check                      from here, or `bun run check:sdk-swift` from Cluenori's root: formatting,
                             Apple-only imports, the tests, and builds for the simulator, iPhones and the example
bun run generate             from Cluenori's root: rewrites Sources/CluenoriIngest and openapi.json
open Example/CluenoriExample.xcodeproj
```

`Sources/CluenoriIngest/CluenoriIngestAPI.swift` and `openapi.json` are generated from the server's
definitions, never edited by hand. The SDK's own code never writes a second client.

The example app is a tiny app that uses every library. Launched with `-CluenoriDemoGate require`
(or `recommend`, `unsupported`, `worded`, `none`), it answers itself as a deployment would
(`DemoDeployment.swift`), so the gate can be tried without one; otherwise it sends to
`-CluenoriDeployment <URL>` with `-CluenoriKey <key>`.

The tests use Swift Testing with a fake deployment, a clock the test moves, and a folder of their
own (`Tests/Support`). They drive the engine through its calls and check what reaches the
deployment.

## Structure

```
CluenoriUpdateGate   CluenoriAnalytics   CluenoriPerformance      opt-in: views, events and screens, performance
        └────────────────────┼────────────────────┘
                         Cluenori                                  the core
                             │
                      CluenoriIngest                               the generated client of the ingest API
```

Inside the core, the app's calls go to an inbox in the order they were made. The recorder takes
them one at a time: it owns the installation, the person, consent, the session and the queue, and
stamps each signal with its session, person and feature. Beside it, delivery sends the queue under
its rules, and the manifest is asked for and kept; the update gate shows it on the main actor.

## Decisions and constraints

- **The deployment's address is a parameter,** since an SDK key doesn't carry it: each founder's
  Cluenori runs at their own domain.
- **iOS 26 or later,** for Liquid Glass and Swift's `Mutex`; the gate's views use the system's glass
  buttons.
- **Warnings are errors in `./check` only,** never in an app's build, so a newer Xcode's new warning
  can't break an app that depends on this package.
- **The views are functions of plain values and closures:** an app can present them however it
  likes, and their previews show every state.
- **No signals outside a session:** an app launched in the background, such as by a push, records
  nothing until it comes to the foreground, except MetricKit's reports, which belong to no session.
- **Screens are CluenoriAnalytics' to name.** CluenoriPerformance measures the visits of the screens
  it names; without it, launches, memory, hangs and MetricKit are still measured, not by screen.
  Screens may be shown on any thread: each visit ends on the thread that showed the next, in the
  order they were shown, and a `reset()` ends the visit in the session that ends, the screen going
  on as a new visit in the next.
- **Hitches are measured while scrolling only:** a display link runs in the run loop's tracking mode,
  while a scroll view follows a finger or decelerates, so a screen at rest costs nothing. iOS has no
  signal for an animation that failed; late frames and a main thread that doesn't answer are the
  real ones. A hang is timed by a ping to the main thread every 100 ms from another, only in the
  foreground, so a suspended app is never one.
- **Crashes are MetricKit's,** each counted against the release its report names, so a crash of
  0.3.0 reported after the update to 0.4.0 is still 0.3.0's. No crash handler is installed, so the
  SDK never fights another reporter.
- **The memory as a session ends** is measured as the app leaves the foreground, and recorded only
  if the session ends before it comes back, even after the app was terminated.
