# message-center-service — Implementation Status

Companion to [index.html](./index.html), [cross-repo-changes.md](./cross-repo-changes.md), and [free-round-bonus-status.md](./free-round-bonus-status.md). Covers **only** the `message-center-service` repo (four .NET 10 projects: api, consumer, relay, emulator, plus shared library). Last updated: 2026-05-18.

Working branch: `feature/2026-05-18-alex-frb-enhance` (commit `2336286`).

---

## 1. Done

### 1.1 `EventType` enum extension — `CampaignWinning = 6`, `EndedEarly = 7`

FRB introduces two new values on top of the Tournament-era set (1–5). Both are wire-compatible: append-only, no renumbering.

| Value | Source | Routing | Behavior family |
|---|---|---|---|
| `CampaignWinning = 6` | FRB Winning event (per ticket-detail row) | `member_inbox` (payload carries `member_id`) | Like `PrizeSettled (1)` — independent per ticket, NOT a lifecycle event |
| `EndedEarly = 7` | FRB EndedEarly event (prize depleted) | `operator_inbox` (no `member_id` in payload) | Like `Suspended (2)` / `Terminated (3)` — campaign-lifecycle terminal |

Refs:
- Spec: [cross-repo-changes.md §3.2](./cross-repo-changes.md), [index.html §5.3](./index.html)
- FRB enum source: `FreeRoundBonus.Shared/Enums/InboxEventType.cs` (values 6/7 added in `dc54c60`)
- Code: `message-center-shared/Enums/EventType.cs`

### 1.2 Consumer routing — accepts FRB's PascalCase `type` strings

FRB emits the `type` field via `Enum.ToString()` (PascalCase like `"CampaignWinning"`, `"EndedEarly"`). Tournament + Emulator emit lowercase tokens (`"coming_soon"`, `"running"`). `MapTypeString` now accepts both styles.

| Token form | Resolves to |
|---|---|
| `suspend` / `Suspended` | `Suspended (2)` |
| `terminate` / `Terminated` | `Terminated (3)` |
| `coming_soon` / `ComingSoon` | `ComingSoon (4)` |
| `running` / `Running` | `Running (5)` |
| `campaign_winning` / `CampaignWinning` | `CampaignWinning (6)` — new |
| `ended_early` / `EndedEarly` | `EndedEarly (7)` — new |
| `prize_settled` / `PrizeSettled` | `PrizeSettled (1)` |

> The numeric `event_type` path is preferred (FRB sets both); the string fallback covers schema-loose producers and dev seeds.

Refs:
- Code: `message-center-consumer/ConsumerWorker.cs` (`MapTypeString`)

### 1.3 Unread-count buckets + popup eligibility re-grouped

Two badge categories in `/api/v1/inbox/unread_count`:

| Bucket | Old set | New set | Rationale |
|---|---|---|---|
| `promotion` (eye-catcher) | {4, 5} | **{4, 5, 6}** | CampaignWinning is action-required (PLAY NOW / PLAY LATER) — belongs in the high-attention bucket |
| `inbox` (history) | {1, 2, 3} | **{1, 2, 3, 7}** | EndedEarly is a terminal status, like Terminated |
| popup-eligible | (1, 4, 5) | **(1, 4, 5, 6)** | CampaignWinning triggers the in-game popup |
| non-popup | (2, 3) | (2, 3, 7) | EndedEarly updates badges silently, no popup |

Refs:
- Code: `message-center-api/Repositories/MemberInboxRepository.cs`
  (`GetPromotionUnreadCountAsync`, `GetInboxUnreadCountAsync`, `GetLatestPopupAsync`)

### 1.4 Lifecycle supersession + cascade — EndedEarly joins the chain

A campaign now has 5 lifecycle terminals: `Suspended (2)`, `Terminated (3)`, `ComingSoon (4)`, `Running (5)`, **`EndedEarly (7)`**. The "newer lifecycle exists" check (`NewerLifecycleExistsForMember/Operator`) and the cascade-on-MarkAsRead query (`CascadeReadOlderLifecycleAsync` in both repositories + the controller guard) all widen from `IN (2,3,4,5)` to `IN (2,3,4,5,7)`.

`PrizeSettled (1)` and `CampaignWinning (6)` are deliberately **excluded** — each prize period stands alone, each ticket-detail stands alone. Neither marks older lifecycle events stale, and neither cascades.

Three places touched:

| Site | Purpose |
|---|---|
| `MemberInboxRepository.NewerLifecycleExistsForMember` (const) | Dynamic Status in `GetCombinedPageAsync` + suppression in count/popup |
| `MemberInboxRepository.NewerLifecycleExistsForOperator` (const) | Same, for operator_inbox |
| `MemberInboxRepository.CascadeReadOlderLifecycleAsync` (SQL UPDATE) | Cascade member-side lifecycle reads |
| `OperatorInboxRepository.CascadeReadOlderLifecycleAsync` (SQL SELECT) | Cascade operator-side lifecycle reads (INSERT IGNORE into `operator_inbox_read`) |
| `InboxController.CascadeReadOlderLifecycleAsync` (C# guard) | Trigger check: `EventType is (2 or 3 or 4 or 5 or 7)` |

Refs:
- Spec: [cross-repo-changes.md §3.2](./cross-repo-changes.md), [index.html §5.4](./index.html)
- Code: `message-center-api/Repositories/{Member,Operator}InboxRepository.cs`, `message-center-api/Controllers/InboxController.cs`

### 1.5 Dev/Emulator UX surface

| Site | Change |
|---|---|
| `message-center-api/Controllers/DevController.cs` | Mock SSE `/api/v1/dev/sse/mock-stream` now cycles 7 scenarios (was 5) — CampaignWinning added with `Popup=true`, EndedEarly with `Popup=false`. Mirrors prod popup eligibility for client SSE handler dev. |
| `message-center-emulator/wwwroot/index.html` | The `event_type` `<select>` dropdown was stale (showed `1=FRB Campaign / 2=Win / 4=System / 8=Promo` — values that never matched the real enum). Replaced with the 7 actual `EventType` values. Operator/member message routing is automatic via `member_id` presence — unchanged. |

Refs:
- Code: `message-center-api/Controllers/DevController.cs`, `message-center-emulator/wwwroot/index.html`

### 1.6 Schema + docs comment refresh

| Site | Change |
|---|---|
| `docker/mysql/init.sql` | `event_type` column COMMENT for both `member_inbox` and `operator_inbox` extended: `'... 5.Running 6.CampaignWinning 7.EndedEarly'`. No DDL alter (TINYINT already covers values 0–127). |
| `CLAUDE.md` | `/unread_count` endpoint description, `member_inbox.event_type` value list, and "Lifecycle Event Read Semantics" paragraph (mentions EndedEarly + CampaignWinning carve-out). |

### 1.7 Tests — 164 → 170, all green

New coverage:

| Test | Asserts |
|---|---|
| `ConsumerWorkerTests.ProcessMessage_NumericEventType6_MapsToCampaignWinning` | Numeric `event_type=6` → `EventType.CampaignWinning`; member_inbox routing |
| `ConsumerWorkerTests.ProcessMessage_NumericEventType7_MapsToEndedEarly` | Numeric `event_type=7` → `EventType.EndedEarly`; operator_inbox routing |
| `ConsumerWorkerTests.ProcessMessage_PascalCaseTypeCampaignWinning_MapsToEventType6` | String `type="CampaignWinning"` fallback mapping |
| `ConsumerWorkerTests.ProcessMessage_PascalCaseTypeEndedEarly_MapsToEventType7` | String `type="EndedEarly"` fallback mapping |
| `InboxControllerTests.MarkAsRead_EndedEarly_CascadesOlderOnMemberInbox` | Marking EndedEarly as read cascades older same-campaign lifecycle events |
| `InboxControllerTests.MarkAsRead_CampaignWinning_DoesNotCascade` | CampaignWinning does NOT cascade (parity with PrizeSettled) |

Refs:
- Tests: `message-center-tests/Consumer/ConsumerWorkerTests.cs`, `message-center-tests/Api/Controllers/InboxControllerTests.cs`

---

## 2. Parked for future work

### 2.1 M3.5 — Inbox row real-time ticket state (Q10 follow-up)

When the player re-opens the inbox days after a CampaignWinning landed, the row needs to reflect the **current** ticket state (used / claimed / expired / still claimable) — but the body JSON is a frozen snapshot from the moment of issuance.

Three approaches in spec [§5.4](./index.html):

| Option | Plan | Status |
|---|---|---|
| **A. (recommended)** | On `/get_list` (or per-row hydration), msg-center calls FRB `GET /api/frb/tickets?member_id=&status=` and merges live fields (`used_rounds`, `remaining_rounds`, `status`, etc.) into the response | Not started — needs alignment with FRB on response shape + caching strategy |
| B. | FRB emits a per-state-transition outbox event; msg-center keeps a local mirror of ticket state | High traffic, needs aggregation; rejected |
| C. | msg-center subscribes to FRB Redis Pub/Sub | Violates [D1](./index.html) (Redis pub/sub retired); rejected |

When unblocked, expected work in this repo:
- New `IFreeRoundBonusClient` (typed HttpClient) under `message-center-api/Infrastructure/` calling FRB's read API
- Response merge logic in `InboxController.GetList` and possibly `BuildEnrichedPayloadAsync` (SSE)
- Cache strategy (per-request vs short-TTL) — FRB call latency budget needs measuring before deciding
- Tests for stale-fallback (FRB unreachable → return body snapshot only)

### 2.2 PLAY NOW callback endpoint

Spec [§3.2 row 4](./cross-repo-changes.md): msg-center should expose an endpoint the client hits when the player taps PLAY NOW (popup OR inbox). It proxies to FRB's claim API:

```
POST /api/frb/tickets/{ticketId}/levels/{level}/claim
```

Why proxy through msg-center (rather than client → FRB direct):
- Keeps the client's "API surface" homogeneous (single host, single auth scheme)
- Centralizes idempotency logging
- Lets msg-center mark the inbox row as read on a successful claim without a second roundtrip

Not started. Depends on FRB M3 (claim API exists). Tracking under the same M3 milestone.

### 2.3 Body payload extraction for FRB Winning fields

`InboxController.ExtractFromBody` currently digs only `campaign_id` and `campaign_period_id` out of the stored `body` JSON. FRB Winning payloads carry several more fields the client likely wants surfaced at the response root (not inside opaque `body`):

| Field | Spec source | Use |
|---|---|---|
| `ticket_id`, `ticket_detail_id` | [index.html §5.3](./index.html) | Identify the claimable ticket for PLAY NOW callback |
| `level` | §5.3 | Which threshold level was hit |
| `game_id`, `game_name` | §5.3 (Figma) | "Win on Buffalo King!" copy |
| `bet_cents`, `reward_count`, `max_payout_cents` | §5.3 | Number rendering on popup card |
| `expires_at` | §5.3 | Countdown + auto-hide |

Two options when this is implemented:
- A) Extend `ExtractFromBody` + add typed columns to the response DTO
- B) Pass the full `body` JsonElement to the client and let it parse

