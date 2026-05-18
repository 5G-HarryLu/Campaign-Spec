# free-round-bonus — Implementation Status

Companion to [index.html](./index.html) and [cross-repo-changes.md](./cross-repo-changes.md). Covers **only** the `free-round-bonus` repo (`Campaign` and `FreeRoundBonus.Shared` projects). Last updated: 2026-05-18.

Working branch: `feature/2026-05-15-alex-frb-enhance` (commits `dc54c60..3ae84da`).

---

## 1. Done

### 1.1 Lifecycle outbox: replace `frb:campaign:status_changed` Redis pub/sub with `outbox_msg` writes

| Aspect | Before | After |
|---|---|---|
| Trigger source | `MySqlCampaignInfoService.PublishStatusChangedAsync` Redis publish | Same site, same diff loop, writes outbox instead |
| Delivery | Redis Pub/Sub `frb:campaign:status_changed` (literal) | OceanBase `five_game_trans.outbox_msg` via DAL `SystemService.InsertOutboxMessage` |
| Consumer | GameServer subscriber → CampaignEventRecall to client | msg-center → popup / inbox fan-out |
| Skip-on-time-ended guard | Kept (line 256 of the service) | Kept |
| Reachable events | 1 (Redis publish only) | 4: ComingSoon, Welcome (= Running), Suspend, Terminate |

Refs:
- Spec: D1, §5.1, §7.1
- Code: `src/Campaign/Infrastructure/MySQL/MySqlCampaignInfoService.cs` (commits `096279e`, `3a330b5`, `3ae84da`)
- Constant `RedisKeys.CampaignStatusChangedChannel` deleted
- `IConnectionMultiplexer` dependency removed from `MySqlCampaignInfoService`

### 1.2 EndedEarly outbox emit on prize depletion

The sync proto doesn't carry `end_reason`, so EndedEarly is emitted **inline at the write site** instead of from the sync diff loop.

| Trigger | When `BetEventProcessor` finishes a ticket-issuance round and `CampaignStatusUpdater.UpdateStatusIfLimitReachedAsync` detects `currentCount >= prizeQuantity` |
| --- | --- |
| Status write | `UpdateStatusAsync(End, PrizeDepleted)` — unchanged |
| New behavior | Right after the status write, `EmitEndedEarlyAsync` fans `PublishEndEarlyAsync` out per operator |

Refs:
- Spec: §5.2 "EndEarly", §6.2 row for `BetEventProcessor`
- Code: `src/Campaign/Application/Services/CampaignStatusUpdater.cs` (commit `096279e`)

### 1.3 `IFrbOutboxMsgPublisher` + `FrbOutboxMsgPublisher`

Mirrors `ITournamentOutboxMsgPublisher`. Six methods (5 lifecycle + 1 winning).

| Method | Status | Uses |
|---|---|---|
| `PublishComingSoonAsync` | Active | Lifecycle outbox (1.1) |
| `PublishWelcomeAsync` | Active | Lifecycle outbox (1.1) |
| `PublishSuspendAsync` | Active | Lifecycle outbox (1.1) |
| `PublishTerminateAsync` | Active | Lifecycle outbox (1.1) |
| `PublishEndEarlyAsync` | Active | Inline EndedEarly (1.2) |
| `PublishWinningAsync` | **Defined but not called yet** | M3 (claim flow) will wire it up |

Refs:
- Spec: §6.1 "新增檔案" rows for `IFrbOutboxPublisher` / `FrbOutboxPublisher` (renamed `*Msg*` per 1.5 below)
- Code: `src/Campaign/Application/Interfaces/IFrbOutboxMsgPublisher.cs`, `src/Campaign/Infrastructure/OutboxMsg/FrbOutboxMsgPublisher.cs`

#### Outbox payload reference

Lifecycle events (campaign-scoped, no member):

```json
{
  "type": "Running",
  "event_type": 5,
  "message_type": 1,
  "campaign_type": 2,
  "campaign_id": "CAMP-LUNAR-2026",
  "operator_id": "op-acme"
}
```
- `partition_key`: `"campaign:{campaignId}"`
- Idempotency: `"frb-{eventType}-{campaignId}"`

Winning event (member-scoped, M3 will emit):

```json
{
  "type": "CampaignWinning",
  "event_type": 6,
  "message_type": 1,
  "campaign_type": 2,
  "campaign_id": "CAMP-LUNAR-2026",
  "operator_id": "op-acme",
  "member_id": "member-12345",
  "ticket_id": "ticket-abc-001",
  "ticket_detail_id": "detail-abc-001-level3",
  "level": 3,
  "game_id": "PG_BUFFALO",
  "bet_cents": 500,
  "reward_count": 15,
  "max_payout_cents": 50000,
  "expires_at": "2026-05-30T23:59:59Z"
}
```
- `partition_key`: `"{operatorId}:{memberId}"`
- Idempotency: `"frb-CampaignWinning-{ticketDetailId}"`

