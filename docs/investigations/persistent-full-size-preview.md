**Persistent full-size hover preview — investigation, 2026-09-07**

An ordinary UI sequence now reproduces the problem: enter a thumbnail, press Escape before its 0.3-second hover delay finishes while keeping the pointer on the card, then move away. The card disappears without canceling its timer; that timer subsequently opens a full-size preview with no visible parent. All five early-Escape trials reproduced the orphan, including a rebuilt run without a view-lifecycle observation modifier. Pointer exit before the timer and Escape after full-size display were negative controls. Opening a new ordinary Dock preview cleared the obstruction. See [the natural-trigger report](natural-hover-trigger.md) for manual steps, native traces, controls, and evidence. The local correction now passes the demonstrated route and timing controls; see [the fix report](persistent-preview-fix.md). The code analysis below describes the committed baseline.

**Scope and baseline**

- Branch: `bug/persistent-preview`, commit `d2a8e2bb388c7664f28b7b844e2de60380ac8c31`.
- The user confirmed that the persistent surface is the large full-size preview, with “Present a full size preview of the window” enabled, on latest stable.
- The installed `/Applications/DockDoor.app` reports version/build `1.40.1`. This identifies the installed bundle, not a verified running process.
- The `1.40.1` tag resolves to `95708edc19d69dc0fbd828977d2e209f4e1af93a`. `WindowPreview.swift`, `SharedPreviewWindowCoordinator.swift`, and `WindowDismissalContainer.swift` are unchanged between that tag and the committed baseline. Subsequent DEBUG instrumentation and the local correction are separate from that comparison.
- Read-only inspection of saved preferences found `previewHoverAction = previewFullSize`, `tapEquivalentInterval = 0.3`, `fadeOutDuration = 0`, `preventPreviewReentryDuringFadeOut = true`, and `preventDockHide = false`. There was no explicit saved `inactivityTimeout`; the source default is 0.2 seconds. These are saved preferences, not an in-process settings snapshot.

Line references below are relative to this commit. Paths beginning with `Hover/` abbreviate `DockDoor/Views/Hover Window/`.

**Request lifetime and cleanup defects**

1. **Full-size requests can outlive their source hover or card.**

   The demonstrated natural trigger begins before the display request is even queued. Escape removes the card, but its timer is not canceled. The timer later passes its hover UUID check and calls `showWindow` with the parent already hidden. That native sequence establishes the missing card-removal cleanup; it does not require the additional queue race described below.

   `Hover/WindowPreview.swift:937–955` creates a hover UUID and checks it when the 0.3-second timer fires. It then calls `showWindow`, passing neither that UUID nor a source-card identity. The full-size request supplies no Dock item or bundle identifier.

   `Hover/Shared Components/SharedPreviewWindowCoordinator.swift:1067–1109` still schedules a `DispatchWorkItem` even when `overrideDelay` makes the delay zero. That work item subsequently creates a separate `Task { @MainActor ... }` at line 1104. Neither the task nor the display function revalidates the original hover or checks that its thumbnail panel is still visible. The Dock validation does not protect this request because its `bundleIdentifier` is nil.

   On hover exit, `WindowPreview.swift:918–923` invalidates the timer and UUID and closes an already-created full-size panel. It does not cancel the queued coordinator request. Even the broader `hideWindow()` cancellation only reaches the `DispatchWorkItem`, not a task that the work item has already created. Apple's [DispatchWorkItem cancellation documentation](https://developer.apple.com/documentation/dispatch/dispatchworkitem/cancel()) confirms that cancellation does not stop work that has already begun.

   Consequently, both of these boundaries matter:

   - Timer fires → hover ends → queued display runs: an unwanted full-size panel can appear after hover exit. If its parent remains visible and dismissal continues working, a later parent dismissal can still clean it up. This ordering alone does **not** establish permanent persistence.
   - Work item creates its task → parent is dismissed → task displays the full-size panel: the child can be recreated after the parent's cleanup has already completed. There is no request/session validation at the final display boundary to reject it.

2. **Cleanup depends on the wrong window's visibility.**

   `Hover/Shared Components/SharedPreviewWindowCoordinator.swift:186–217` implements general dismissal in this order:

   ```swift
   cancelPendingShow() // conditional
   restoreDockAutoHideState()
   guard isVisible else { return }
   DragPreviewCoordinator.shared.endDragging()
   hideFullPreviewWindow()
   // Remove thumbnail content, clear state, order thumbnail panel out.
   ```

   Here `isVisible` belongs to the coordinator's thumbnail/switcher `NSPanel`. The large preview is a different `NSPanel`, stored in `fullPreviewWindow` at line 26. A state of `thumbnail hidden / full-size visible` therefore causes every subsequent `hideWindow()` call to return before touching the visible child.

   `performShowWindow` at lines 831–838 can produce precisely this state: its full-size branch creates the child without requiring or showing the parent. That branch also bypasses the `setShowing` call in `updateContentViewSizeAndPosition`; `fullWindowPreviewActive` is not a reliable record of this child's visibility.

