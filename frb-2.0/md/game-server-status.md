# GameServer — Implementation Status

Companion to [index.html](./index.html), [cross-repo-changes.md](./cross-repo-changes.md), [free-round-bonus-status.md](./free-round-bonus-status.md), and [message-center-service-status.md](./message-center-service-status.md). Covers **only** the `GameServer` repo. Last updated: 2026-05-19.

Working branch: `feature/2026-05-19-alex-frb-enhance` (commit `370932ce`).

---

## 1. Done

### 1.1 Retire `frb:ticket:pending` subscription (ticket-granted notification)

GameServer used to subscribe to FRB's Redis Pub/Sub `frb:ticket:pending` channel and push `CampaignEventRecall` (with `EventType = TicketGrant`) to online players. After FRB starts writing Winning events to `outbox_msg` and msg-center fans them out into `member_inbox`, the player-facing notification flows through msg-center → GameClient instead. GameServer is no longer in the chain.

| Aspect | Before | After |
|---|---|---|
| Trigger source | Redis Pub/Sub `frb:ticket:pending` published by FRB `RedisNotificationPublisher` | FRB outbox `FrbWinning` event → msg-center → GameClient inbox |
| GameServer role | Subscriber, fan-out to online sessions via `CampaignEventRecall` | None |
| Player UX when offline at grant time | Notification dropped (Pub/Sub fire-and-forget) | Inbox row persists; player sees it next login |
| Idempotency on duplicate publish | Best-effort (subscriber re-pushed) | msg-center deduplicates via `IdempotencyKey` upstream |

Refs:
- Spec: [cross-repo-changes.md §3.3](./cross-repo-changes.md), [free-round-bonus-status.md §2.4](./free-round-bonus-status.md)
- Code deleted: `GameServer/BackgroundService/FrbTicketSubscriberService.cs`, `GameServer.Tests/BackgroundService/FrbTicketSubscriberServiceTests.cs`

### 1.2 Retire `frb:campaign:status_changed` subscription (campaign lifecycle notification)

GameServer used to subscribe to FRB's Redis Pub/Sub `frb:campaign:status_changed` channel and push `CampaignEventRecall` (with `EventType = CampaignStatus`) to online players within affected operator/game pairs. FRB now emits lifecycle events (`ComingSoon`, `Welcome/Running`, `Suspend`, `Terminate`, `EndedEarly`) through outbox; msg-center routes them to popup (ComingSoon/Running) or inbox (Suspend/Terminate/EndedEarly).

| Aspect | Before | After |
|---|---|---|
| Trigger source | Redis Pub/Sub `frb:campaign:status_changed` from FRB `MySqlCampaignInfoService.PublishStatusChangedAsync` | FRB outbox lifecycle events → msg-center fan-out |
| GameServer role | Subscriber, pushed `CampaignEventRecall` to all affected online sessions | None |
| In-memory cache (`FrbCampaignStatusCache`) | Populated by this subscriber, read by `CampaignService.CampaignCall` | Removed; `CampaignService` uses DAL `GetCampaign(...).Status` as single source |

Refs:
- Spec: [cross-repo-changes.md §3.3](./cross-repo-changes.md), [free-round-bonus-status.md §1.1](./free-round-bonus-status.md)
- Code deleted: `GameServer/BackgroundService/FrbCampaignStatusSubscriberService.cs`, `GameServer/Game/Campaign/FrbCampaignStatusCache.cs`, `GameServer.Tests/BackgroundService/FrbCampaignStatusSubscriberServiceTests.cs`

### 1.3 `CampaignService` dependency cleanup

`CampaignService.CampaignCall` previously consulted `IFrbCampaignStatusCache.GetStatus(campaignId)` first, then fell back to the DAL `GetCampaign(...).Status`. The cache was a perf optimization populated only by the now-retired status subscriber; with the subscriber gone the cache would always be empty, so the cache lookup is removed entirely. Two call sites updated, both fall through to the DAL value that was already the source of truth on cache miss.

Refs:
- Code: `GameServer/Service/CampaignService.cs` lines 62, 80, 102
- Test: `GameServer.Tests/Service/CampaignServiceTests.cs` (mock removed)

### 1.4 `FrbSubscriberServiceBase` rename → `RedisPubSubSubscriberBase`

The shared base class (Polly retry pipeline, circuit breaker, DLQ) was authored alongside FRB but is not FRB-specific — `BalanceSyncService` (member wallet refresh) also depends on it. Rather than inline the resilience layer into one subscriber or strip it, the base class is renamed and generalised:

| Aspect | Before | After |
|---|---|---|
| Class name | `FrbSubscriberServiceBase` | `RedisPubSubSubscriberBase` |
| DLQ Redis key | `frb:ticket:dlq` (via `FrbConstants.ChannelDeadLetterQueue`) | `redis:pubsub:dlq` (private const on the base) |
| DLQ envelope | `FrbDeadLetterMessage` (FRB-specific JSON context) | `RedisPubSubDeadLetterMessage` + own `JsonSerializerContext`; adds `channel` field so the DLQ identifies which subscriber dropped the message |
| Log prefix | Hard-coded `[FRB]` in retry callback | Uses subclass-provided `LogPrefix` consistently |
| Polly behaviour | Same retry / breaker config | Unchanged |

Only `BalanceSyncService` survives as a subscriber subclass.

Refs:
- Code: `GameServer/BackgroundService/RedisPubSubSubscriberBase.cs`, `GameServer/BackgroundService/RedisPubSubDeadLetterMessage.cs`, `GameServer/Service/CampaignServer/BalanceSyncService.cs`

### 1.5 `FrbConstants` / `FrbRedisModels` trim

Constants and DTOs that only the retired subscribers referenced are removed:

| Removed | Kept (still used) |
|---|---|
| `ChannelPending` (`frb:ticket:pending`) | `ChannelInUse`, `ChannelCompleted`, `ChannelEarlyCompleted` (FRB still consumes these from GameServer) |
| `ChannelCampaignStatusChanged` (`frb:campaign:status_changed`) | `ChannelMemberWalletRefresh` (`member:wallet:refresh`) |
| `ChannelDeadLetterQueue` (`frb:ticket:dlq`), `DlqTtlDays` | `TicketHashKeyPrefix`, `PlayerTicketSetKeyPrefix` (read by `FrbTicketHelper`) |
| `FrbPendingMessage` DTO | `CompletionReasonAllRoundsUsed`, `CompletionReasonCappedPayout` |
| `FrbCampaignStatusChangedMessage` DTO | `FrbInUseMessage`, `FrbCompletedMessage` (publish DTOs used by `FrbTicketHelper`) |
| `FrbDeadLetterMessage` DTO | `MemberWalletRefreshMessage` (used by `BalanceSyncService`) |
| Matching `JsonSerializable` entries on `FrbJsonContext` | `FrbTicketStatus` enum + extensions |

Refs:
- Code: `GameServer/Game/Campaign/FrbConstants.cs`, `GameServer/Game/Campaign/FrbRedisModels.cs`

### 1.6 DI cleanup

Three registrations removed in `GameServer/Extensions/IServiceCollectionExtension.cs`:
- `services.AddSingleton<IFrbCampaignStatusCache, FrbCampaignStatusCache>()`
- `services.AddHostedService<FrbTicketSubscriberService>()`
- `services.AddHostedService<FrbCampaignStatusSubscriberService>()`

`IFrbTicketHelper` and `BalanceSyncService` registrations untouched.

### 1.7 Tests — 60 / 60 green

- Removed: `FrbTicketSubscriberServiceTests.cs`, `FrbCampaignStatusSubscriberServiceTests.cs` (test the deleted subscribers).
- Updated: `CampaignServiceTests.cs` — dropped the now-unused `Mock<IFrbCampaignStatusCache>` field and its `IServiceProvider.GetService` setup.
- Untouched: `FrbTicketHelperTests.cs`, `FrbTicketInfoTests.cs` — exercise gameplay-side ticket reads/writes which remain unchanged.

Final test result: 60 passed, 0 failed.

---

## 2. Out of scope — deliberately untouched

These were considered and explicitly left alone because the FRB Redis data plane (hash, player set, GameServer-published progress events) survives the migration. Per Keen's confirmation: *"FRB keeps the same behavior except (1) do not publish to redis for campaign status change (2) do not publish to redis when ticket granted"*.

### 2.1 `FrbTicketHelper` — entire gameplay-side ticket helper

Reads from `frb:ticket:{id}` hash (`GetTicketAsync`, `GetTicketsAsync`, `GetPlayerTicketByCampaignIdAsync`), reads from `frb:player:{op}:{member}:tickets` set (`GetPlayerTicketIdsAsync`), writes progress via Lua conditional-update script (`UpdateTicketProgressAsync`, `UpdateTicketCompletionWithRetryAsync`), publishes `frb:ticket:in_use` / `frb:ticket:completed` (`PublishInUseStatusAsync`, `PublishCompletedStatusAsync`, fire-and-forget + retry variants), adds tickets to player set (`AddTicketToPlayerSetAsync`).