### 1.4 Enum extensions (M1 prep — wire-compatible, not all written yet)

| Enum | Added | Used today by |
|---|---|---|
| `TicketStatus` | `PendingClaim = 6`, `Claimed = 7` | **No code writes them yet** — M3 |
| `TicketStatusConverter` | string mappings `pending_claim` / `claimed`, int mappings 6 / 7 | Reads of the two values when they appear |
| `InboxEventType` | `CampaignWinning = 6` | M3 |
| `InboxEventType` | `EndedEarly = 7` | Inline emit (1.2) — active |

> Wire-compat note: `TicketStatus` is a `byte` stored as TINYINT. Values 1–5 are unchanged; new values append. No DDL alter required.

Refs:
- Spec: §6.2 "既有檔案的改動" rows for `TicketStatus.cs` and `InboxEventType`
- Code: `src/FreeRoundBonus.Shared/Enums/TicketStatus.cs`, `InboxEventType.cs`, `Utils/TicketStatusConverter.cs`

### 1.5 `Outbox` → `OutboxMsg` rename (refactor, both sides)

Cosmetic alignment with the OceanBase table name. There are two `outbox*` tables in the same schema — the legacy `outbox` and the active `outbox_msg`; the in-code names should make it obvious which one is targeted.

Both Campaign and Tournament were renamed:

| Old | New |
|---|---|
| `Campaign.Host.TournamentOutboxOptions` (Campaign-local duplicate) | `Campaign.Host.OutboxMsgOptions` (shared by tracker + publisher) |
| `Tournament.Host.TournamentOutboxOptions` | `Tournament.Host.TournamentOutboxMsgOptions` |
| `ITournamentOutboxPublisher` | `ITournamentOutboxMsgPublisher` |
| `TournamentOutboxPublisher` | `TournamentOutboxMsgPublisher` |
| `Tournament.Infrastructure.Outbox` (namespace + folder) | `Tournament.Infrastructure.OutboxMsg` |
| `Campaign.Infrastructure.Outbox` (namespace + folder) | `Campaign.Infrastructure.OutboxMsg` |
| Log prefixes `[TournamentOutbox]`, `[FrbOutbox]` | `[TournamentOutboxMsg]`, `[FrbOutboxMsg]` |

Behavior unchanged: same topic (`msg-center-events`), same DAL gRPC method, same payload format.

Refs:
- Commit `a0cbbd3`

### 1.6 `TournamentCampaignTracker` — consume the shared options class

Pure type-name refactor following 1.5. Field/ctor parameter changed from `TournamentOutboxOptions` → `OutboxMsgOptions`. Same DI registration, same topic value, same outbox write. No behavior change.

### 1.7 Bet-by-level park markers

Three sites where `GameChipsConfig.Bet` is read carry a `TODO(FRB-2.0 M5 — bet-by-level)` comment pointing to this doc and `cross-repo-changes.md §M5`. No code change.

Sites:
- `src/Campaign/Application/Services/TicketService.cs:72`
- `src/Campaign/Application/Services/BetEventProcessor.cs` (two sites)

---

## 2. Parked for future work

### 2.1 Bet-by-level (Q7–Q9 / M5)

The biggest open question. `GameChipsConfig.Bet` is currently keyed `(campaign, operator, game)` — one bet per game-in-a-campaign. The new requirement is to allow **per-level** bets.

Unresolved decisions (from spec §3.1):
- **Q7** — key shape: `(campaign, level)` vs `(campaign, level, game_id)`
- **Q8** — cross-game behavior: shared bet within a level or per-game-within-a-level?
- **Q9** — schema landing:
  - A) extend `campaign_threshold_currency` with a `bet` column (lives next to `level`)
  - B) new table `campaign_frb_level_bet`

Until product confirms, we touch nothing. The three call sites are marked with TODOs so a future grep finds them.

When unblocked, expected downstream work:
- `ThresholdConfig` entity + `MySqlThresholdConfigRepository` — read new field
- Valhalla DAL proto (`ThresholdConfigItem` or new message) — coordinate with DAL team
- `TicketBuilder` / `BetEventProcessor` — switch bet-resolution order
- DB migration (or new table) per Q9 outcome

### 2.2 M3 — Claim flow

Not started in this branch. Spec §7 M3 covers it. Needed for:

