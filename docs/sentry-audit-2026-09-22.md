# Mithka Sentry check — 2026-09-22

Read-only check of `sentry.nekoko.it`, organization `nekoko`, project `mithka`
(10). No production settings or issues were changed and no test events were
sent. All counts below are aggregates.

Window: **2026-09-21 08:16:37 to 2026-09-22 08:16:37 UTC**.
Comparison: **2026-09-14 08:16:37 to 2026-09-21 08:16:37 UTC**.

The authenticated `sentry-cli` issues/events fallback worked. An 18,000-event
listing reached August 28, covering both windows completely; a separate
2,500-event retrieval confirmed the last-day total. These are retained error
events, not sessions or active users, and do not establish a crash/failure rate.
Category matching used CLI titles and tags, not full native stacks.

| Category | Last 24h events | Prior 7d events | Last 24h identified users |
| --- | ---: | ---: | ---: |
| All listed events | 1,463 | 7,704 | 393 |
| App Hanging | 292 | 24 | 7 |
| ANR | 1 | 2 | 1 |
| MissingPluginException | 845 | 3,370 | 343 |
| Null-check errors | 16 | 3,440 | 5 |
| Crash-signature events (abort, EXC_BAD_ACCESS, SIGABRT) | 35 | 163 | 30 |
| Thread construction/resource unavailable | 0 | 1 | 0 |
| ANativeWindow/SurfaceProducer title matches | 0 | 5 | 0 |

Five last-day events had no user tag; they were not treated as a single user.
There were 2,770 events without user tags in the baseline, including a large
Windows null-check cluster. User counts are unique within each row, not additive.

Last-day platforms: Android 1,029; macOS 291; iOS 130; Windows 7; Linux 6.
No CLI title matches were found in either window for MDK FrameReader,
AudioBackend, short-body/No-content HttpException, memory pressure or OOM.
Truncated titles and missing full native stacks mean these are **not confirmed
absences**. `/video/` attribution cannot be comprehensively established through
the listing alone.

## Priority findings

1. **New macOS hang cluster on a release containing the fixes.**
   [MITHKA-J](https://sentry.nekoko.it/organizations/nekoko/issues/4225/)
   contains 287 macOS hangs in the last day versus zero macOS hangs in the
   preceding week. Of these, 284 were on `1.5.2+26092103`, across one identified
   user, with commit `6f029fc`; three were on `1.4.10+26091808`.
   Git ancestry confirms `6f029fc3` contains the July performance fixes
   `446b89a9`, August hot-path fix `2739c9ac`, Android sticker workaround
   `e93e4b58`, and compatibility toggle `82f4a6cd`. This is a regression signal
   on a fix-bearing release, not evidence that those commits caused it.
   A native main-thread stack and session context are needed to identify the
   cause. Do not infer population-wide incidence from one user's repetition.
2. **Android plugin/channel failures are the broadest error cluster.**
   The 845 missing-plugin events affected 343 identified users. App-links alone
   accounts for 714 events in
   [MITHKA-A](https://sentry.nekoko.it/organizations/nekoko/issues/4203/).
   Reports span older versions through `1.5.3+1790048194`; app-links includes
   490 on `1.4.10`, 96 on `1.5.2`, and 17 on `1.5.3`.
   A separate channel-error cluster contributed 144 events across six users.
   Android `MainActivity` used a hand-maintained plugin list that omitted eight
   compiled production plugins. The accompanying targeted repair registers
   app-links, CameraX, native video thumbnails, video compression, QR scanning,
   recording, sensors and WebView, preserving per-plugin loading/error handling.
   A regression test compares this list with Flutter's generated registry.
   This addresses a verified registration gap; a shipped Android build and
   subsequent Sentry observations are still needed to confirm production impact.
3. **Native crash signatures still occur on recent releases.**
   The 35 last-day signatures comprise Android 28 and iOS 7. Releases include
   Android `1.5.3+1790048194` (1), `1.5.2+1789961741` (5),
   `1.4.10+1789719951` (18), and older Android versions (4); iOS
   `1.5.0+1198` (2), `1.4.10+1163` (3), and `1.2.6+1103` (2).
   Generic `abort` titles cannot establish whether a decoder, memory pressure
   or another native component caused them.

The remaining five last-day hangs were on iOS: `1.5.0+1198` (2),
`1.4.10+1163` (2), and `1.2.6+1103` (1). The ANR was Android
`1.4.10+1789719951`. Sixteen null-check errors were on iOS `1.4.10+1163`
(10), Android `1.4.10+1789719951` (5), and Android `1.5.2+1789961741` (1).
Missing commit tags were not inferred from version numbering. Older releases
are not automatically classified as lacking every earlier fix.

## Performance access and sampling

The transaction/Discover API returned **403**; the metrics route returned **404**.
The available browser reached Sentry successfully but displayed sign-in rather
than an authenticated dashboard. This is not a current DNS failure.

Transaction volume, route p50/p95/p99, slow/frozen frames, RSS, image-cache and
custom Mithka metrics therefore remain **unknown**. Error-event counts cannot
replace them. No inference of good performance is justified.

Keep the existing **2% tracing rate** for now. Increasing it cannot solve access
restrictions, and decreasing it would reduce already-unverified coverage.
Restore read access before making a volume-based sampling adjustment. Repeated
hang/plugin errors are also an event-volume concern independent of tracing.
The new video reporting has its own bounded diagnostic sampling, described in
[video-playback-telemetry.md](video-playback-telemetry.md).

Earlier automation notes from August used shorter/capped histories and were
weeks old. They were useful for selecting tracked signatures but are not a
like-for-like daily baseline for this check; the comparison above was rebuilt
from live data instead.
