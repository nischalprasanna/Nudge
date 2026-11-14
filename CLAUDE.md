# Nudge: build brief for Claude Code

You are the lead engineer on Nudge for the next ~30 hours. Read this whole brief before doing anything, then save it as `CLAUDE.md` in the repo root so every future session starts from it. Treat it as the source of truth for scope. Do not add features that are not listed here; if you think something is missing, ask me first.

---

## 1. Mission

Build **Nudge**: a native iPhone + Apple Watch app that lets blind and low-vision people operate touchscreen appliances (microwaves, ovens, thermostats, washing machines, coffee machines) that have no physical buttons.

The user points the phone at a touchscreen and says a goal, for example "heat for 90 seconds". Nudge reads the screen, plans the sequence of taps, guides the user's fingertip to each button with 3D spatial audio, voice and Apple Watch haptics, and after every tap re-reads the screen to verify the right thing happened, recovering if not.

The pitch line: "Physical buttons are disappearing and blind people are being locked out of their own kitchens. Nudge gets them back in."

## 2. Context you need

- This is for a 36-hour hackathon (Kearney PERLab x OTCR at UIUC). Two students. Submission is due **Sunday Nov 15, 8:30 AM Central**. Judging starts 9:30 AM.
- Judging criteria: Research and use of Velocity AI (handled outside this build), Commercial potential, Technical feasibility, Deliverable, Final pitch (~4 min + ~2 min Q&A).
- **The live demo is the deliverable.** A blindfolded teammate will use Nudge on a real touchscreen appliance in front of judges. Reliability in that moment beats everything else.
- Neither of us has written Swift before. You write the code; we test on devices and do the physical steps. Explain anything I must do in plain, numbered steps.
- Prior art the judges may raise, so build to clearly exceed it: Apple's Magnifier "Point and Speak" (reads text under a pointing finger; users report it fails on appliances), VizLens and StateLens (university research on guiding blind users on touchscreens; StateLens needed pre-recorded videos and crowd workers per device). Our edge: zero setup on a never-seen device, goal-directed planning, verified taps, multimodal guidance (spatial audio + watch), handheld robustness, privacy.

## 3. Hardware (all available)

- MacBook (Apple Silicon) with Xcode installed
- iPhone Pro with LiDAR (exact model unknown: detect it and tell me; it affects on-device AI availability)
- Apple Watch paired with that iPhone
- AirPods Pro / AirPods 3 or newer (head tracking supported)

## 4. Features: ALL of these are essential

Build every item below. None are optional. Order of work is in section 8.

### 4.1 Core guidance loop
1. **Zero-setup screen reading.** Point the phone at any touchscreen it has never seen. Identify every button and its label (text and icons). No photos to take, no crowd workers, no pre-mapping.
2. **Goal-directed task mode.** The user speaks a goal ("heat for 90 seconds", "set oven to 350", "popcorn"). Nudge breaks it into steps and walks through each tap.
3. **Real-time fingertip guidance.** Track the index fingertip continuously and guide it to the current target.
4. **Verify every action.** After each tap, re-read the screen and confirm the expected change ("Set to 1 minute 30. Say 'go' to start."). Speak the result.
5. **Error recovery.** If a wrong button was pressed or the state is unexpected, say what happened and how to fix it ("You pressed Defrost. Stop is at the bottom right, move down.") and replan.
6. **Works on changing screens.** Screens change after taps. Re-read after every step; never assume a static layout.
7. **Safety guardrails.** Extra spoken confirmation before risky actions: high oven temperatures, long cook times, anything that could cause harm or cost. **Payments are excluded entirely**: no payment flows anywhere in the app, and if a payment screen is detected, say Nudge does not handle payments and stop.

### 4.2 Handheld mode
8. The phone can be held in one hand and moved freely, or worn on a lanyard / chest mount, while the other hand reaches. Button positions must stay correct as the phone moves. Use ARKit world tracking to anchor the screen as a fixed plane in space.

### 4.3 Hover guidance with LiDAR
9. The user explores with the fingertip **hovering above the glass** and only touches on "tap now", so exploration never triggers buttons by accident.
10. Measure real fingertip-to-glass distance using LiDAR scene depth, and correct for **parallax** (the finger appearing over the wrong spot when viewed at an angle): project the fingertip onto the screen plane using the anchored screen pose, so the reported target position matches where the finger will actually land.
11. Give hover-height feedback ("a little closer", "too close, lift slightly") so the user keeps a safe hover distance.