| Piece | Status |
|---|---|
| `TicketStateMachine` for `PendingClaim → Claimed` transition | Not started |
| `TicketClaimService` (idempotent claim via conditional UPDATE on `free_round_bonus_ticket_details.id`) | Not started |
| `TicketClaimController` exposing `POST /api/frb/tickets/{ticketId}/levels/{level}/claim` | Not started |
| `BetEventProcessor` change: threshold-met writes `status = PendingClaim` instead of legacy `Pending = 1` | Not started |
| `TicketBuilder.StatusEnum = PendingClaim` | Not started |
| `FrbOutboxMsgPublisher.PublishWinningAsync` first caller | Wired but unused |

Prerequisite: `PendingClaim = 6` and `Claimed = 7` are already in the `TicketStatus` enum (1.4 above), so M3 just adds writers/readers — no enum surgery.

### 2.3 M3.5 — Inbox real-time ticket state (Q10)

Blocker for the inbox-row USED/expired UI. Three candidate approaches in spec §5.4:

- **A.** FRB exposes a read API (`GET /api/frb/tickets?member_id=&status=`) — recommended in the spec
- **B.** Per-state-transition outbox events — high traffic, needs aggregation
- **C.** msg-center subscribes to FRB Redis channels — violates D1

Decision pending msg-center team alignment.

### 2.4 M4 — Retire `RedisNotificationPublisher` / `frb:ticket:pending`

The remaining FRB Redis publish (ticket-issued notification → GameServer) is still in place at `src/Campaign/Infrastructure/Redis/RedisNotificationPublisher.cs`. It retires only after:

1. M3 wires `PublishWinningAsync` so msg-center receives the threshold-met event
2. GameServer cuts over to consuming via msg-center (their team owns this per D9)

Then this branch deletes:
- `RedisNotificationPublisher.cs`
- `INotificationPublisher` interface
- `Campaign.Domain.ValueObjects.TicketNotification`
- DI registrations
- `RedisKeys.TicketPendingChannel` constant

### 2.5 Backstage operation path for Suspend / Terminate (D6 detail)

Spec §7.1 risk row: "後台操作路徑". Today the FRB tracker assumes backstage flips `campaign.status` directly in MySQL (CDC-style detection). If backstage actually goes through a FRB API instead, the tracker still catches it via sync diff — but the latency window equals one sync interval. Decision pending backstage team confirmation.

### 2.6 Shared `outbox_msg` topic routing (D2)

`OutboxMsgOptions.Topic` defaults to `"msg-center-events"`, shared with Tournament. Spec §7.1: "msg-center 端依 `event_type` 而非 topic 路由". Need msg-center team to confirm their routing is `event_type`-based, not topic-based, before high-traffic FRB lifecycle volume joins the shared topic.

### 2.7 EndedEarly — `end_reason` propagation through DAL sync

Today EndedEarly is emitted inline (1.2) because the sync proto doesn't carry `end_reason`. If a future requirement needs EndedEarly to fire from non-FRB code paths (e.g. an admin tool that writes the column directly), the cleanest fix is to add `end_reason` to `CampaignSyncItem` in Valhalla's proto. Not blocking; flagged for awareness.

---

## 3. Commit log

| Commit | Subject | Scope |
|---|---|---|
| `dc54c60` | feat: M1 — FRB outbox publisher + state and event enum scaffolding | 1.3, 1.4 |
| `a0cbbd3` | refactor: rename Outbox → OutboxMsg to match outbox_msg table | 1.5, 1.6 |
| `096279e` | feat: M2 — FRB lifecycle event emission | 1.1 (initial), 1.2 |
| `3a330b5` | refactor: merge FRB lifecycle outbox emit into MySqlCampaignInfoService | 1.1 (correction) |
| `3ae84da` | refactor: retire frb:campaign:status_changed Redis pub/sub | 1.1 (final) |

554 → 551 tests after the M2 restructure; all green.

---

## 4. Out-of-scope items deliberately untouched in this branch

For completeness, these are spec-adjacent things we did **not** modify on `free-round-bonus`:

- **GameServer / GameClient code** — spec D9; their team owns the cutover.
- **msg-center service** — spec D1; their team owns the consumer side. See [cross-repo-changes.md §3.2](./cross-repo-changes.md).
- **`Aggregator/Infrastructure/Redis/RedisBetEventPublisher`** — internal bet-event pipeline, not player-facing.
- **`Tournament.Infrastructure.Redis.RedisMemberWalletNotifier`** and **`Campaign.Api.MembersController` `member:wallet:refresh` publish** — wallet refresh path, unrelated.
- **End-reminder backstage field** — spec D7: "先不動 schema, 之後再處理".
