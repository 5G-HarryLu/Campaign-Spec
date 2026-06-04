# FRB msg-center Integration — Cross-Repo Change Plan

Shared reference for changes spanning **three repos** driven by the FRB msg-center integration spec ([index.html](./index.html)).
Date opened: 2026-05-15 · Spec source: Keen / Notion FRB-msg-center-ticket-bet · Spec date: 2026-05-13.

> **Bet-by-level scope note** — per current decision, the **bet-by-level** work (spec §1.3, Q7–Q9, M5) is **commented out / parked** in every section below. Each repo's section flags those items as `[PARKED — bet-by-level]` so we can revisit without re-reading the spec. Do not implement them yet.

---

## 1. Repos involved

| Repo | Role in this initiative |
|------|--------|
| [free-round-bonus](https://github.com/alexkan-gemmis/free-round-bonus) | FRB / Campaign services (.NET 10). Source of all outbox writes; owns ticket state machine and claim API. |
| [message-center-service](https://github.com/) | msg-center (.NET). Consumes outbox via Kafka, fan-out to popup + inbox, calls back FRB claim API. |
| [GameServer](https://github.com/) | Game-side .NET service. Subscribes to FRB Redis Pub/Sub today; that subscription is **retired** once msg-center becomes the single notification source. |

Outbox topic is **shared** with Tournament (`TournamentOutboxOptions.Topic`, decision D2). msg-center must route by `event_type`, not topic.

### Outbox table reference (confirmed)

Storage lives on **OceanBase** (`five_game_trans_dev.outbox_msg`) — *not* MySQL. Source: `mcp__mysql__describe_table` against `oceanbase_dev` (2026-05-15).

```sql
CREATE TABLE `outbox_msg` (
  `id`            varchar(24)  NOT NULL  COMMENT 'ObjectId',
  `topic`         varchar(255) NOT NULL  COMMENT 'SNS topic name',
  `partition_key` varchar(255) NOT NULL  COMMENT 'SNS MessageGroupId (e.g. member:<member_id>)',
  `data`          json         NOT NULL  COMMENT 'Message payload',
  `created_at`    datetime     NOT NULL  COMMENT 'Created time (UTC)',
  PRIMARY KEY (`id`),
  KEY `idx_created` (`created_at`)
) partition by key(`id`) (64 partitions p0..p63);
```

| Column | Role for FRB outbox writes |
|---|---|
| `id` | 24-char Mongo ObjectId (`ObjectId.GenerateNewId().ToString()`) — matches Tournament's pattern. |
| `topic` | Shared with Tournament: `msg-center-events` (`TournamentOutboxOptions.Topic`, D2). |
| `partition_key` | `"{operator_id}:{member_id}"` for member-scoped events; for campaign-lifecycle events (no member) use `"campaign:{campaign_id}"`. |
| `data` | JSON envelope — see [index.html §5.3](./index.html). Includes `type`, `event_type`, `campaign_type`, ticket-level fields for FrbWinning. |
| `created_at` | Written by DAL (`SystemService.InsertOutboxMessage`) in UTC; FRB does not set this. |

> Idempotency lives on the DAL gRPC side, not on this table — the `IdempotencyKey` field in `InsertOutboxMessageRequest` (e.g. `frb-FrbWinning-{ticketId}`) is what stops duplicate inserts. No idempotency column on the table itself.

---

## 2. Lifecycle event → repo responsibility matrix

| Event | free-round-bonus (FRB) | message-center-service | GameServer |
|---|---|---|---|
| `FrbComingSoon` | `CampaignSyncBackgroundService` writes outbox N min before start (N from backstage). | Route to popup. | — |
| `FrbWelcome` | `CampaignSyncBackgroundService` writes outbox at start. | Route to popup. | — |
| `FrbSuspend` | Backstage path writes outbox (see §3 D6 risk). | Route to inbox. | — |
| `FrbTerminate` | Backstage path writes outbox. | Route to inbox. | — |
| `FrbWinning` | Threshold met → create `PendingClaim` ticket + write outbox (full payload, see [index.html §5.3](./index.html)). | Fan-out popup **and** inbox row with PLAY NOW / PLAY LATER. PLAY NOW → call FRB claim API. | — |
| `FrbPayout` | **No FRB action** (Keen: msg-center decides). | popup, msg-center semantics. | — |
| `FrbEndEarly` | Backstage path writes outbox. | Route to inbox. | — |
| `FrbEnd` (natural end) | No event. | — | — |
| (existing) `frb:ticket:pending` Redis Pub/Sub | **Retire after GameServer migration** (M4). | — | **Unsubscribe & delete files** (M4). |

---

## 3. Per-repo file checklists

Legend: `[ ]` not started · `[~]` in progress · `[x]` done · `[PARKED]` deferred · 🔴 high impact · 🟡 medium · 🟢 low

### 3.1 `free-round-bonus`

Detailed spec view: [index.html §6 Codebase 影響清單](./index.html).

**New files**
- [ ] 🟡 `src/Campaign/Application/Interfaces/IFrbOutboxPublisher.cs` — interface, mirror of `ITournamentOutboxPublisher`.
- [ ] 🟡 `src/Campaign/Infrastructure/Outbox/FrbOutboxPublisher.cs` — impl, calls DAL `SystemService.InsertOutboxMessage`.
- [ ] 🟡 `src/Campaign/Host/FrbOutboxOptions.cs` — topic / idempotency settings. (Or reuse `TournamentOutboxOptions` directly per D2.)
- [ ] 🔴 `src/Campaign/Application/Services/TicketClaimService.cs` — claim orchestration, idempotency, expiry checks. Pattern: `src/Tournament/Reward/RewardClaimService.cs`.
- [ ] 🔴 `src/Campaign/Domain/Services/TicketStateMachine.cs` — adds **two new transitions on top of the existing chain**: `PendingClaim → Claimed` (claim API) and `Claimed → Pending` (player enters game). Existing `Pending → InUse → Completed/EarlyCompleted/Expired` transitions remain unchanged. Pattern reference: `src/Tournament/Reward/RewardStateMachine.cs` (simpler here: no `Claiming` transient).
- [ ] 🟡 `src/Campaign/Api/Controllers/TicketClaimController.cs` — `POST /api/frb/tickets/{ticketId}/levels/{level}/claim`. Pattern: `src/Tournament/Api/Controllers/RewardController.cs`.
- [ ] 🟡 `src/Campaign/Domain/Events/FrbLifecycleEvent.cs` — payload value objects for the 7 events.
- [ ] 🟡 `src/Campaign/Api/Controllers/TicketQueryController.cs` — **conditional on Q10**: `GET /api/frb/tickets?member_id=&status=` for msg-center inbox state refresh.

**Existing files to modify**
- [ ] 🔴 `src/FreeRoundBonus.Shared/Enums/TicketStatus.cs` — add `PendingClaim = 6` (msg-center showing PLAY NOW) and `Claimed = 7` (post-claim, awaiting player to enter game). **Do not renumber 1–5.** The two new states **prepend** to the existing chain — after `Claimed`, ticket transitions to existing `Pending = 1` when the player enters the game; the legacy `Pending → InUse → Completed/EarlyCompleted/Expired` path is unchanged. No transient `Claiming` state: claim API is a single conditional DB update (`UPDATE … WHERE status = PendingClaim`), no remote wallet call.
- [ ] 🔴 `src/Campaign/Application/Services/BetEventProcessor.cs` — on threshold met, create `PendingClaim` ticket + call `FrbOutboxPublisher`; drop `INotificationPublisher` dependency.
- [ ] 🔴 `src/Campaign/Domain/Services/TicketBuilder.cs` — `StatusEnum = TicketStatus.PendingClaim`.
- [ ] 🟡 `src/Campaign/Application/Services/TicketService.cs` — filter queries that need to distinguish `PendingClaim` vs `Pending`.
- [ ] 🟡 `src/Campaign/Host/CampaignSyncBackgroundService.cs` — emit `ComingSoon` (N min before start, N from backstage) and `Welcome` (on start).
- [ ] 🟡 `src/Campaign/Infrastructure/MySQL/TournamentCampaignTracker.cs` — generalise pattern for FRB lifecycle (Suspend/Terminate/EndEarly) if backstage writes DB directly (see §4 risk D6).
- [ ] 🟡 `src/Campaign/Program.cs` — register `IFrbOutboxPublisher`, `TicketClaimService`, `TicketStateMachine`; remove `INotificationPublisher` / `RedisNotificationPublisher` registration **only after GameServer cuts over** (M4).
- [ ] 🟢 `src/Campaign/Domain/ValueObjects/TicketNotification.cs` — delete after M4 cutover.
- [ ] 🟢 `src/Campaign/Infrastructure/Redis/RedisNotificationPublisher.cs` — delete after M4 cutover; remove `frb:ticket:pending` constant from `src/FreeRoundBonus.Shared/Constants/RedisKeys.cs`.
- [ ] 🟢 `src/FreeRoundBonus.Shared/Enums/InboxEventType.cs` — add 7 FRB values (style-match Tournament enums).

**[PARKED — bet-by-level]** *(do not start until Q7–Q9 confirmed)*
- [ ] 🟡 `src/Campaign/Domain/Entities/ThresholdConfig.cs` — add `BetCents` (or equivalent) by-level field.
- [ ] 🟡 `src/Campaign/Infrastructure/MySQL/MySqlThresholdConfigRepository.cs` — read/write new field.
- [ ] 🟢 `src/Campaign/Infrastructure/MySQL/MySqlConfigRepository.cs:64` — clarify `GameChipsConfig.Bet` vs by-level priority/fallback.
- [ ] 🟡 `src/Campaign/Infrastructure/Protos/campaign.proto` — add `bet` field to threshold message (currently `ThresholdConfigItem`); coordinate with Valhalla team.
- [ ] DB schema: `campaign_threshold_currency.bet` (or new `campaign_frb_level_bet` table — Q9).

**Tests**
- [ ] `tests/Campaign.Tests/...` — claim state machine, outbox payload shape, idempotency.

---

### 3.2 `message-center-service`

Layout: four .NET services around Kafka + OceanBase/MySQL. Outbox flow today:
`message-center-relay/RelayWorker.cs` → Kafka `msg-center-events` → `message-center-consumer/ConsumerWorker.cs` → `MemberInboxRepository` / `OperatorInboxRepository` → `message-center-api/Controllers/InboxController.cs` serves clients.

**New / modified**
- [ ] 🔴 `message-center-shared/Enums/EventType.cs` — extend with 7 FRB values (or 5 if Payout/End excluded from FRB's responsibility). Today only Tournament-style values exist (`PrizeSettled = 1`, `Suspended = 2`, `Terminated = 3`, `ComingSoon = 4`, `Running = 5`).
- [ ] 🔴 `message-center-consumer/Models/OutboxEnvelope.cs` — confirm envelope covers `ticket_id`, `game_id`, `game_name`, `bet_cents`, `reward_count`, `max_payout_cents`, `expires_at` (Figma fields, [index.html §5.3](./index.html)).
- [ ] 🔴 `message-center-consumer/ConsumerWorker.cs` (`ProcessMessage`) — branch on FRB event types; write to member_inbox with FRB-specific payload (game_name / bet / reward_count / expires_at).
- [ ] 🟡 `message-center-api/Controllers/InboxController.cs` — expose PLAY NOW callback that issues `POST /api/frb/tickets/{ticketId}/levels/{level}/claim` to FRB. Same endpoint serves popup PLAY NOW and inbox PLAY NOW.
- [ ] 🟡 `message-center-api/Repositories/MemberInboxRepository.cs` — handle FRB suppression / stale cascade (existing comment already mentions FRA/FRB single-game vs Tournament multi-game distinction).
- [ ] 🟡 Inbox row state refresh path — **depends on Q10 (M3.5)**:
    - If method A (recommended): on inbox open, call FRB `GET /api/frb/tickets?member_id=&status=` and merge.
    - If method B: subscribe FRB outbox update events.
    - If method C: subscribe FRB Redis channels (not recommended).

**[PARKED — bet-by-level]**
- [ ] If inbox needs to display per-level bet, payload key naming must match FRB's final schema decision (Q9).

**Tests**
- [ ] FRB event routing in consumer; PLAY NOW callback happy/error/expired paths; inbox state refresh per Q10 outcome.

---

### 3.3 `GameServer`

Today GameServer is the **direct consumer** of FRB Redis Pub/Sub. After migration, msg-center owns the player-facing path.

**Files to retire (M4, after msg-center is live and verified)**
- [ ] 🔴 `GameServer/BackgroundService/FrbTicketSubscriberService.cs` — subscribes `frb:ticket:pending`. **Delete.**
- [ ] 🟡 `GameServer/BackgroundService/FrbCampaignStatusSubscriberService.cs` — FRB campaign status Pub/Sub. **Delete** (lifecycle events now go via msg-center).
- [ ] 🟡 `GameServer/BackgroundService/FrbSubscriberServiceBase.cs` — base class; **delete** once both subclasses are gone.
- [ ] 🟢 `GameServer/Game/Campaign/FrbRedisModels.cs` — Redis payload models for FRB. **Delete** if unreferenced after the above.
- [ ] 🟢 `GameServer/Game/Campaign/FrbConstants.cs` — FRB channel constants. **Delete** if unreferenced.

**Kept / unrelated**
- `GameServer/Service/CampaignServer/BalanceSyncService.cs` — still publishes/subscribes to `member:wallet:refresh`. **Not affected** by this change.
- `Model/Entity/MySQL/FiveGameTrans/MemberInbox.cs` / `OperatorInbox.cs` — already mapped. If GameServer needs to read inbox for any in-game display, this is the touch point — but spec **D9** says GameServer changes are out of scope for FRB; defer to GameServer team.

**Cutover prerequisite**
- Before deleting the subscribers, confirm with GameServer team that msg-center is the single source of FRB winning notification (popup + inbox). FRB will run an optional double-write window (outbox + Pub/Sub) to de-risk — see §4.

**[PARKED — bet-by-level]** — none expected. GameServer reads bet from ticket payload, not from threshold config.

---

## 4. Risks & cross-team coordination

Carried from [index.html §7.1](./index.html), tagged by where they bite:

| Risk | Owners | Notes |
|---|---|---|
| Backstage path for Suspend/Terminate/EndEarly (D6 unresolved) | FRB + Backstage | If backstage writes DB directly → CDC-style tracker. If backstage hits FRB API → outbox write inline. Decide before M2. |
| Cutover double-write window | FRB + GameServer + msg-center | Outbox + Redis Pub/Sub in parallel until GameServer cuts. Guard against duplicate winning push (idempotency key on msg-center side: suggest `frb-FrbWinning-{ticketId}`). |
| Q10 (inbox real-time ticket state) | FRB + msg-center | Blocker for M3.5 only. M1/M2 unblocked. Default to method A (FRB read API). |
| Shared Tournament outbox topic | FRB + msg-center | msg-center must route on `event_type`, not topic. |
| TicketStatus enum extension | FRB | Append 6/7; never renumber 1–5 (TINYINT-direct-persist). |
| Claim idempotency | FRB | Atomic via conditional UPDATE: `UPDATE free_round_bonus_ticket_details SET status = Claimed WHERE id = ? AND status = PendingClaim`. Claim is **per-level** (one detail row per claim). rowCount = 0 → already claimed / expired. msg-center may retry safely. |
| Claim past `expires_at` | FRB + msg-center | FRB returns explicit "expired" error; msg-center must surface it in inbox. |

---

## 5. Milestones (mirrors [index.html §7](./index.html))

| ID | Scope | Repos touched |
|---|---|---|
| M1 | Outbox publisher + enum extensions + DI wiring (no behaviour change yet) | free-round-bonus |
| M2 | Lifecycle events (ComingSoon / Welcome / Suspend / Terminate / EndEarly) | free-round-bonus, message-center-service |
| M3 | Claim flow — state machine, claim API, BetEventProcessor switch to `PendingClaim` + Winning outbox | free-round-bonus, message-center-service |
| M3.5 | Inbox real-time state refresh (Q10) | free-round-bonus, message-center-service |
| M4 | Retire `RedisNotificationPublisher` / `frb:ticket:pending` and GameServer subscribers | free-round-bonus, GameServer |
| **M5 [PARKED]** | Bet by level (Q7–Q9) | free-round-bonus (+ Valhalla proto, backstage) |

---

## 6. Open questions to track

- **Q7–Q9** — bet-by-level key shape, cross-game behaviour, schema location. **[PARKED]** until product clarifies.
- **Q10** — how msg-center pulls real-time ticket state. Default plan: FRB read API.
- **D6 follow-up** — backstage operation path (direct DB vs API) for Suspend/Terminate/EndEarly.

---

## 7. Doc usage convention

- This file is the **shared truth** between the three repos for this initiative.
- Each repo may keep its own implementation notes under its docs folder, but **cross-repo decisions land here first** and are linked back from repo-local docs.
- When updating: change the relevant `[ ]` → `[~]` → `[x]`, and note the linking PR in a trailing line. Resolve `[PARKED]` items only when product gives the green light on Q7–Q9.