### 4.4 Multimodal feedback
12. **3D spatial audio with AirPods head tracking.** The guidance tone should sound like it comes from the target button's real position in space and stay put as the user turns their head. Encode distance with beep rate (faster when closer) and use a distinct chime plus "tap" when on target.
13. **Stereo direction cues** as a simpler mode and fallback when head tracking is unavailable: left/right panning for horizontal offset, pitch for vertical offset.
14. **Voice instructions** ("left", "up a little", "tap now") as the beginner and fallback mode.
15. **AirPods Transparency compatibility.** Apps cannot switch AirPods noise modes, so when AirPods connect, remind the user by voice to turn on Transparency so they keep hearing their surroundings. Keep guidance sounds short and clear so they sit on top of real-world sound without masking it.
16. **Apple Watch haptics** on the reaching wrist: pulses that speed up as the finger approaches, a strong distinct buzz when on target, a "confirmed" pattern after a successful tap, a "wrong" pattern on error. Keep the watch app active during a task (extended runtime session). Must also work with audio off, so deafblind users can use haptics alone.
17. Users can choose which feedback channels are on (audio / voice / watch, any combination).

### 4.5 Intelligence and privacy
18. **On-device AI planning** using Apple's on-device foundation model where this iPhone supports it; otherwise fall back to the cloud model. Report which path is active.
19. **On-device text recognition** for reading labels wherever possible. Use the cloud vision model only for what on-device cannot do (icons, ambiguous layouts, goal-to-button mapping when on-device planning is unavailable).
20. **Private and offline-ready.** Screen reading runs on the device where possible. Never upload images of screens showing personal information. Call the cloud only when the screen state changes, not every frame.

### 4.6 Memory, sharing, accessibility modes
21. **My devices.** After the first use, save a device's layout on the phone so future use is instant, offline and private.
22. **Voice shortcuts** for saved devices, e.g. "heat my coffee" = Time Cook, 45 seconds, Start on "Kitchen microwave". Users create them by voice.
23. **Shared appliance library.** When a user learns a new device, its layout (button labels, normalized positions, screen states, device fingerprint; never camera images) can be shared anonymously to a cloud library, so the next user with the same model gets instant, more accurate guidance. Opt-in, with a clear spoken explanation. Pick a simple hosted backend you can set up quickly and tell me exactly what account steps I must do.
24. **Low-vision mode.** A magnified, high-contrast live view of the appliance screen with the current target highlighted, for users with some sight.
25. **Label translation.** Read button labels and instructions in the user's chosen language, even when the appliance is in another language (prefer Apple's on-device Translation framework where available).

### 4.7 Testing and demo support
26. **Built-in test logging.** Every task attempt logs: device, goal, steps, success/failure, time to complete, errors and recoveries, feedback channels used. Exportable as CSV (share sheet) so we can put real numbers on a slide.
27. **Demo-safe mode.** One switch that preloads a chosen saved device, uses cached AI results, avoids network calls during the demo, and keeps everything else working. If the network drops mid-demo, nothing should stall.

## 5. Technical direction (recommended defaults; improve them if you have a better approach)

| Concern | Recommended approach |
|---|---|
| App | SwiftUI iOS app + watchOS companion app |
| Project generation | XcodeGen (`project.yml`) so the .xcodeproj is generated and merges stay clean |
| Screen detection and anchoring | Vision rectangle detection on a frame, raycast corners into ARKit, anchor a plane |
| Fingertip | Vision hand pose (index tip), raycast onto the anchored screen plane |
| Hover | ARKit scene depth from LiDAR |
| Text | Vision text recognition on a rectified (perspective-corrected) screen image |
| Cloud AI | Anthropic API with a vision-capable Claude model; favor speed for interactive calls. Key read from `Config/Secrets.xcconfig` (gitignored). I will create the key; tell me when you need it |
| On-device planning | Apple Foundation Models framework if supported on this iPhone |
| Spatial audio | AVAudioEngine + AVAudioEnvironmentNode, head pose from CMHeadphoneMotionManager |
| Speech | Speech framework for input, AVSpeechSynthesizer for output |
| Watch | WatchConnectivity for messages, WKInterfaceDevice haptics, WKExtendedRuntimeSession |
| Translation | Apple Translation framework where available |
| Shared library | Simple hosted backend of your choice; layouts only, never images |

The app's own interface must be fully usable with VoiceOver: it is built for blind users.

## 6. Things only I (the human) can do

Tell me exactly when, in short numbered steps, and wait for my confirmation:
- Sign into Xcode > Settings > Accounts with my Apple ID (I type the password; never ask me for it).
- Tap "Trust This Computer" on the iPhone.
- Enable Developer Mode on the iPhone and the Apple Watch.
- Keep the Watch awake, unlocked and near the phone during installs.
- Create the Anthropic API key and paste it into `Config/Secrets.xcconfig`.
- Create any backend account for the shared library.
- Physically test on devices and report what happened.

