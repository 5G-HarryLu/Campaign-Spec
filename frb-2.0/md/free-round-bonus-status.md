# free-round-bonus — Implementation Status

Companion to [index.html](./index.html) and [cross-repo-changes.md](./cross-repo-changes.md). Covers **only** the `free-round-bonus` repo (`Campaign` and `FreeRoundBonus.Shared` projects). Last updated: 2026-05-20.

Working branch: `feature/2026-05-15-alex-frb-enhance` (commits `dc54c60..da106d1`).

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
| ~~`TicketStatus`~~ | ~~`PendingClaim = 6`, `Claimed = 7`~~ — **TO BE REVERTED (M3)** | No code writes them; superseded by the 5-enum + `claimed_at` model |
| ~~`TicketStatusConverter`~~ | ~~string `pending_claim` / `claimed`, int 6 / 7~~ — **revert with the enum** | — |
| `InboxEventType` | `CampaignWinning = 6` | M3 — **keep** (different enum from `TicketStatus`) |
| `InboxEventType` | `EndedEarly = 7` | Inline emit (1.2) — active — **keep** |

> **FSM model decided 2026-06-05** — `TicketStatus` stays at `1..5`; the `6/7` above are reverted on the M3 branch. Claim is a **`claimed_at` timestamp** (PLAY NOW only), not a status value; `Pending=1` is the inbox/awaiting-claim state and no longer blocks accumulation. **Do not confuse with `InboxEventType` 6/7, which is a separate enum and stays.**
> Wire-compat note: `TicketStatus` is a `byte` stored as TINYINT. Values 1–5 are unchanged.

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

### 1.7 M5 — Bet-by-level resolution

Q7/Q9 resolved by the DB: a `level INT NOT NULL DEFAULT 0` column was added to `campaign_operator_game_chips`, keying chips/bet by `(campaign_id, operator_id, game_id, level)`. Live MySQL already has multi-level rows (e.g. campaign `1e7b0527-…` carries levels 1–4 with distinct bets like `1:0.60, 2:9.00, 3:50.00, 4:300.00`), confirming Q7 = `(campaign, operator, game, level)` and Q9 = extend `campaign_operator_game_chips` (not `campaign_threshold_currency`, not a new table). Q8 stays as **per-game-within-a-level** because the row grain is per-game already — same level on two games can have different bets.

