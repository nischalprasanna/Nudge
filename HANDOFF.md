# Handoff: Saturday 14 November, about 6:15 PM

Written when work moved from Nischal's Mac to another laptop. Read `CLAUDE.md` first (the brief), then this.

## Setting up on another Mac

1. Install Xcode 27 and XcodeGen (`brew install xcodegen`).
2. Clone the repository.
3. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and put the keys in. The keys are not in git. Move them between laptops by AirDrop or a password manager, not by chat or email.
4. Signing uses Nischal's Personal Team (`33847454LD` in `project.yml`). Either sign into Xcode > Settings > Accounts on the new Mac with Nischal's Apple ID, or change `DEVELOPMENT_TEAM` and the bundle identifier to the other person's. Changing them installs a second copy of the app with empty settings and logs.
5. Plug in the iPhone, unlock it and tap "Trust This Computer".
6. `scripts/deploy.sh --phone-only` builds, installs and launches. Leave off `--phone-only` to include the Watch.

## What works (all on the iPhone, repeated several times today)

- Finds and anchors the iPad "microwave" panel, reads its keys, plans "cook for 90 seconds" as 9, 0, Start, guides the finger, checks each press, announces the result.
- Spoken aiming help while looking for the screen, and "tilt the phone down" coaching before keys low in the picture.
- Apple Watch: beat that quickens as the finger closes in, on-target, confirmed and wrong buzzes.
- "Tap" is held back while the finger is more than about 7 cm from the glass (installed, not yet confirmed by a test).
- Chest mode gives directions as body movements ("Lean forward a little"). Installed, untested.

## Finger tracking: what was found, and what to do next

This was the task in progress. Nothing in the tracking has been changed yet.

**How it was measured.** The app now has a recorder (Settings > Test tools > "Record tracking frames", on by default in this build). While guiding, it keeps camera frames, LiDAR depth and the tracker's answers in `Documents/track.bin` on the phone. `Tools/track-replay` replays that file on a Mac. Running Apple's hand tracker on the recorded frames on the Mac gave the same answer as the phone (482 of 800 frames against 483), so the replay can be trusted for testing changes.

**What the recording showed (two runs of "cook for 90 seconds", 800 frames):**

- When the whole hand is in the picture, the tracker is nearly perfect: on 9 and 0, only 2 to 8 frames were lost between the first and last sighting.
- The losses are long gaps on Start (16 frames in one run; 38, 19 and 22 in the other, each 2 to 4 seconds). In every one of those frames the finger is sharp and plainly visible, but the palm is off the edge of the picture. Apple's tracker needs to see the palm; with only a finger in view it reports nothing at all.
- Tried on the same frames, none better: allowing two hands, running on part of the picture, adding black or mirrored canvas around the picture.
- The phone offers ARKit no ultra-wide camera format, so a wider view is not available.
- LiDAR sees the bare finger very clearly in every lost frame looked at: a clean ridge 2 to 8 cm above the screen plane, with the screen itself flat within about 5 mm. Near the tip, where the finger meets the glass, the ridge fades out, so the depth outline ends a little short of the true fingertip.

**Next steps, in order:**

1. Write a backup finder that is used only when Apple's tracker reports no hand: take the LiDAR points above the screen plane that connect to the edge of the picture, and report the end of that shape furthest from where it enters. Correct for the tip falling short (extend along the finger's direction, or refine with the camera picture). Measure it with the replay tool against frames where Apple's tracker does see the finger, so its error is known before it ships. An older attempt at this (`DepthHandFinder`, switched off) reported the knuckle nearest the glass and jumped; do not just switch that back on.
2. Widen the framing coaching so the palm stays in view: the hand comes from the bottom right, so the key should end up no lower than about half way down and not far right of centre. The rule today only asks for 60% down.
3. Check the suspected jitter source: `locateFinger` in `PerceptionPipeline` switches frame by frame between a LiDAR-corrected position and a plain camera-line position. The recording has what is needed to measure this.

Keep every change behind a switch, and test it on the recording before installing it. Changes to tracking made without that today were reverted three times.

**The recording itself** is not in git (356 MB). A copy is on Nischal's Mac at `recordings/track1.bin`. The copy on the phone is deleted the next time the task screen opens.

## Before the demo

- Turn the recorder off by default (`TrackRecorder.init`, and the default in `SettingsView`).
- Not started: demo-safe mode, saved devices and voice shortcuts, shared appliance library, 3D spatial audio with head tracking, Transparency reminder, on-device planning, low-vision magnifier, translation. Nischal said there is no 8 PM freeze: the presentation is being made in parallel.
- `README.md` is out of date for the Watch, the aiming help and the height gate.
- Open questions in `QUESTIONS.md`: 1, 2, 5, 7.
- Watch sometimes goes quiet part-way through a task; not diagnosed.

## Pitch direction agreed today

After the mentor's feedback: Nudge is "the last arm's length". Navigation tools get a blind person to the door or the room; Nudge gets their hand onto the control. Stages: touchscreens now, then anything you need to touch (lift buttons, handles, switches), then a chest camera with wrist haptics as a wearable. The shared appliance library is the proposed moat. Market figures and the competitor list still need sourced research.
