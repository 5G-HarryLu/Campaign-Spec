# Super Gems Jackpot — DDL Scripts (v4.0 / 每日增量盤中注入)

依 [規格 Ch05 — Data Model](./index.html#p5) 產出的建表語法,供手動建立。可執行腳本另見 [sql/jackpot_mysql.sql](./sql/jackpot_mysql.sql)、[sql/jackpot_oceanbase.sql](./sql/jackpot_oceanbase.sql);MongoDB 集合見文末。

**共 9 張:MySQL 5 + OceanBase 3 + MongoDB 1**

- **MySQL 5**（config 真值、低頻寫）：`jackpot_pool_group`、`jackpot_game_mapping`、`jackpot_operator_setting`、`jackpot_config`、`jackpot_admin_audit`
- **OceanBase 3**（權威帳本、高頻寫）：`jackpot_round`、`accounting_jackpot`、`jackpot_daily_increment`
- **MongoDB 1**（warm DB、時序、本服務直連）：`jackpot_pool_snapshot`

> v2 相對前版的主要變動:①`jackpot_win` → **`accounting_jackpot`**(注單類慣例,身分欄位 join accounting、無 payout 狀態機);②**刪 `jackpot_fx_rate`**(改用既有 `currency.fixed_rate`);③**snapshot 移 MongoDB**;④config **就地更新不留版本**(`UQ(pool,tier)`);⑤PK 慣例 = 自增 `sn`,唯一性用 UNIQUE。

## 通則（全表適用）

- 字元集：`utf8mb4` / `utf8mb4_unicode_ci`
- **時間欄位**（MCP 實測兩庫慣例）：
  - **MySQL**：`TIMESTAMP`。`explicit_defaults_for_timestamp = ON`,`TIMESTAMP NOT NULL` 無隱式 `DEFAULT`/`ON UPDATE`。`created_at` = `TIMESTAMP NOT NULL`(無 default);`updated_at` = `TIMESTAMP NULL`。
  - **OceanBase**：`TIMESTAMP(3)`。`created_at` = `TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)`(⚠ 精度須匹配 `(3)`,否則 OceanBase 報 1067 Invalid default value);`updated_at` = `TIMESTAMP(3) NULL`。
  - 其餘事件時間(`opened_at`/`closed_at`…)依語意 NULL / NOT NULL;值一律 **UTC**,應用層寫入。`rate_date` 為 `DATE`,不套用。
- 金額精度：ppm（累積速率/RTP）、ppb（FX）、micro-cents（池值,= USD cent × 10⁻⁶）、cents（一般金額）；全整數
- 主鍵慣例（five_game）：ObjectId 命名 `id`(`VARCHAR(24)`)、自增序號命名 `sn`(`BIGINT UNSIGNED AI`);唯一性用 UNIQUE,不以資料欄位當 PK
- FX：不建 jackpot 匯率表,用既有 `currency.fixed_rate`
- 本 DDL **不含**須「修改的既有表」`game_math` / `game_feature_support`（GameServer 側遷移),亦不含共用 `outbox_msg`、`accounting`、`currency`

> ⚠ OceanBase 相容 MySQL 語法;分區 / replica / locality 規格未定義,依環境 DBA 慣例另補。

---

## MySQL（5 張）

### 1. jackpot_pool_group — PoolGroupID 主檔

```sql
CREATE TABLE `jackpot_pool_group` (
  `id`         VARCHAR(24)      NOT NULL COMMENT 'ObjectId,與 campaign 慣例一致',
  `name`       VARCHAR(64)      NOT NULL COMMENT 'pool 顯示名稱',
  `status`     TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '0=disabled、1=active',
  `created_at` TIMESTAMP        NOT NULL COMMENT 'UTC',
  `updated_at` TIMESTAMP        NULL     COMMENT 'UTC',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='彩金群組主檔(Option B:每 game group 一個隔離池)';
```

### 2. jackpot_game_mapping — game → pool 對應

```sql
CREATE TABLE `jackpot_game_mapping` (
  `sn`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '自增序號(慣例:不以資料欄位當 PK)',
  `game_id`       VARCHAR(64)     NOT NULL COMMENT '一個 game 只屬一個 pool(會議防呆,UNIQUE 強制)',
  `pool_group_id` VARCHAR(24)     NOT NULL COMMENT '所屬池',
  `created_at`    TIMESTAMP       NOT NULL COMMENT 'UTC',
  PRIMARY KEY (`sn`),
  UNIQUE KEY `uq_game_id` (`game_id`),
  KEY `ix_pool_group_id` (`pool_group_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='寫入語意=full-set replace(UpsertJackpotGameMapping);跨池衝突整批拒絕';