| Aspect | Before | After |
|---|---|---|
| Lookup key | `(campaign_id, operator_id, game_id)` | `(campaign_id, operator_id, game_id, level)` |
| Caller passes | n/a | `threshold.Level` (i.e. the player's qualifying level) |
| TicketService.CreateTicketsAsync | Resolves chips for level 1 indirectly | Passes `threshold.Level` (always `1` for this entry path) |
| BetEventProcessor | One bet per (campaign, operator, game) | Reads the row for the level the player just qualified for |
| Repository surface | `IConfigRepository.GetGameChipsConfigAsync` (DAL gRPC) | **New** `IFrbConfigRepository.GetGameChipsConfigByLevelAsync` (direct MySQL/Dapper) |

**Why a new repository instead of changing `IConfigRepository`:** the existing RPC is shared with non-FRB callers (Aggregator, Tournament) and must not silently change shape. Keeping the FRB-specific lookup on its own interface lets non-FRB code continue calling the legacy single-row method without carrying a level argument.

**Why direct MySQL today:** the Valhalla DAL `GetGameChipsConfig` RPC doesn't carry `level` (see `Valhalla/Sleipnir/repository/campaign_operator_game_chips_repo.go` — `WHERE campaign_id = ? AND operator_id = ? AND game_id = ?`). Rather than expand the proto in this branch, FRB reads MySQL directly via Dapper. Phase N+1 will move this to a level-aware DAL method and delete the direct-DB read here. The two RPCs coexist cleanly until then.

Refs:
- Spec: §1.3, §3.1 Q7–Q9, §7 M5
- Code:
  - `src/Campaign/Application/Interfaces/IFrbConfigRepository.cs` (new)
  - `src/Campaign/Infrastructure/MySQL/FrbConfigRepository.cs` (new — direct Dapper)
  - `src/Campaign/Domain/Entities/GameChipsConfig.cs` (added `Level`)
  - `src/Campaign/Application/Services/TicketService.cs` (consumes `IFrbConfigRepository`; `IConfigRepository` no longer injected here)
  - `src/Campaign/Application/Services/BetEventProcessor.cs` (consumes `IFrbConfigRepository` alongside `IConfigRepository`; the latter still holds `GetOperatorCurrencySnAsync`)
  - `src/Campaign/Program.cs` (DI registration)
- The three former `TODO(FRB-2.0 M5 — bet-by-level)` markers are removed.

---

## 2. Parked for future work

### 2.1 M3 — Claim flow

Not started in this branch. Spec §7 M3 covers it. Needed for:

| Piece | Status |
|---|---|
| **Revert** `TicketStatus.PendingClaim/Claimed` (6/7) + their `TicketStatusConverter` mappings | Not started |
| `free_round_bonus_ticket_details` DDL: add `claimed_at timestamp NULL` (+ detail-level `expired_at`) | Not started |
| `TicketStateMachine` — **no new transitions**; claim sets `claimed_at`, status stays `Pending` | Not started |
| `TicketClaimService` (idempotent claim via CAS `SET claimed_at WHERE status=Pending AND claimed_at IS NULL`) | Not started |
| `TicketClaimController` exposing `POST /api/frb/tickets/{ticketId}/levels/{level}/claim` (PLAY NOW only) | Not started |
| `BetEventProcessor` change: threshold-met creates `status = Pending, claimed_at=NULL`; stop blocking accumulation | Not started |
| `TicketBuilder.StatusEnum = Pending` (claimed_at null) | Not started |
| `FrbOutboxMsgPublisher.PublishWinningAsync` first caller | Wired but unused |

> **✅ FSM model decided (2026-06-05) — keep 5 enums + `claimed_at`.** Status stays `1..5`; `Pending=1` *is* the "in inbox, awaiting claim" state (semantics updated: no longer blocks accumulation). **claim = PLAY NOW only** → CAS-set `claimed_at` (`WHERE status=Pending`), status unchanged; first spin → `InUse`. **PLAY LATER does not claim** (ticket stays `Pending, claimed_at=NULL`). Distinguish the two buckets by `claimed_at IS NULL` vs `IS NOT NULL`. The shipped `PendingClaim=6`/`Claimed=7` are **reverted in this M3 work** (see the first table row). This is simpler than 6/7 and meets the "identify granted-but-unclaimed vs claimed-but-not-played" requirement. *(`InboxEventType` 6/7 is a different enum — keep it.)*

**Concurrency / claim idempotency (decided 2026-06-05):** a player can **multi-open different games at once**, and one FRB campaign can **target multiple games**, so same-game "後踢前 single session" does **not** guarantee a single claimer. Protection is **FSM + CAS** under the DB's exclusive row lock: the conditional `UPDATE … SET status = <claimed> WHERE id = ? AND status = <pending>` lets exactly one caller see `affected = 1`; everyone else sees `0` (already claimed / expired). `idempotencyKey` guards double-click / resend. **No `version` / optimistic-lock column** is added.

### 2.2 M3.5 — Inbox real-time ticket state (Q10)

Blocker for the inbox-row USED/expired UI. Three candidate approaches in spec §5.4:

- **A.** FRB exposes a read API (`GET /api/frb/tickets?member_id=&status=`) — recommended in the spec
- **B.** Per-state-transition outbox events — high traffic, needs aggregation
- **C.** msg-center subscribes to FRB Redis channels — violates D1

**Decided (2026-06-05) = A.** Implement as a **new web API on free-round-bonus**, same pattern as the existing APIs FRB already exposes to PlatformApi. It reads **Redis** (`frb:inventory:*` / `frb:ticket:*`) and returns live `used_rounds` / remaining / `expired_at`, so callers (msg-center, PlatformApi) get real-time values without understanding FRB internals. Remaining work is just the controller + read path; implementation details still to align with the msg-center team.

### 2.3 M4 — Retire `RedisNotificationPublisher` / `frb:ticket:pending`

The remaining FRB Redis publish (ticket-issued notification → GameServer) is still in place at `src/Campaign/Infrastructure/Redis/RedisNotificationPublisher.cs`. It retires only after:

1. M3 wires `PublishWinningAsync` so msg-center receives the threshold-met event
2. GameServer cuts over to consuming via msg-center (their team owns this per D9)

Then this branch deletes:
- `RedisNotificationPublisher.cs`
- `INotificationPublisher` interface
- `Campaign.Domain.ValueObjects.TicketNotification`
- DI registrations
- `RedisKeys.TicketPendingChannel` constant

### 2.4 Backstage operation path for Suspend / Terminate (D6 detail)

Spec §7.1 risk row: "後台操作路徑". Today the FRB tracker assumes backstage flips `campaign.status` directly in MySQL (CDC-style detection). If backstage actually goes through a FRB API instead, the tracker still catches it via sync diff — but the latency window equals one sync interval. Decision pending backstage team confirmation.

### 2.5 Shared `outbox_msg` topic routing (D2)

`OutboxMsgOptions.Topic` defaults to `"msg-center-events"`, shared with Tournament. Spec §7.1: "msg-center 端依 `event_type` 而非 topic 路由". Need msg-center team to confirm their routing is `event_type`-based, not topic-based, before high-traffic FRB lifecycle volume joins the shared topic.

### 2.6 EndedEarly — `end_reason` propagation through DAL sync

Today EndedEarly is emitted inline (1.2) because the sync proto doesn't carry `end_reason`. If a future requirement needs EndedEarly to fire from non-FRB code paths (e.g. an admin tool that writes the column directly), the cleanest fix is to add `end_reason` to `CampaignSyncItem` in Valhalla's proto. Not blocking; flagged for awareness.

### 2.7 DAL: level-aware `GetGameChipsConfig`

§1.7 ships `IFrbConfigRepository.GetGameChipsConfigByLevelAsync` as a **direct MySQL/Dapper** read so we don't have to round-trip a proto change through Valhalla in the same branch. The follow-up is straightforward and additive:

1. Extend `GetGameChipsConfigRequest` with `uint32 level = 4` and `GetGameChipsConfigResponse` with `uint32 level = 6` in `src/Campaign/Infrastructure/Protos/campaign.proto`.
2. Update Valhalla's `CampaignOperatorGameChipsRepoInterface.Get` to take `Level` and add `AND level = ?` to the GORM query.
3. Re-point `FrbConfigRepository.GetGameChipsConfigByLevelAsync` at the new DAL call; delete the direct `IDbConnection` dependency and the inline SQL.

No `level` overload is added to the legacy single-row `IConfigRepository.GetGameChipsConfigAsync` because non-FRB callers don't need it. Coordinate the proto bump with the DAL team before flipping FRB over.

---

## 3. Commit log

| Commit | Subject | Scope |
|---|---|---|
| `dc54c60` | feat: M1 — FRB outbox publisher + state and event enum scaffolding | 1.3, 1.4 |
| `a0cbbd3` | refactor: rename Outbox → OutboxMsg to match outbox_msg table | 1.5, 1.6 |
| `096279e` | feat: M2 — FRB lifecycle event emission | 1.1 (initial), 1.2 |
| `3a330b5` | refactor: merge FRB lifecycle outbox emit into MySqlCampaignInfoService | 1.1 (correction) |
| `3ae84da` | refactor: retire frb:campaign:status_changed Redis pub/sub | 1.1 (final) |
| `da106d1` | feat: M5 — FRB bet/chips by level via FrbConfigRepository | 1.7 |

554 → 551 → 553 tests (added two for `FrbConfigRepository`); all green.

---

## 4. Out-of-scope items deliberately untouched in this branch

For completeness, these are spec-adjacent things we did **not** modify on `free-round-bonus`:

- **GameServer / GameClient code** — spec D9; their team owns the cutover.
- **msg-center service** — spec D1; their team owns the consumer side. See [cross-repo-changes.md §3.2](./cross-repo-changes.md).
- **`Aggregator/Infrastructure/Redis/RedisBetEventPublisher`** — internal bet-event pipeline, not player-facing.
- **`Tournament.Infrastructure.Redis.RedisMemberWalletNotifier`** and **`Campaign.Api.MembersController` `member:wallet:refresh` publish** — wallet refresh path, unrelated.
- **Reminder mechanism** — **decision updated 2026-06-05: removed entirely.** The whole reminder mechanism is dropped — both the activity end-countdown reminder and the reconnect/re-enter reminder & redirect. Back Office reminder fields are pulled; any reconnect-redirect that's still wanted becomes a pure front-end concern. (Supersedes the earlier D7 "先不動 schema, 之後再處理".)
