# Nudge

Physical buttons are disappearing, and blind people are being locked out of their own kitchens. Nudge gets them back in.

Nudge is an iPhone and Apple Watch app that helps blind and low-vision people use touchscreen appliances. You point the phone at the screen, or wear it on your chest, and say what you want ("cook for 90 seconds"). Nudge reads the screen, works out which keys to press, guides your fingertip to each one with sound, voice and taps on the wrist, and after every press reads the screen again to check that it did what was expected.

This is a hackathon prototype built in about 36 hours by two students. Nothing in it has been clinically validated or certified, and it has only been used by its two authors, on one simulated microwave panel shown on an iPad. Figures below come from our own recordings and are labelled as such.

## Status

| Feature | State |
|---|---|
| Find and anchor a screen it has never seen | Working on the phone |
| Read key labels on the phone | Working, with misreads in dim light (see limitations) |
| Spoken goal, planned as a whole route | Working on the phone |
| Fingertip guidance by tones, voice and Apple Watch | Working on the phone |
| Finger tracking when the palm is out of view (LiDAR backup) | Working on the phone |
| Re-read the screen after each press and check it | Working on the phone |
| Recover from a wrong press | Seen once on the phone: a wrong key opened the timer, and Nudge had the user press Stop and start again |
| "Tap" held back until the finger is near the glass | Built and installed; not separately confirmed |
| Spoken help to aim the camera at the screen | Working on the phone |
| Worn on the chest, hands-free: asks what to do as soon as it opens | Built late; used for the recorded demo |
| Apple Watch: beat that quickens as the finger closes in, on-target, confirmed and wrong cues | Working on the phone and Watch; the Watch sometimes goes quiet part-way through a task |
| Choice of feedback channels (tones, voice, watch) | Built |
| Saved devices and saved tasks that replay with no network | Built; logic tested on a Mac; not confirmed on the phone |
| Demo-safe mode (saved device and tasks only, no network) | Built; logic tested on a Mac; not tried on the phone |
| Test log with CSV export | Built and used (`docs/test-log-2026-11-14.csv`) |
| The app's own captioned video of each task | Built; used for the recorded demo |
| Payment screens refused, risky steps confirmed first | Written; tested from a Mac, not on a real payment or oven screen |
| 3D spatial audio with head tracking | Not built. Guidance tones are stereo: left and right by position, pitch by height |
| AirPods Transparency reminder | Not built |
| On-device planning with Apple's foundation model | Not built. Planning uses a cloud model; a saved task replays on the phone with no model at all |
| Voice shortcuts under a new name ("heat my coffee") | Not built. A saved task is found by the words it was first asked with |
| Shared appliance library | Not built. Saved devices hold exactly what would be shared (labels and positions, no pictures) |
| Low-vision magnifier | Not built |
| Label translation | Not built |

## How it works

```
 camera frame ──► find a rectangle that holds text ──► pin it as a rectangle in 3D (ARKit + LiDAR)
                        │
                        ├──► flatten the screen ──► read its keys on the phone (Vision)
                        │                                   │
                        │              a saved device? ─────┤ put its saved labels back on the keys
                        │                                   │
 spoken goal ──► speech to text on the phone ───────────────┤
                                                            ▼
                               planner: the whole route ("9, then 0, then Start")
                               cloud model, or a saved task replayed on the phone
                                                            │
 every frame:  fingertip in the picture (Vision hand tracker)       │
               finger as a ridge in the depth map (LiDAR)  ─────────┤
               ──► where the finger pad will land, and how high     ▼
                               guidance: stereo tones, one-word voice cues, Watch beat
                                                            │
                         user taps and takes the hand away ◄┘
                                   │
                                   └──► read the screen again ──► check the press ──► next key
```

### The pieces

- **Finding the screen.** Vision proposes rectangles; Nudge keeps the one that most tightly holds text, and confirms it by reading at least three labels in it, so a desk or a door is not taken for a screen. The corners are placed in 3D on a plane fitted through LiDAR points, so key positions stay right while the phone moves. The outline is then widened to take in the display above the keys.
- **Helping aim.** A blind user cannot see the camera's view, so while searching Nudge says which way to move ("Tilt the phone down a little", or for a phone on the chest, "Lean forward a little"). Before a key low in the picture it asks for a small tilt so the hand will be in view.
- **Reading.** A high-resolution still is flattened and read on the phone. Small images are enlarged first and read in overlapping pieces; key outlines are found and read one at a time; digits a key-pad grid implies are filled in. A key that cannot be read is still kept, marked unread.
- **Planning.** The planner returns the whole route in one answer. After each press Nudge moves straight on to the next key while the planner checks that press in the background against a fresh reading. If the check disagrees, guidance is interrupted and the check's answer is followed.
- **Tracking the finger.** Apple's hand tracker gives the fingertip in the picture, but it needs to see the palm. With only a finger in view it reports nothing. LiDAR still sees that finger as a ridge standing above the screen, so Nudge finds the ridge, works out which way it points and uses its end. When the hand tracker does see the fingertip, its position in the picture is combined with the ridge's height, which is far steadier than the depth at a single pixel.
- **Parallax.** The fingertip is placed in 3D and dropped straight down onto the screen plane, so the reported position is where the finger will land, not where it appears from the camera's angle.
- **Guiding.** Tones sit left or right with the key, rise in pitch when it is higher, and quicken as the finger closes in. The voice says little: a direction, "a little" when close, "Closer to the screen" when lined up but far from the glass, and "Tap". The Watch gives a beat that quickens with closeness, generated on the Watch so it stays even.
- **Knowing a press happened.** Nudge waits for the hand to leave, then reads the screen until it differs from before.
- **Saved devices.** After a task that goes right first time, Nudge offers by voice to remember the device: key labels and positions only, on the phone. Next time it recognises the screen from the labels it reads correctly (mostly the digits), fits the saved layout to the new outline, and puts the saved labels back on misread or missed keys. A goal done before is replayed from the phone with no planning.
- **Hands-free on the chest.** With "Worn on the chest" on, the app opens by asking "Hey, what do you want to do?", and when a task ends it asks by voice what to do next. The screen switches off and ignores touches while it is against the body. Every button still works.