**Why the obstruction can remain indefinitely**

The large panel has `hidesOnDeactivate = false` (`SharedPreviewWindowCoordinator.swift:487`). Its `FullSizePreviewView.swift:13–25` contains image/live-image presentation and has no independent hover-exit or dismissal timer. The inactivity tracker belongs to the thumbnail's content (`WindowPreviewHoverContainer.swift:350–363` and `WindowDismissalContainer.swift:89–106`); after removal it no longer has a window to dismiss.

Application activation and Space changes call the same `hideWindow()` function (`DockDoor/Utilities/Window Management/WindowManipulationObservers.swift:178–205`), so those routes inherit the early-return defect. Escape is also gated by the thumbnail's visibility snapshot in `DockDoor/Utilities/KeybindHelper.swift:973–988`; the snapshot can say invisible while `fullPreviewFrame` is non-nil. The full-size view has no click action of its own, consistent with a picture obstructing interaction with the real window beneath it.

Opening a new ordinary window preview takes `performShowWindow` through its unconditional `hideFullPreviewWindow()` at line 831 **before** rendering the next preview. That is a direct explanation for the reported recovery. This refers to a successfully rendered ordinary window preview; not every Dock hover or standalone widget necessarily takes that route.

**Card-removal exposure — confirmed by natural input**

`WindowPreview` has no `.onDisappear` cleanup for its full-preview timer or hover ownership. Current cancellation relies on hover-ended events and particular click/action callbacks. Parent dismissal, replacement of hosted cards, or a change from an image card to a compact card does not explicitly cancel that card's full-preview request. AppKit-hosted cards are removed/replaced in `Hover/WindowPreview Supporting/CardGridScrollView.swift:201–230`.

The early-Escape tests now confirm this route: `hover.cardDisappeared` retained the same hover UUID, `parent.hide.return` showed the parent hidden, and `hover.timerAccepted` subsequently accepted that UUID. Removing the diagnostic `onDisappear` modifier and repeating the sequence reproduced the same orphan. A coordinator-owned request token would address both this confirmed lifetime problem and the separate queue exposure.

**Further candidate reproductions beyond the confirmed Escape sequence**

Keep the existing full-size hover action, 0.3-second delay, and zero fade-out. Use an ordinary application window with a valid thumbnail; compact/windowless cards do not run this full-size hover path.

1. Hover its Dock icon until the thumbnail panel appears.
2. Enter a thumbnail and move out onto the desktop around the 0.3-second threshold. Vary the dwell time across approximately 0.25–0.4 seconds. Move well outside both the thumbnail panel and Dock icon.
3. In a second series, click that thumbnail around the same threshold, so activation and parent dismissal race with full-size display. An immediate click long before the threshold is a useful negative control because the existing timer cancellation should cover it.
4. Wait at least two seconds without hovering another Dock item. A candidate failure is the large image remaining after the small panel disappears, with the pointer away from the Dock and thumbnail.
5. Record whether moving the pointer farther away, activating another app, or Escape dismisses it. Then show another ordinary window preview and record whether that clears it.

Run a small bounded series, such as 30 attempts per variation. Failure to reproduce does not disprove the source defect: the unmodified queue handoff can be very short, and the actual scheduling distribution has not been measured. A third variation is switching Spaces or dismissing the parent while the thumbnail dwell timer is pending; this probes the missing view-removal cancellation separately.

**Controlled debug experiment — reproduced on native AppKit**

Xcode 27.0 beta 6 built and ran the opt-in `DockDoorPreviewRace` scheme through the GUI. The successful process was PID 2874. A startup driver selected an existing Xcode window with a captured image, showed its ordinary thumbnail through `showWindow`, and submitted the same `.fullWindowPreview` coordinator request used by a thumbnail's hover timer. This driver bypasses the human hover and timer stage. Inside the accepted full-size task, the probe waits 0.2 seconds, calls the actual `hideWindow()`, lets teardown callbacks drain for 0.5 seconds, and resumes the original display implementation.

The [recorded JSONL trace](evidence/preview-race-controlled-2026-09-07.jsonl) shows:

| Elapsed seconds | Native state/event |
| ---: | --- |
| 0.694 | Full-size task accepted while the thumbnail panel was visible. |
| 0.914 | `hideWindow()` returned with both panels hidden. |
| 1.463 | The same queued request displayed the full-size panel while the thumbnail stayed hidden. |
| 1.782 | Another actual `hideWindow()` call returned with the full-size panel still visible. |
| 16.982 | The diagnostic's direct `hideFullPreviewWindow()` cleanup removed it. |

Computer Use captured the DockDoor-owned full-size panel during the inspection interval: it showed a frozen Xcode image, while DockDoor's accessibility tree identified a separate system-dialog surface. A later inspection showed the settings window after cleanup. A subsequent ordinary hover in the same process generated `hover.armed`, `hover.timerAccepted`, full-size display, and `hover.cancel`; that occurrence dismissed normally.

