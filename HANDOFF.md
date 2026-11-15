# Handoff: Saturday 14 November (last updated about 8:45 PM)

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

Measured on a recording, then changed. See the end of this section for what was built.

**How it was measured.** The app now has a recorder (Settings > Test tools > "Record tracking frames", on by default in this build). While guiding, it keeps camera frames, LiDAR depth and the tracker's answers in `Documents/track.bin` on the phone. `Tools/track-replay` replays that file on a Mac. Running Apple's hand tracker on the recorded frames on the Mac gave the same answer as the phone (482 of 800 frames against 483), so the replay can be trusted for testing changes.

**What the recording showed (two runs of "cook for 90 seconds", 800 frames):**

- When the whole hand is in the picture, the tracker is nearly perfect: on 9 and 0, only 2 to 8 frames were lost between the first and last sighting.
- The losses are long gaps on Start (16 frames in one run; 38, 19 and 22 in the other, each 2 to 4 seconds). In every one of those frames the finger is sharp and plainly visible, but the palm is off the edge of the picture. Apple's tracker needs to see the palm; with only a finger in view it reports nothing at all.
- Tried on the same frames, none better: allowing two hands, running on part of the picture, adding black or mirrored canvas around the picture.
- The phone offers ARKit no ultra-wide camera format, so a wider view is not available.
- LiDAR sees the bare finger very clearly in every lost frame looked at: a clean ridge 2 to 8 cm above the screen plane, with the screen itself flat within about 5 mm. Near the tip, where the finger meets the glass, the ridge fades out, so the depth outline ends a little short of the true fingertip.

**What was built from that (Saturday about 8:45 PM, installed, not yet tried on the phone):**

- `DepthFingerFinder`: finds the finger as a ridge in the LiDAR depth. Used on its own when Apple's tracker reports no fingertip, once it has held steady for a tenth of a second. On the recording it agrees with Apple's tracker to 2.7 mm at the median (10 mm at the 90th percentile), and brings the frames with a finger position from 483 to 644 of 800. On Start in the second run: 75 to 177 of 182 frames, longest loss 3.8 s down to 0.2 s.
- When Apple's tracker does see the fingertip, its point in the picture is now combined with the ridge's height. The old way read depth at the single fingertip pixel, which flips between finger and glass; the reported position jumped more than 8 mm in 26 of 433 frame pairs. With the ridge's height it is 1.
- Switch: `usesDepthFinger` in `PerceptionPipeline`. False returns to Apple's tracker alone.
- Known limits: nothing is reported while the hand moves fast (LiDAR smears, and the finder stays silent on purpose); with a finger pressed flat on the glass the ridge can end up to about 8 mm short of the tip; the sideways correction (`registrationShift`) was measured with one hand position and one phone.
- Not done: widening the framing coaching. Left as it is until the backup has been tried, since more coaching means more talking before each key.
- `Tools/track-replay/build.sh` builds the scoring tools (`ridgetest` is the one that produced the numbers above).

**The recording itself** is not in git (356 MB). A copy is on Nischal's Mac at `recordings/track1.bin`. The copy on the phone is deleted the next time the task screen opens.

## Before the demo

- Turn the recorder off by default (`TrackRecorder.init`, and the default in `SettingsView`).
- Not started: demo-safe mode, saved devices and voice shortcuts, shared appliance library, 3D spatial audio with head tracking, Transparency reminder, on-device planning, low-vision magnifier, translation. Nischal said there is no 8 PM freeze: the presentation is being made in parallel.
- `README.md` is out of date for the Watch, the aiming help and the height gate.
- Open questions in `QUESTIONS.md`: 1, 2, 5, 7.
- Watch sometimes goes quiet part-way through a task; not diagnosed.

## Pitch direction agreed today

After the mentor's feedback: Nudge is "the last arm's length". Navigation tools get a blind person to the door or the room; Nudge gets their hand onto the control. Stages: touchscreens now, then anything you need to touch (lift buttons, handles, switches), then a chest camera with wrist haptics as a wearable. The shared appliance library is the proposed moat. Market figures and the competitor list still need sourced research.
