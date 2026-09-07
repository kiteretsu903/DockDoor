**Baseline reproduction — dismiss a thumbnail before its hover timer fires**

The local fix now passes this route and its timing controls. See [the fix and regression report](persistent-preview-fix.md). The results below describe the unfixed baseline.

With “Present a full size preview of the window” and the existing 0.3-second hover delay, entering a thumbnail and pressing Escape before that delay finishes leaves a persistent large preview. The pointer must remain over the thumbnail until Escape closes it. This reproduced in all five early-Escape trials using normal macOS input, with forced preview scheduling disabled.

**Manual reproduction**

1. Hover Calculator's Dock icon until its thumbnail appears.
2. Move onto the thumbnail image.
3. Immediately press Escape, roughly 0.1–0.25 seconds after entering, without moving the pointer first.
4. The thumbnail disappears. Its large preview then appears after the remainder of the hover delay.
5. Move away or press Escape again: the large image remains. Open an ordinary Dock preview to clear it.

This is a narrow window in ordinary use, which explains why it can feel random. The test establishes one real UI trigger matching the symptom and recovery. It does not establish that every earlier unrecorded occurrence used Escape.

**What the natural trace proves**

The first natural run recorded the same hover ID through this sequence:

| Time from entering the thumbnail | Event |
| ---: | --- |
| 0 ms | Hover timer armed. |
| 146 ms | Escape handled through the application's normal key handler. |
| 147 ms | Thumbnail card disappeared with its hover ID still present. |
| 155 ms | Parent dismissal finished; both panels hidden. |
| 301 ms | That card's timer was accepted despite the parent being hidden. |
| 317 ms | The full-size panel appeared with no visible parent. |

The first orphan remained visible for about 69.8 seconds until a normal Calculator Dock preview cleared it. An intervening Escape did not clear it. Native screenshots confirmed the large Calculator image after the small panel disappeared.

The decisive point is **before** the coordinator's asynchronous display handoff: the timer fires after its source card is gone and submits a new full-size request. Canceling a pending display during Escape cannot cancel a request that has not been submitted yet. The earlier controlled queue-ordering experiment identified another possible lifetime gap, but that queue race is unnecessary for this demonstrated trigger.

**Root cause in the baseline source**

- `WindowPreview` cancels `fullPreviewTimer` and clears `fullPreviewHoverID` on hover exit and click/action callbacks. Removing the card has no corresponding cleanup.
- `hideWindow()` removes the thumbnail content without invalidating that card's timer. The surviving timer's UUID check still passes.
- The full-size `showWindow` path accepts the request even when its originating thumbnail panel is already hidden.
- General dismissal returns early when the thumbnail panel is hidden, before closing its separate full-size child. Escape is also gated by the parent visibility snapshot, so it does not dispatch its usual dismissal for an orphan alone.
- Successfully rendering another ordinary preview calls `hideFullPreviewWindow()` before displaying the new content, which explains and reproduces the recovery.

Baseline line references and the wider code audit are in [the investigation](persistent-full-size-preview.md).

**Confirmation and controls**

| Trial | Result |
| --- | --- |
| Escape after approximately 0.10, 0.15, 0.20, and 0.25 seconds | 4/4 persistent orphan previews. |
| Move out after approximately 0.15 seconds, before pressing Escape | Hover canceled; no late full-size preview. |
| Wait approximately 0.55 seconds, then press Escape | Full-size preview had already appeared; Escape dismissed both panels normally. |
| Remove the diagnostic `onDisappear` modifier, rebuild, and repeat early Escape | Reproduced again, with a second native screenshot. |
| Open a new ordinary Dock preview | Removed the orphan; final test UI cleanup verified. |

The final baseline confirmation preserved the original SwiftUI view structure. In that saved instrumentation snapshot, all five modified Swift files produced source identical to the committed baseline after DEBUG sections were removed. In `observe` mode, the full-size display path does not call or await the controlled suspension. The helper posts actual mouse-moved and Escape events; it never calls preview show/hide methods directly. Normal logging and synthetic input replay remain instrumentation, so these results are a reproducible UI sequence rather than a recording of a historical spontaneous incident.

**Evidence and repeatability**

- [First natural trace and controls](evidence/natural-hover-escape-2026-09-07.jsonl), [validated summary](evidence/natural-hover-escape-2026-09-07.json).
- [Confirmation without the view observer](evidence/natural-hover-escape-no-view-observer-2026-09-07.jsonl), [validated summary](evidence/natural-hover-escape-no-view-observer-2026-09-07.json).
- [Input plans for the controls](evidence/DockDoor-natural-controls.json) and [observer-free confirmation](evidence/DockDoor-natural-no-disappear-observer.json). Coordinates belong to this machine and layout; refresh them before reuse.
- [First-run instrumentation snapshot](evidence/natural-hover-instrumentation.patch) and [observer-free snapshot](evidence/natural-hover-no-view-observer-instrumentation.patch). Summaries retain the exact source and log hashes.

The user authorized the [bounded pointer helper](tools/hover_trial.py). Because the Python process had no input-posting permission, the helper sends its plans to the already-authorized, certificate-signed debug app. The app validates a maximum of 120 steps and 30 seconds per plan, limited to movement, Escape, and waits. Input handling requires `DOCKDOOR_PREVIEW_RACE=observe` and `DOCKDOOR_PREVIEW_INPUT=1`. The input flag is removed from the handoff scheme, so the remaining run is passive. The `--targets` request exports only the test Dock icons, screen geometry, and the app's preview frame to `/tmp/DockDoor-InputTargets.json` while the input flag is enabled.

Xcode Beta built every app revision through the GUI. Local Debug signing retains the same Apple Development certificate and bundle ID; those personal settings are excluded from the contribution. Accessibility and screen-capture grants survived rebuilds. Only the signed debug copy is left running; the installed stable copy is stopped. See [the run guide](preview-race-debug-run.md) for the current passive log path.

**Local correction verified**

The fix cancels the timer on card disappearance, carries coordinator-owned hover IDs through display, rejects expired requests, and dismisses the full-size panel independently of parent visibility. The same native route and its controls pass. See [the fix report](persistent-preview-fix.md) for the complete regression results and evidence.
