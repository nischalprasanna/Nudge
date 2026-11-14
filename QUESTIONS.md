# Questions for the morning

Written overnight, Saturday 14 November. Everything here was decided without you so work could continue; each item says what I assumed and what changes if you disagree.

## Needs Nischal in the morning (in this order)

1. **Test the new build on the phone, lights on.** Open Nudge, press Start, point at the microwave panel photo, type or say "heat for 90 seconds". Screen-record it. This is the first look at the new interface with a live camera, and the first run of the new finger tracking.
2. **Try the finger-hidden case on purpose.** Point with your hand so the back of it hides your fingertip. The fingertip ring on the camera view turns dashed when Nudge is using the LiDAR fallback. Tell me whether the dashed ring sits on your hand, and how far off it is.
3. **Try a spoken goal.** Every test so far used a typed goal. Speech recognition has never run on the phone.
4. **Get to a real appliance.** Everything has been tested on a photo of a panel or on a phone screen. A photo never changes when pressed, so multi-step tasks have never been run.
5. **Install the Watch app.** The full build including the Watch app now signs and builds. With the Watch unlocked and near the phone, run `scripts/deploy.sh` (without `--phone-only`), then open Nudge on the Watch and use Settings > "Send a test tap to the watch".
6. **Decide on the skills** (question 1 below).

## Questions

### 1. Should the third-party UI skills be installed into your Claude setup?

- **Why it matters:** you asked me to download all the UI/UX skills from skills.sh. Installing them runs their installers and adds their instructions to every future Claude session on this Mac.
- **What I did instead:** I read the relevant ones and applied their guidance to the design without installing anything.
- **What I found:** three are plain design guidance and fine to install: `anthropics/skills` (frontend-design), `emilkowalski/skills` (emil-design-eng and apple-design), `vercel-labs/agent-skills` (web-design-guidelines, though it fetches its rules from a second repository each time it runs). Three I would not install without a closer look: `designed-by-ai/skills` design-mobile-apps is a client for a paid design service and sends your briefs to it; `leonxlnx/taste-skill` installs a hook that runs on every session exit and failed one of the site's security audits; `uizze.sh` ios-design installs from a website rather than a reviewable repository.
- **If you want them:** say which, and I'll install them with you watching.

### 2. Is the yellow-and-black dot design the direction you want?

- **Why it matters:** it is a strong look and it is everywhere in the app, including the logo and icon.
- **What I assumed:** yes. It comes from tactile paving and braille, yellow on black is one of the most legible pairings for low vision, and the dot field shows judges what the user is hearing.
- **If not:** colours and type live in one file (`Nudge/Design/Theme.swift`), so a different palette is a small change. A different motif is a bigger one.

### 3. Finger hidden by the hand: is the LiDAR fallback good enough, or do we change how the phone is held?

- **Why it matters:** this was your biggest complaint, and it decides how the blindfolded demo is staged.
- **What I did:** added a second tracker that finds the part of the hand nearest the glass from depth alone. It passes a synthetic test but has never seen real LiDAR data. When the fingertip really is hidden, it will report the knuckle, which may be 2 to 5 cm from where the finger lands.
- **What I'd also do:** hold or mount the phone higher, looking down at the hand, so the fingertip is visible past the knuckles. Nudge now says this after it loses the finger a second time.
- **If the fallback misbehaves:** it can be switched off in one line (`usesDepthFallback` in `PerceptionPipeline`), which returns to the previous behaviour.

### 4. Keep the "Closer" height check, or drop it?

- **Why it matters:** it caused the "closer, closer" problem while you were touching the screen.
- **What I did:** height is now measured against the screen right beside the finger, and a finger that has stopped approaching for 1.2 seconds is treated as touching. Untested.
- **If it still misbehaves:** I'd remove the check and say "Tap" as soon as the finger is over the button. Height would then only be used for the "Lift" warning.

### 5. Which features do we cut?

- **Why it matters:** feature freeze is 8 PM today, and tuning on a real appliance has to come first.
- **Not started:** 3D spatial audio with head tracking, on-device planning, saved devices and voice shortcuts, shared appliance library, low-vision magnifier, label translation, demo-safe mode, AirPods Transparency reminder.
- **My recommended order once the core loop works on a real appliance:** demo-safe mode (protects the demo), Watch haptics (already built), saved devices (makes the demo instant), then spatial audio. I'd describe the rest as planned rather than build them badly.
- **What I assumed overnight:** that you would rather have a core loop that works than more untested features, so I added only the test log, which is small and cannot break anything.

### 6. Is it acceptable that a picture of the screen can go to OpenAI?

- **Why it matters:** the pitch says "private".
- **What happens now:** button labels always go as text. A picture goes only when fewer than 8 labels can be read, and never when the labels include words like "password" or an @ sign. That check is basic.
- **If you want it stricter:** I can make pictures opt-in with a spoken question first.

### 7. Lighting

- **Why it matters:** hand tracking failed often in the dim purple light and worked with the lights on.
- **What I assumed:** the demo room will be lit.
- **If it might not be:** I can add an option to switch on the phone's torch, though it may cause glare on glossy panels.

## Things I did not do

- Did not install anything on the Watch, since you parked it.
- Did not install the third-party skills.
- Did not delete anything or rewrite git history.
- Did not create accounts or spend money. The only paid calls were a handful of GPT-6 Luna test requests earlier, with your key.