## What we measured

These are from our own recordings of the authors using Nudge on the iPad panel, not from a user study.

- **Finger tracking, 800 recorded frames across two runs of "cook for 90 seconds".** Apple's hand tracker alone gave a fingertip in 483 frames. With the LiDAR backup, 644. On the Start key in one run, 75 of 182 frames became 177, and the longest loss fell from 3.8 seconds to 0.2.
- **Agreement.** Where both saw the finger, the backup and the hand tracker agreed to 2.7 mm at the median and about 10 mm at the 90th percentile.
- **Steadiness.** While the finger was still in the picture, the old method (depth at the fingertip pixel) moved the reported position by more than 8 mm in 26 of 433 frame pairs. Using the ridge's height, 1.
- **A run done blind.** In one eyes-closed run the hand tracker found the finger in a few dozen frames per key and the LiDAR backup in 143 to 256; the task completed, including a recovery from a wrong key.
- **Test log.** `docs/test-log-2026-11-14.csv` holds 53 attempts from the day of development up to about 8 PM on 14 November: 9 completed, 2 failed, 42 stopped by hand, most of those while a fault was being diagnosed. It is a development log, not a success rate.

The recordings can be replayed with `Tools/track-replay`, which is how every change to tracking was measured before it went on the phone.

## What stays on the phone, and what does not

| On the phone | Sent to a cloud model |
|---|---|
| Camera frames, the screen outline, 3D tracking | Key labels and their positions, as text |
| Text recognition | The spoken goal, as text |
| Hand tracking, LiDAR depth, the finger finder | A picture of the screen, only when the planner asks for one |
| Speech recognition (on the phone where the phone supports it) | |
| Saved devices and saved tasks | |
| Payment-screen and personal-information checks | |
| The test log and the task videos | |

A picture is never sent if the labels suggest personal information. That check is basic: it looks for words such as "password" and for @ signs, and would not catch personal content shown in other ways.

A saved task replays with no network at all. Planning something new needs the cloud model.

The cloud key is built into the app. That is acceptable for a demo on the authors' own phone and not for distribution.

## How it compares with earlier work

| | Needs setup per device | Plans toward a goal | Checks each press | Guidance |
|---|---|---|---|---|
| Apple Magnifier "Point and Speak" | No | No, reads text under the finger | No | Speech |
| VizLens (research) | Yes: a reference photo labelled by crowd workers | No | No | Speech |
| StateLens (research) | Yes: videos of the device, plus crowd labelling | Yes, from a pre-built model of the device | Follows its pre-built state model | Speech |
| Nudge | No | Yes | Yes, by re-reading the screen | Stereo tones, speech and Watch haptics |

This table reflects our reading of the published descriptions of those systems, not a side-by-side test.

## Honest limitations

- **One device, two users.** Everything was built and tried on one simulated microwave panel on an iPad, by the two authors. It has not been tried by a blind user or on a real appliance.
- **Reading in dim or coloured light.** Function-key labels were often misread ("Popcom", "Roheat") or not read. In one run this led the planner to the wrong key. Saved devices are the fix for a device used before; a new device in poor light is still at risk.
- **A wrong key is only caught by the planner.** When a saved task is replayed with no network, a press counts as confirmed if the finger was guided onto the key and the screen changed. Nudge then reads out the display instead of claiming more than it knows.
- **Fast movement.** LiDAR smears a fast-moving hand, and the backup stays silent on those frames on purpose.
- **A finger flat on the glass.** The backup can read up to about 8 mm short of the fingertip. Its sideways correction was measured with one hand position on one phone.
- **Depth near the glass.** LiDAR cannot tell a finger 2 mm above the screen from one touching it, so Nudge only holds "Tap" back when the finger is several centimetres away.
- **Icon-only screens.** A screen is only accepted if at least three pieces of text can be read on it.
- **Speed.** Planning a new goal takes roughly 3 to 6 seconds and occasionally times out. Each press needs the hand out of view for about a second so the screen can be read.
- **The Watch app** is awkward to install during development (see `HANDOFF.md`), and sometimes goes quiet part-way through a task.
- **Not built:** head-tracked spatial audio, the Transparency reminder, on-device planning with Apple's model, the shared library, the low-vision magnifier and translation.

## Building

Requirements: a Mac with Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen), an iPhone with LiDAR, and optionally an Apple Watch.

1. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and add at least one key (OpenAI, Anthropic or Gemini).
2. Plug in the iPhone and run:

```bash
scripts/deploy.sh
```

Add `--watch` to update the Watch app as well. `HANDOFF.md` records what that needs.

Tools that run on a Mac:

- `Tools/track-replay/build.sh` builds the tools that replay a recording from the phone and score the finger finder.
- `Tools/device-tests/run.sh` tests saved-device matching and the offline replay of a saved task.
- `scripts/sim.sh <folder>` builds for the simulator and screenshots each screen (layout only).

## Design

Yellow on black, and dots. Both come from tactile paving, the raised yellow dots that guide blind pedestrians, and yellow on black is among the most legible pairings for low vision. The logo is the letter "n" in braille. The dot field on the task screen mirrors the audio guidance, so someone watching can follow what the user is hearing.
