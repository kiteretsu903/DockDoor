**Preview diagnostic — local fix and native regressions verified, 2026-09-07**

A natural UI trigger is now verified: enter a thumbnail and press Escape before the 0.3-second hover delay finishes, without first moving off the card. All five early-Escape trials reproduced a persistent large preview; pointer-exit and late-Escape controls dismissed normally. The final positive trial removed the view-lifecycle observation modifier. See [the natural-trigger report](natural-hover-trigger.md) for the current finding and normal-input evidence. The earlier forced-ordering experiment remains documented below. The local correction now passes 18 native checks and the queued-request regression; see [the fix report](persistent-preview-fix.md). The fix and regression artifacts are maintained on the fork branch `bug/persistent-preview`; no release was created. The evidence section below preserves the earlier baseline reproduction.

**Evidence**

- [Complete successful process trace](evidence/preview-race-controlled-2026-09-07.jsonl), PID 2874.
- [Validation summary and source/log hashes](evidence/preview-race-controlled-2026-09-07.json).
- Native DockDoor screenshot in this task's conversation, taken during the orphan inspection interval. It shows a frozen Xcode window as the large preview; DockDoor's accessibility tree reports a separate system-dialog surface.

The trace records parent hidden at 0.914 seconds, full-size panel visible with parent hidden at 1.463 seconds, survival of another `hideWindow()` call at 1.782 seconds, and successful direct cleanup at 16.982 seconds. The accepted request ID remains the same through those events. A later ordinary hover in this process displayed and dismissed normally.

Checks passed for event ordering, request identity, panel visibility, final cleanup, and both permissions. Source comparison after removing DEBUG sections was identical to the committed baseline in the saved baseline instrumentation snapshots; current source also contains the production fix. Xcode built successfully; existing Swift 6 locking warnings in `WindowUtil` and editor macro/recommended-settings notices remain unrelated to this diagnostic. No CLI build commands were used.

**Repeat through Xcode Beta**

Open `DockDoor.xcodeproj` in Xcode 27.0 beta 6. Keep only one DockDoor process running. Choose one of the shared schemes:

| Scheme | Behavior |
| --- | --- |
| `DockDoorPreviewRace` | `controlled` mode with startup driver enabled. Forces one diagnostic ordering; the fixed app must reject the expired request. Old unfixed snapshots clean up an orphan after 15 seconds. |
| `DockDoorPreviewTrace` | `observe` mode. Records actual events during normal use; no forced display, deliberate wait, forced dismissal, or timed cleanup. |
| `DockDoor` | With diagnostic environment variables unset, the probe is disabled. |

Run with Cmd+R. The diagnostic schemes pass temporary launch arguments for the full-size hover action, 0.3-second dwell, zero fade-out, normal Dock hiding, and disabled automatic update checks. They do not write those overrides to the user's saved preferences.

The controlled startup driver waits three seconds for startup/window discovery, selects an eligible Xcode window, drains queued activation notifications, shows its thumbnail, and submits the full-size request through the same coordinator entry point used by hover. It bypasses the actual pointer dwell/timer stage. The full-size task pauses for 0.2 seconds, calls the real parent `hideWindow()`, waits another 0.5 seconds for teardown, and then attempts display through the ownership guard. The fixed app rejects that expired request. After 0.3 seconds it checks for an orphan and calls normal `hideWindow()` again. If the orphan survives, it leaves 15 seconds for inspection and then calls `hideFullPreviewWindow()` directly. Avoid other preview activity during this short experiment.

For the fixed app, expected events are `controlled.pause`, `controlled.resume`, `full.displayRejected`, and `controlled.orphanNotObserved`. The unfixed baseline instead produced `controlled.orphanObserved`, `controlled.survivedHide`, and `controlled.cleanup`. A missing parent, missing eligible window, interruption, or missing result makes a run inconclusive. Only one request per process is controlled; relaunch to repeat.

`DebugPreviewRaceProbe.runFromDebugger()` remains available when stopped in an app Swift frame, but the startup scheme is preferable: pausing a process with global input hooks interfered with debugger input during an earlier attempt. An initial attempt was canceled before the parent appeared; another paused session had to be stopped along with its attached debugserver. Neither was counted as a reproduction. Xcode Beta resolved the earlier stable-Xcode launch incompatibility.

**Stable debug signing and permission verification**

The app's Debug configuration is pinned to the existing Apple Development certificate with SHA-1 `CE1C653F6BFA542C339BCAF62294580BD63B85D7`, team `C2W74C8UVK`, and bundle identifier `com.ethanbills.DockDoor.debug`. Keep this certificate and bundle identifier for subsequent local debug builds; do not switch back to ad-hoc signing. Release signing is unchanged.

The built app's signature and designated requirement were inspected. Inside PID 1641, LLDB returned `AXIsProcessTrusted() == true` and `CGPreflightScreenCaptureAccess() == true`. After rebuilding with the same certificate, PID 2874 recorded both grants again, without a new grant between those two checked runs. This verifies permission retention for this rebuild; it is not a guarantee against future macOS permission resets or certificate expiry.

The installed `/Applications/DockDoor.app` is separately signed by the upstream developer and requested its own Accessibility permission when reopened. The user chose to leave the signed debug copy running. The installed copy was quit.

**Handoff snapshot after native validation, 2026-09-07**

The only DockDoor process left running after the fix and regression tests is PID 12055, launched from Xcode with `DockDoorPreviewTrace`. The forced startup scenario and input-replay flag are disabled. Its startup log records `session.observe` and granted Accessibility and Screen Recording access. Both preview panels are hidden, and DockDoor remains running in the menu bar. The same signing certificate was verified again.

Current passive log:

`/tmp/DockDoor-PreviewRace-12055-CD84EACF-01B6-4634-9B3F-C1F42E306D4A.jsonl`

This path belongs to the current process; the filename changes after a relaunch. Relaunch using the trace scheme to keep passive recording enabled. Launching the app normally without the environment variable disables this diagnostic logging.

**Capturing the random occurrence**

Each process announces `/tmp/DockDoor-PreviewRace-<pid>-<uuid>.jsonl` in the Xcode console. Logs contain monotonic elapsed times, wall-clock timestamps, event names, opaque request/hover IDs, window IDs, parent/full-size visibility, pointer-inside-frame checks, parent opacity, and switcher state. They contain no window titles, screenshots, or document paths. Files are written through a serial background queue. Earlier controlled logs can begin with a sub-microsecond negative elapsed value due to lazy timestamp initialization; current logs clamp that initial value to zero.

If the preview sticks during ordinary use, note the time and which action immediately preceded it. Then use the usual new-preview action to clear it. The passive log can distinguish a late request after parent dismissal from a case where the thumbnail itself remains visible. Logging can affect timing slightly. `observe` does not inject the suspension used in the controlled test.

The controlled result alone establishes persistence when supplied an injected ordering. Subsequent normal-input trials identify a real trigger earlier in the lifecycle: card removal leaves its hover timer alive, and the timer submits the full-size request after parent dismissal. Those trials also verified that a newly rendered ordinary preview removes the orphan. The separate queue handoff remains a possible exposure rather than the demonstrated trigger. The input replay bridge is separately opt-in through `DOCKDOOR_PREVIEW_INPUT=1`; the handoff run has that flag disabled.

The fixed queued-request regression is archived in [its trace](evidence/fixed-queued-preview-2026-09-07.jsonl). Native input replay results and a repeatable trace verifier are linked from [the fix report](persistent-preview-fix.md).
