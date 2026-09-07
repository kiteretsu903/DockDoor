**Persistent full-size preview fixed locally — 2026-09-07**

Escape during the thumbnail's 0.3-second hover delay now dismisses the thumbnail without opening a large preview afterward. The signed debug build passed the same native pointer-and-Escape route that reproduced the baseline bug, plus timing-boundary and normal-hover controls. The fix and its regression evidence are maintained on the fork branch `bug/persistent-preview`.

**Behavior and implementation**

- `WindowPreview` cancels its timer on disappearance as well as hover exit and click actions.
- `SharedPreviewWindowCoordinator` issues an ID for each full-size hover. The view carries that ID through the timer and display request; the coordinator checks ownership and parent visibility when accepting the request and immediately before display. Dismissal or a new hover invalidates the previous ID.
- Card cleanup closes only the full-size preview belonging to that card's hover. A late disappearance callback from an older card cannot cancel a newer hover.
- General dismissal closes the large panel before checking the thumbnail's visibility. Escape also recognizes a visible large panel independently of the thumbnail.
- The full-size display branch keeps its valid ownership while replacing the child content. An unavailable target position no longer falls through into rendering a centered thumbnail panel.

Production changes are limited to `WindowPreview.swift`, `SharedPreviewWindowCoordinator.swift`, and `KeybindHelper.swift`. Existing investigation instrumentation remains behind `#if DEBUG`. The contribution leaves the upstream project file unchanged. Local debug signing retains the same certificate and bundle ID as the authorized investigation builds. Personal signing values are excluded from the published source snapshot and validation summaries.

**Native regression results**

Xcode 27 beta 6 built and launched the fixed app through Cmd+R. The input helper posted normal mouse-moved and Escape events. These trials used `observe` mode, with no injected display delays or direct preview show/hide calls.

| Route | Checks | Result |
| --- | ---: | --- |
| Enter Calculator thumbnail; Escape after 0.10–0.25 seconds | 7 | Timer canceled; no late full-size panel. |
| Escape around the dwell boundary: 0.28, 0.29, 0.30, 0.31, 0.32 seconds | 5 | No stuck panel. At 0.30–0.32 seconds the large preview appeared before Escape and was dismissed. |
| Leave the thumbnail after 0.15 seconds | 1 | Timer canceled; no large preview. |
| Sustained hover, then Escape | 2 | Normal large preview appeared and both panels closed; one run also received native screenshot verification. |
| Show another ordinary Dock preview between trials | 3 | Preview still opened and dismissed normally. |

All **18 checks passed**, with zero recorded states where the full-size panel was visible while the thumbnail was hidden. Each hover trial verifies that the pointer actually armed a timer; a missed target cannot count as a pass. Final panel states are checked for every trial. The baseline had reproduced the bug in all five early-Escape trials.

The separate controlled regression also passed: an accepted full-size request was suspended, the parent was dismissed, and the same request resumed. The new final guard rejected it (`full.displayRejected`), followed by `controlled.orphanNotObserved`. This validates the queued-request boundary separately from the natural UI route.

**Evidence and repetition**

- [Native trace](evidence/fixed-native-hover-2026-09-07.jsonl) and [validated results with source/plan hashes](evidence/fixed-native-hover-2026-09-07.json), PID 10859.
- [Queued-request trace](evidence/fixed-queued-preview-2026-09-07.jsonl) and [asserted result](evidence/fixed-queued-preview-2026-09-07.json), PID 11730.
- [Tested source snapshot](evidence/fixed-preview-source.patch).
- [Original bug and reproduction](natural-hover-trigger.md), including baseline logs.
- [Input replay tool](tools/hover_trial.py) and [native trace verifier](tools/verify_hover_trials.py).

Replay input requires the explicit `DOCKDOOR_PREVIEW_INPUT=1` flag in the trace scheme. Refresh native geometry first: saved coordinates are specific to this display/Dock layout. Remove the flag and restart after testing. The current handoff uses passive logging only; see [the run guide](preview-race-debug-run.md).

The native coverage above verifies the demonstrated route and display scheduling boundary. It does not claim exhaustive testing of every Space, display layout, application, or window-switcher feature. Existing `WindowUtil` Swift 6 locking warnings and Xcode editor notices are unrelated to this change.
