# Nudge

Physical buttons are disappearing, and blind people are being locked out of their own kitchens. Nudge gets them back in.

Nudge is an iPhone app that helps blind and low-vision people use touchscreen appliances. You point the phone at the screen and say what you want ("heat for 90 seconds"). Nudge reads the screen, works out which button comes next, guides your fingertip to it with sound and voice, and after each press reads the screen again to check that it did what was expected.

This is a hackathon prototype. Nothing in it has been clinically validated or certified, and it has only been tried by its two authors.

## Status

| Feature | State |
|---|---|
| Find and anchor a screen it has never seen | Working on device |
| Read button labels on the phone | Working on device |
| Step-by-step planning from a typed goal | Working on device |
| Spoken goal | Written; only typed goals have been tried so far |
| Fingertip guidance by tones and voice | Working on device, still being tuned |
| Re-read the screen after each press | Working on device |
| Recover from a wrong press | Correct in tests run from the Mac; not yet seen on device |
| Payment screens refused, risky steps confirmed | Written; tested from the Mac, not on a real appliance |
| Hover height from LiDAR | Measured, but too unreliable within a centimetre or two of the glass to speak about. The "Closer" and "Lift" prompts are switched off; the user is told once to keep the finger off the glass until "Tap" |
| Hand tracking from LiDAR when the fingertip is hidden | Written, but switched off: on the phone it made the pointer jump |
| Test log with CSV export | Written, not yet used |
| Apple Watch haptics | Watch app builds; not yet installed or tested |
| 3D spatial audio with head tracking | Not started (stereo tones are in) |
| On-device planning, saved devices, voice shortcuts, shared library, low-vision magnifier, translation, demo-safe mode | Not started |

## How it works

```
 camera frame ──► find screen outline ──► anchor it as a rectangle in 3D (ARKit + LiDAR)
                        │
                        ├──► flatten the screen image ──► read text on the phone (Vision)
                        │                                        │
 spoken goal ──► speech to text (on the phone) ──────────────────┤
                                                                 ▼
                                              planner: "which single button next?"
                                              (cloud model; labels as text, picture only if needed)
                                                                 │
 every frame:  fingertip (Vision hand pose, LiDAR fallback) ─────┤
               ──► position and height over the anchored screen  ▼
                                              guidance: stereo tones + one-word voice cues
                                                                 │
                         user taps and pulls hand away ◄─────────┘
                                   │
                                   └──► read the screen again ──► planner checks the result ──► next step
```

### The pieces

- **Finding the screen.** Apple's Vision framework proposes rectangles; Nudge keeps the one that most tightly contains text, since a control panel is a rectangle full of labels, and ignores rectangles with no text in them. Its corners are placed in 3D with ARKit, on a plane fitted through 25 measured points, so button positions stay correct while the phone moves.
- **Reading it.** A high-resolution still is flattened to a straight-on view and read with Vision text recognition on the phone. Keypad rows are split into separate buttons and two-line names ("TIME" over "COOK") are joined.
- **Planning.** The planner is asked for one step at a time and is called again after every press with a fresh reading. That is what lets it notice a wrong press ("That opened Defrost; press Stop/Clear") instead of following a plan that no longer matches the screen.
- **Tracking the finger.** Vision's hand tracker gives the index fingertip. LiDAR depth turns it into a 3D point, which is dropped straight down onto the screen plane, so the reported position is where the finger will land rather than where it appears from the camera's angle. When the hand hides the fingertip, a second tracker finds the part of the hand nearest the glass from depth alone.
- **Guiding.** Tones carry the continuous guidance: they sit left or right with the button, rise in pitch when it is higher, and speed up as you close in. The voice says very little: a direction ("Left", or "Left a little" when nearly there) and "Tap". Once "Tap" has been given it stands until the finger clearly moves away, so a few millimetres of wobble do not bring the directions back.
- **Knowing a press happened.** Nudge waits for the hand to leave the view, then reads the screen until two readings agree.

## What stays on the phone, and what does not

| On the phone | Sent to a cloud model |
|---|---|
| Camera frames, the screen outline, 3D tracking | Button labels and their positions, as text |
| Text recognition | The spoken goal, as text |
| Hand and fingertip tracking, LiDAR depth | A picture of the screen, only when it has fewer than 8 readable labels or the model asks for one |
| Speech recognition (on-device where the phone supports it) | |
| Payment-screen and personal-information checks | |
| The test log | |

The personal-information check is basic: it looks for words such as "password" and for @ signs. It would not catch a screen that shows personal content in other ways.

The cloud key is built into the app. That is acceptable for a demo on the authors' own phone and not for distribution.

## How it compares with earlier work

| | Needs setup per device | Plans toward a goal | Checks each press | Guidance |
|---|---|---|---|---|
| Apple Magnifier "Point and Speak" | No | No, reads text under the finger | No | Speech |
| VizLens (research) | Yes: a reference photo labelled by crowd workers | No | No | Speech |
| StateLens (research) | Yes: videos of the device, plus crowd labelling | Yes, from a pre-built model of the device | Follows its pre-built state model | Speech |
| Nudge | No | Yes | Yes, by re-reading the screen | Stereo tones and speech; watch haptics planned |

This table reflects our reading of the published descriptions of those systems, not a side-by-side test.

## Honest limitations

- **Finger tracking is the weakest part.** If the hand hides the fingertip from the camera, tracking drops out. A LiDAR fallback was tried and switched off because it made tracking less steady. Holding the phone higher, so it looks down at the hand, helps.
- **Depth near the glass.** LiDAR is accurate to roughly a centimetre at this range, so Nudge cannot tell a finger 2 mm above the screen from one touching it.
- **Light.** Hand tracking failed often in a dim room and worked with the lights on.
- **Icon-only screens.** Nudge only accepts something as a touchscreen if it can see at least three pieces of text on it; without that rule it locked onto desks and other plain rectangles. A screen made up only of icons is therefore not found at present.
- **Framing.** If the camera is too close to see the panel's edges, Nudge can lock onto a smaller box inside it.
- **Speed.** Each step takes about 2 seconds to plan and 2 more to confirm the screen has settled.
- **Testing so far** has been on a photo of a microwave panel on a laptop and on a phone screen, not on a real appliance.

## Building

Requirements: a Mac with Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen), an iPhone with LiDAR.

1. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and add at least one key (OpenAI, Anthropic or Gemini).
2. Plug in the iPhone and run:

```bash
scripts/deploy.sh --phone-only
```

Leave off `--phone-only` to include the Apple Watch app. `scripts/sim.sh <folder>` builds for the simulator and screenshots each screen (layout only; the simulator has no camera).

`Tools/hand-finder-test/run.sh` runs the depth-based hand tracker on a synthetic scene.

## Design

Yellow on black, and dots. Both come from tactile paving, the raised yellow dots that guide blind pedestrians, and yellow on black is among the most legible pairings for low vision. The logo is the letter "n" in braille. The dot field on the task screen mirrors the audio guidance, so someone watching can follow what the user is hearing.