This earlier experiment confirmed persistence under an injected ordering. Its suspension is not present in production, so it did not establish a natural trigger by itself. The subsequent [normal-input trials](natural-hover-trigger.md) confirmed the card-disappearance timer route without relying on that suspension and verified recovery through another ordinary Dock preview. The separate queue gap remains a source-level exposure. Passive `observe` mode neither calls nor awaits the controlled suspension.

For the natural trace, record monotonic timestamps and opaque request/card/session IDs at hover enter/exit, timer fire/cancel, display request/enqueue/task entry, parent hide entry and completion, and child show/hide. Include parent/child visibility, pointer-inside-parent status, selected preview ID, and the cancellation reason. Add a marker on source-card disappearance. Window titles, captured images, and document paths are unnecessary.

The decisive sequence to look for is:

```text
full-size request for hover H accepted
hover H ends and/or parent session ends
parent hide completes
full-size request H displays anyway
later hideWindow returns because the parent is hidden
```

If a live failure instead has the thumbnail still visible, inspect its inactivity tracker, Dock selection, and switcher guards. That would mean the orphan-child path does not fully explain that particular occurrence.

**Other paths reviewed and their relevance**

| Path | Finding and implication |
| --- | --- |
| Thumbnail fade/reentry | Its opacity and timer state deserve separate testing, but the saved fade duration is zero and the reported stuck surface is the large panel. An overlapping fade animation is not needed for the defect above. |
| Dock selection | `WindowDismissalContainer.swift:109–129` treats AX selected-item equality as continued Dock hover, without a geometry check. Apple's [AXSelectedChildren documentation](https://developer.apple.com/documentation/applicationservices/kaxselectedchildrenattribute) describes selection, not a pointer hit-test. Whether selection remains stale on the user's system was not measured. This could keep the thumbnail open, but is not required for the orphan-child explanation. |
| Hover tracking | `mouseIsWithinPreviewWindow` is maintained by thumbnail entered/exited callbacks. It is neither a full-size request token nor validated by the full-size display path. |
| Cmd+Tab / switcher | The thumbnail fade code skips dismissal while switcher flags are set. Cmd+Tab has additional observer/keyboard cleanup. No stuck switcher flag was observed, and it is not required for the identified path. |
| Dragging | The thumbnail removes its dismissal overlay during a preview drag. Missing gesture completion could affect thumbnail lifetime; the user reports ordinary hovering and a large preview, so this is secondary. |
| Window discovery/cache | Dock refresh results merge into the current panel rather than directly creating a full-size preview. They can change card lifetime, but do not remove the full-size cancellation gap. |
| Run-loop timers | Scheduled timers use the default run-loop mode, so menu/drag tracking can delay them. [Apple Timer documentation](https://developer.apple.com/documentation/foundation/timer/scheduledtimer(withtimeinterval:repeats:block:)). Delay by itself does not explain a permanently orphaned full-size panel after normal event processing resumes. |

**Prior upstream work**

Upstream [issue #973](https://github.com/ejbills/DockDoor/issues/973) reported a full-size preview appearing after a thumbnail click. Commit [f51abe8](https://github.com/ejbills/DockDoor/commit/f51abe8d7bf9d078a86fea48483143aa73a10b72) added the timer UUID and click cancellation now present in this source. That protects the stage before the request enters `showWindow`, but the UUID is not propagated through the coordinator's subsequent queue/task boundaries. This is a source-level limitation of that fix, not proof that every later report shares the same cause.

**Fix direction recorded after baseline reproduction**

The correction needs both cancellation and unconditional child cleanup. Give full-size hover requests explicit ownership of a thumbnail session and card, invalidate that ownership on hover end, source removal, parent dismissal, and session replacement, and revalidate it immediately before creating the panel. Keep this separate from unrelated pending Dock previews so cancelling one thumbnail hover does not accidentally cancel a legitimate transition to another app.

General dismissal should always close auxiliary full-size/search surfaces before any return based on parent visibility. Repeated dismissal must remain safe. A visibility flag alone is insufficient: an old request can otherwise display over a newly opened parent session. Request generation plus source identity matters.

The baseline investigation proposed that fix validation cover cancellation before the timer fires, after enqueue, and after the task is created; source-card removal; parent hide followed by a new session; normal sustained hover; movement between thumbnails; and repeated hide calls with only the child visible. The invariant is that a full-size hover panel cannot remain visible without a valid owning hover/session. Both the earlier controlled experiment and five ordinary-input early-Escape trials reproduced the defect. The user's historical unrecorded incidents cannot all be attributed to Escape from this evidence, and the later local correction is documented in [the fix report](persistent-preview-fix.md). The saved baseline instrumentation is inside `#if DEBUG`; removing DEBUG sections from those saved snapshots produces source identical to the baseline. Current source also contains the production correction. The local working copy retains the user's existing development certificate; the contribution leaves upstream project signing unchanged. Per the user's preference, the signed debug copy is left running in passive trace mode, with the installed stable copy stopped and the input-helper flag disabled.