All consumers in active gameplay paths — `LoginService`, `WSUser`, `CampaignService`, `CampaignServiceHelper`, `GameActionHelper` — remain unchanged. FRB continues to write the hash and player set on ticket creation; FRB continues to subscribe to GameServer's `in_use` / `completed` publishes to drive its state machine.

### 2.2 Claim handling on GameServer side (5-enum model, decided 2026-06-05)

**Updated**: FRB does **not** add `PendingClaim`/`Claimed` states. Status stays `1..5`; `Pending = 1` itself is the "in inbox, awaiting claim" state, and **claim = PLAY NOW only** sets a `claimed_at` timestamp via CAS (`WHERE status = Pending`) — status does not change on claim. (The `6/7` previously shipped into the FRB `TicketStatus` enum is reverted on the implementation branch.)

Net effect on GameServer is **the same as before, and even simpler**: when the player taps PLAY NOW, msg-center calls FRB's claim API (sets `claimed_at`) and redirects into the game. By the time GameServer sees the ticket via `FrbTicketHelper.GetTicketAsync`, status is `Pending` and the existing `Pending → InUse → Completed / EarlyCompleted / Expired` flow takes over. **No GameServer code reads or writes any claim-specific state** — `claimed_at` is FRB-internal.

The `FrbTicketStatus` enum on GameServer (`Pending`, `InUse`, `Completed`, `EarlyCompleted`) is unchanged and intentionally does not mirror anything FRB-side.

### 2.3 `BalanceSyncService` and `member:wallet:refresh`

Member wallet balance push from FRB to GameClient via Redis Pub/Sub. Unrelated to lifecycle / winning flow. Reparented onto `RedisPubSubSubscriberBase` (1.4) but functionally identical.

### 2.4 `TicketGrantedService` (gRPC session callback)

This is a **different** ticket-granted path from the retired Redis subscriber: the CampaignServer process pushes a session-level `NotifyTicketGranted` message to GameServer via the existing gRPC connection. It also emits `CampaignEventRecall` with `EventType = TicketGrant`. Spec does not call for retiring this path; left untouched.

### 2.5 `LoginService.NotifyCampaignStatusChanges` and `RecoverFrbTickets`

On login, `LoginService` reads pending campaign-notify rows from MySQL and emits `CampaignEventRecall` for them; it also enumerates the player's FRB ticket set from Redis and re-emits ticket info. These are inbound-on-login flows, not Redis Pub/Sub subscribers, and remain the safety net for the offline-at-grant case alongside the new inbox path.

### 2.6 `Model/Repository/...FreeRoundBonus*` — DB access for FRB tickets

Untouched. These are read/write paths for gameplay reporting (winning lists, ticket history) and are unrelated to the notification pipeline.

---

## 3. Deploy ordering

Per Keen: GameServer must be deployed **after** `free-round-bonus` and `message-center-service` have both shipped their revisions. During the gap:

1. **FRB + msg-center deployed first** — Winning events land in `member_inbox`, lifecycle events in `operator_inbox` / popup. FRB's Redis Pub/Sub for ticket-granted / campaign-status may still be running in parallel (no harm — GameServer is still subscribing at this point).
2. **GameServer deployed** — subscribers gone. Any inbox rows accumulated in step 1 are surfaced to GameClient via msg-center's API on next login/poll. No popup gap because the inbox persists.

No double-write coordination needed from GameServer's side — this is a pure consumer-removal change, not a producer change. Rollback is `git revert` of commit `370932ce`; no DB migrations or shared-state mutations.

---

## 4. Commit log

| Commit | Subject | Scope |
|---|---|---|
| `370932ce` | 移除 FRB Redis Pub/Sub 訂閱，改由 message-center-service 經 inbox 通知玩家 | 1.1–1.7 (single PR) |

13 files changed, +51 / −681 lines (mostly deletions).

---

## 5. Open items / follow-ups

- **None blocking.** All spec-listed GameServer deletions are complete.
- If the FRB team later confirms the `frb:ticket:in_use` / `frb:ticket:completed` publish path will also be retired (replaced by a sync API or different signal), GameServer would need a second PR to remove those publishes from `FrbTicketHelper`. Not requested in the current spec.
- If `BalanceSyncService` becomes the only `RedisPubSubSubscriberBase` subscriber long-term, future consideration: inline the base into `BalanceSyncService` to reduce indirection. Not urgent — the base is small and the abstraction is honest as long as more than zero subscribers benefit.