Signing: automatic with my Personal Team. Use `xcodebuild -allowProvisioningUpdates` and `xcrun devicectl` to build, install and launch on the devices wherever possible so I do not have to click around in Xcode. Camera, AR, LiDAR, spatial audio and watch haptics do not work in the Simulator: everything must be tested on the real devices.

## 7. Engineering rules

- **Get to a working device build fast**, then grow it. Never leave the main branch in a broken state.
- Initialize git. Commit at every working checkpoint with a clear message. Tag the best demo-ready build.
- Parallelize where it helps: independent tracks (for example watch app, shared library backend, translation/low-vision) can be developed by subagents or in separate git worktrees, then merged. Keep one integration owner (you).
- Put each module behind a clear interface so a failing module can be switched off without breaking the core loop.
- Keep the API key and any backend secrets out of git.
- **Honesty:** no claims of certification, clinical validation or regulatory compliance anywhere in the app or README. Label estimates as estimates.
- Latency targets: guidance feedback updates at least 15 times per second; a cloud screen read completes in under ~3 s; never block guidance while waiting on the network.
- When something is ambiguous, choose the option that makes the live demo more reliable, and tell me what you chose.

## 8. Order of work and deadlines (all times Central)

| By | Milestone | Done when |
|---|---|---|
| Sat ~3 AM | **Bootstrap**: XcodeGen project with iOS + watchOS targets, installed on both devices | Pressing a button on the iPhone makes the Watch vibrate |
| Sat 9 AM (overnight) | Screen anchoring, fingertip tracking, hover depth, OCR pipeline written and compiling | Builds cleanly for device; ready for me to test in the morning |
| Sat 1 PM | **Core loop on device, handheld**: read screen, speak goal, plan, guide, tap, verify | Blindfolded teammate completes "heat for 90 seconds" on a real microwave |
| Sat 4 PM | Spatial audio + head tracking, stereo mode, voice mode, Transparency prompt, watch haptics, error recovery, safety confirmations, payment exclusion | All feedback channels work; a deliberately wrong tap is caught and recovered |
| Sat 6 PM | LiDAR hover + parallax correction, on-device planning, My devices + voice shortcuts, test logging + CSV export, demo-safe mode | Each works on device |
| Sat 8 PM | Shared appliance library, low-vision mode, label translation | Each works on device. **FEATURE FREEZE at 8 PM** |
| Sat 8 PM to Sun 8 AM | Bug fixes and stability only | The full demo runs 5 times in a row without failure |

If a milestone slips, tell me immediately with your plan to recover. Do not silently drop a feature.

## 9. Final deliverables

1. The app installed and working on the iPhone and Watch, with demo-safe mode ready.
2. A tagged git commit of the demo build.
3. `README.md`: what Nudge does, architecture diagram (text is fine), how each feature works, what is on-device vs cloud, honest limitations, and how it improves on Point and Speak, VizLens and StateLens.
4. Test logs exported as CSV.

## 10. Communication: questions, check-ins and overnight work

**When I am awake (default):**
- Check in with me whenever you have a question, hit a decision that changes scope or the demo, or need me to do something physical. Ask clearly and concisely, give your recommended answer, and wait for my reply on anything that matters. I will answer to the best of my ability.
- For small technical choices, decide yourself and tell me what you chose.

**When I tell you to work overnight:**
- Keep working autonomously through the milestones in section 8 without waiting for me. Do not stop to ask.
- Table every question, concern or decision for the morning instead. Record each one in `QUESTIONS.md` at the repo root with: the question, why it matters, the assumption you made to keep going, and what you would change if my answer differs.
- When a question blocks one task, make the most reasonable assumption that keeps the live demo reliable, note it in `QUESTIONS.md`, and move on to other work rather than idling.
- Anything that needs my hands (device taps, installs, API keys, accounts, testing on devices) goes into `QUESTIONS.md` under "Needs Nischal in the morning", in the order you need them done.
- Never take irreversible actions overnight (deleting work, rewriting git history, creating paid accounts, spending money).
- When I wake up and say I'm back: give me a short summary of what you finished, what is still in progress, and walk me through `QUESTIONS.md` one item at a time so I can answer.

## 11. Start now

1. Save this brief as `CLAUDE.md`.
2. Check the environment (Xcode version, Homebrew, XcodeGen, connected devices, iPhone model and whether on-device foundation models are supported).
3. Give me a short plan with the steps where you need me, then begin the bootstrap milestone.