Lean toward A so the client doesn't need to know about FRB internals. Not started.

### 2.4 `expired_at` column not yet populated from FRB body

FRB Winning carries `expires_at` (ticket claim deadline). The consumer currently leaves `member_inbox.expired_at` NULL. If we want the row auto-cleaned at ticket expiry, `ConsumerWorker.ProcessMessage` should `TryGetProperty("expires_at", ...)`-extract it and pass to `InboxMessage.ExpiredAt`. Trivial change, deliberately deferred until §2.3 lands (they touch the same code path).

### 2.5 Shared `msg-center-events` topic routing (D2 confirmation)

Tournament and FRB now share the `msg-center-events` Kafka topic. The consumer already routes by `event_type` (numeric or string) inside the payload — **not** by topic, partition, or any other Kafka-level metadata. Confirmed compatible. No work needed; flagged for awareness when FRB lifecycle traffic ramps up.

### 2.6 [PARKED — bet-by-level] inbox payload key naming

If FRB's eventual bet-by-level work (spec Q7–Q9, M5) introduces per-level bet keys in the Winning payload, the inbox display path (§2.3 above) needs to match the final key names. Not blocked by anything in this repo; flagged so the §2.3 work doesn't bake in a key shape that'll need renaming.

---

## 3. Commit log

| Commit | Subject | Scope |
|---|---|---|
| `2336286` | Add CampaignWinning and EndedEarly event types for FRB integration | 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7 |

170 → 170 tests after the changes (6 new tests added, all green; 0 existing tests modified or broken).

---

## 4. Out-of-scope items deliberately untouched in this branch

For completeness, these are spec-adjacent things we did **not** modify on `message-center-service`:

- **free-round-bonus repo** — FRB's responsibility. See [free-round-bonus-status.md](./free-round-bonus-status.md).
- **GameServer** — separate team owns the cutover from `frb:ticket:pending` Redis pub/sub. See [cross-repo-changes.md §3.3](./cross-repo-changes.md).
- **`expired_at` cleanup job** — there's no expired-row cleanup worker in this repo today. Adding one is independent of the FRB work; deferred.
- **Operator inbox `scope_filter`** — the audience-filter column exists but is not yet read on the API side. Out of scope for FRB lifecycle (which targets all members of the operator).
- **JWT/auth on `/api/v1/inbox/stream`** — `SseJwtValidator` exists with a query-param fallback for dev; tightening this is operational, not feature-related.