```

### 3. jackpot_operator_setting — per-operator 開關 + RTP

```sql
CREATE TABLE `jackpot_operator_setting` (
  `sn`                   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '自增序號(慣例:不用複合 key 當 PK)',
  `pool_group_id`        VARCHAR(24)     NOT NULL COMMENT '所屬池',
  `operator_id`          VARCHAR(64)     NOT NULL COMMENT 'operator',
  `enabled`              TINYINT(1)      NOT NULL DEFAULT 0 COMMENT 'per-operator 開關;operator×game 交集才生效',
  `rtp_ppm_by_tier_json` VARCHAR(128)    NOT NULL DEFAULT '{}' COMMENT 'RTP by operator×獎項(260715-1),如 {"1":9600,"2":9700};餵 GE 算 Prob=RTP/Price',
  `updated_by`           VARCHAR(64)     NOT NULL COMMENT '後台操作者',
  `created_at`           TIMESTAMP       NOT NULL COMMENT 'UTC',
  `updated_at`           TIMESTAMP       NULL     COMMENT 'UTC',
  PRIMARY KEY (`sn`),
  UNIQUE KEY `uq_pool_operator` (`pool_group_id`, `operator_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='RTP by operator、不 by game;pool 值仍是 global house 池';
```

### 4. jackpot_config — 累積速率 / seed / cap / quota（就地更新,不留版本）

```sql
CREATE TABLE `jackpot_config` (
  `sn`                    BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT '自增序號(慣例:自增 PK 命名 sn)',
  `pool_group_id`         VARCHAR(24)      NOT NULL COMMENT '所屬池;就地更新、不留版本(變更軌跡=admin_audit before/after)',
  `tier`                  TINYINT UNSIGNED NOT NULL COMMENT '1=grand、2=major、3=minor、4=mini(四層皆 option);Super Gems 首發只開 1/2',
  `contribution_rate_ppm` INT UNSIGNED     NOT NULL COMMENT '累積速率 ppm(入池方向,原 rtp_ppm);與中獎 RTP 是兩個獨立旋鈕,不校核',
  `min_per_day_cents`     BIGINT UNSIGNED  NOT NULL DEFAULT 0 COMMENT '最低每日累積 floor(USD cents):昨日 turnover 低於此則以此計',
  `reset_min_cents`       BIGINT UNSIGNED  NOT NULL COMMENT '中獎/撞頂後 seed(USD cents):Grand $20k / Major $2k',
  `reset_threshold_cents` BIGINT UNSIGNED  NOT NULL COMMENT '池增長硬上限 cap(USD cents):撞頂 reset + 溢位補 seed + 假中獎廣播',
  `roll_range_json`       VARCHAR(64)      NULL     COMMENT 'PoolTicker 盤中滾動 range(min/max step),供顯示用',
  `win_count_quota`       INT UNSIGNED     NOT NULL COMMENT '中獎名額:Grand 1 / Major 100。軟限流:quota<1 機率趨零但可為負,非硬上限',
  `updated_by`            VARCHAR(64)      NOT NULL COMMENT '後台操作者',
  `created_at`            TIMESTAMP        NOT NULL COMMENT 'UTC',
  `updated_at`            TIMESTAMP        NULL     COMMENT 'UTC',
  PRIMARY KEY (`sn`),
  UNIQUE KEY `uq_pool_tier` (`pool_group_id`, `tier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='config 就地更新(UQ(pool,tier));RTP 不在此,見 jackpot_operator_setting';
```

### 5. jackpot_admin_audit — 後台稽核

```sql
CREATE TABLE `jackpot_admin_audit` (
  `id`            VARCHAR(24) NOT NULL COMMENT '稽核識別',
  `action`        VARCHAR(32) NOT NULL COMMENT 'rpc 名(7 個受稽核 rpc);與 config 寫入同交易原子',
  `pool_group_id` VARCHAR(24) NULL     COMMENT '範圍(可空,如 fx_update 等 pool 無關列)',
  `tier`          TINYINT     NULL     COMMENT '範圍(可空)',
  `before_json`   TEXT        NULL     COMMENT '變更前值',
  `after_json`    TEXT        NULL     COMMENT '變更後值',
  `operator`      VARCHAR(64) NOT NULL COMMENT '後台操作者',
  `created_at`    TIMESTAMP   NOT NULL COMMENT 'UTC',
  PRIMARY KEY (`id`),
  KEY `ix_pool_created` (`pool_group_id`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='僅於狀態實際變更時寫入;data-plane 排除';
```

---

## OceanBase（3 張）

> Valkey 是投影;真相在此,恢復與稽核都從這裡出發。

### 6. jackpot_round — 回合狀態機（恢復錨點）

```sql
CREATE TABLE `jackpot_round` (
  `id`                                     VARCHAR(24)      NOT NULL COMMENT 'round 識別(ObjectId)',
  `pool_group_id`                          VARCHAR(24)      NOT NULL COMMENT '所屬池',
  `tier`                                   TINYINT UNSIGNED NOT NULL COMMENT '1=grand、2=major、3=minor、4=mini',
  `round_seq`                              INT UNSIGNED     NOT NULL COMMENT '回合序號;UNIQUE 防重開',
  `seed_microcents`                        BIGINT UNSIGNED  NOT NULL COMMENT '本回合 seed(micro-cents)',
  `opened_increment_watermark_microcents`  BIGINT UNSIGNED  NOT NULL COMMENT '開啟當下 cum_increment 錨點 — 池值合成公式用',
  `quota_remaining_at_open`                INT              NOT NULL COMMENT '開啟當下 quota;Valkey 遺失時 quota=此值 − count(wins in round)',
  `status`                                 TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '1=open、2=hit(含撞頂 reset)、3=closed(manual reset)',
  `clamp_overflow_microcents`              BIGINT UNSIGNED  NULL     COMMENT '觸頂溢出累計(對帳公式顯式項,唯一記錄點)',
  `opened_at`                              TIMESTAMP(3)     NOT NULL COMMENT 'UTC',
  `closed_at`                              TIMESTAMP(3)     NULL     COMMENT 'UTC',
  `created_at`                             TIMESTAMP(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT 'UTC(貼 OB 表慣例補上;規格僅列 opened_at/closed_at)',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pool_tier_seq` (`pool_group_id`, `tier`, `round_seq`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='RotateJackpotRound 關舊開新單交易;UNIQUE(pool,tier,round_seq) 防重開;config 無版本,不記 config_version';
```

### 7. accounting_jackpot — 中獎名單（原 jackpot_win 改名,注單類慣例）

> 同事 review:比照 `accounting_bonus`。身分欄位(operator/member/game/幣別)**不重複存 — join accounting 取得**(中獎稀疏,join 無負擔)。**無 payout 狀態機**(SettleWin 同步結算、GS 當場賠付;credit⟷本表對帳兜底)。

```sql
CREATE TABLE `accounting_jackpot` (
  `id`                           VARCHAR(24)      NOT NULL COMMENT 'win_id(ObjectId);GE 上報冪等鍵、亦是派彩全鏈冪等鍵',
  `accounting_id`                VARCHAR(24)      NOT NULL COMMENT '觸發中獎的注單號(GE 上報帶入,平台語彙);供會員下注紀錄查詢',
  `pool_group_id`                VARCHAR(24)      NOT NULL COMMENT '所屬池',
  `tier`                         TINYINT UNSIGNED NOT NULL COMMENT '層',
  `round_id`                     VARCHAR(24)      NOT NULL COMMENT '所屬回合',
  `win_amount_usd_cents`         BIGINT UNSIGNED  NOT NULL COMMENT '中獎金額(USD)=本服務原子結算值(server 為準);須併入 total win',
  `win_amount_local_cents`       BIGINT UNSIGNED  NOT NULL COMMENT '當地幣別金額(結算當下以 currency.fixed_rate 換算一次,不可重算)',
  `pool_value_at_hit_microcents` BIGINT UNSIGNED  NOT NULL COMMENT '結算當下池值(micro-cents 精度來源;win_amount=此值÷1e6 floor)',
  `created_at`                   TIMESTAMP(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT 'UTC。無 payout_status:SettleWin 同步結算、GS 當場賠付',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pool_tier_accounting` (`pool_group_id`, `tier`, `accounting_id`),
  KEY `ix_round_id` (`round_id`),
  KEY `ix_pool_tier_created` (`pool_group_id`, `tier`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='中獎名單;身分欄位 join accounting 取得(比照 accounting_bonus);UNIQUE(pool,tier,accounting_id):同筆注單同 tier 不可重複中';
```

### 8. jackpot_daily_increment — 每日增量（對帳錨點）

```sql
CREATE TABLE `jackpot_daily_increment` (
  `sn`                    BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT '自增序號(慣例)',
  `pool_group_id`         VARCHAR(24)      NOT NULL COMMENT '所屬池',
  `tier`                  TINYINT UNSIGNED NOT NULL COMMENT '層',
  `rate_date`             DATE             NOT NULL COMMENT 'UTC 日界',
  `source_turnover_cents` BIGINT UNSIGNED  NOT NULL COMMENT '前一日 turnover(USD cents);以 currency.fixed_rate 換算(無版本欄位)',
  `increment_microcents`  BIGINT UNSIGNED  NOT NULL COMMENT '當日總增量 = turnover × 累積速率(contribution_rate_ppm)',
  `created_at`            TIMESTAMP(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT 'UTC',
  PRIMARY KEY (`sn`),
  UNIQUE KEY `uq_pool_tier_date` (`pool_group_id`, `tier`, `rate_date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='DailyIncrementJob 每日落帳(UQ 冪等、可重算錨點);當日總增量交 PoolTicker 盤中分次注入 Valkey input;對帳 Σ 錨點';
```

---

## MongoDB（1 集合）

### 9. jackpot_pool_snapshot — 彩金滾動紀錄 / 恢復加速

> 移 MongoDB(warm DB),**本服務直寫直讀(不經 DAL)**;每分鐘一筆(每 pool×tier 每日 ~1,440 筆),TTL index 解保留期。權威仍是 round / daily_increment / accounting_jackpot。

**文件結構（欄位)**

| 欄位 | 型別 | 說明 |
|---|---|---|
| `_id` | ObjectId | Mongo 預設 |
| `pool_group_id` | string | 池 |
| `tier` | int | 層 |
| `snapshot_at` | Date | 快照時間(UTC) |
| `round_id` | string | 所屬回合 |
| `value_microcents` | long | 合成池值(exhausted 由 quota≤0 推導) |
| `quota_remaining` | int | 剩餘名額 |

**索引(mongosh)**

```js
// 唯一索引(冪等):同 pool×tier×snapshot_at 只一筆
db.jackpot_pool_snapshot.createIndex(
  { pool_group_id: 1, tier: 1, snapshot_at: 1 },
  { unique: true, name: "uq_pool_tier_snapshotAt" }
);

// TTL index:自動清舊(如 90 天 = 7776000 秒)
db.jackpot_pool_snapshot.createIndex(
  { snapshot_at: 1 },
  { expireAfterSeconds: 7776000, name: "ttl_snapshot_at" }
);
```

---

## 備註與待確認

- **時間欄位型別**：MCP 實測兩庫慣例對齊 —— MySQL `TIMESTAMP`(`explicit_defaults_for_timestamp=ON`,無隱式 ON UPDATE);OceanBase `TIMESTAMP(3)`;`created_at` 於 OB 帶 `DEFAULT CURRENT_TIMESTAMP(3)`(精度須匹配 (3),否則 1067)、MySQL 不帶;`updated_at` 兩庫皆 `NULL` 可空無 default。
- **`jackpot_round.created_at`（偏離規格）**：規格 round 表僅 `opened_at`/`closed_at`;為對齊現有 OB 表慣例補上 `created_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP`。
- **`accounting_jackpot` 身分欄位**：規格明定 operator/member/game/幣別 **不存本表,join `accounting`**。若報表效能需要反正規化,帶回討論。
- **DB 現有表命名不一致(重要)**：MySQL 目前實際存在的表名為 `jackpot_group` / `jackpot_group_game` / `jackpot_group_operator` / `jackpot_group_setting`,與規格 `jackpot_pool_group` / `jackpot_game_mapping` / `jackpot_operator_setting` / `jackpot_config` **不同**,且欄位有出入;需與 DBA 對齊命名與欄位。`jackpot_admin_audit` 在 DB 尚未建立。
- **`status` / `enabled` / `quota` 等 DEFAULT**：規格未逐欄指定,以上為合理推斷(pool/config status、operator enabled=0、round status=1 open)。若與團隊慣例不符請調整。
- **OceanBase 分區 / 副本 / locality**：規格未定義,依環境補上。
- **不含於本 DDL**：`game_math` / `game_feature_support`(GameServer 側遷移)、共用 `outbox_msg` / `accounting` / `currency`(既有表)皆非本 9 張範圍。
- **覆蓋範圍**：這 9 張(含 Mongo)支援 Ch06 全 14 rpc 的 jackpot 側資料;`GetJackpotPoolDailyTurnover`(讀 DAL 側 turnover)、`GetJackpotReconciliationSums`(需交叉 wallet credit / accounting)另依賴非 jackpot 表。
