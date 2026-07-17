# Super Gems Jackpot — DDL Scripts (v4.0)

依 [規格 Ch05 — Data Model](./index.html#p5) 產出的 10 張 jackpot 系列建表語法,供手動建立。可執行腳本另見 [sql/jackpot_mysql.sql](./sql/jackpot_mysql.sql) 與 [sql/jackpot_oceanbase.sql](./sql/jackpot_oceanbase.sql)。

- **MySQL 6 張**：config 真值、低頻寫（`jackpot_pool_group`、`jackpot_game_mapping`、`jackpot_operator_setting`、`jackpot_config`、`jackpot_fx_rate`、`jackpot_admin_audit`）
- **OceanBase 4 張**：權威帳本、高頻寫（`jackpot_round`、`jackpot_win`、`jackpot_daily_increment`、`jackpot_pool_snapshot`）

## 通則（全表適用）

- 字元集：`utf8mb4` / `utf8mb4_unicode_ci`
- **時間欄位**（已比對現有 `campaign` / `five_game_trans` 表慣例,MCP 實測）：
  - **MySQL**：一律 `TIMESTAMP`。DB 已設 `explicit_defaults_for_timestamp = ON`(MySQL 8.0.44),故 `TIMESTAMP NOT NULL` **不會**被隱式套用 `DEFAULT` / `ON UPDATE`。`created_at` = `TIMESTAMP NOT NULL`(無 default);`updated_at` = `TIMESTAMP NULL`(可空、無 default)。
  - **OceanBase**：一律 `TIMESTAMP(3)`。`created_at` = `TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP`;`updated_at` = `TIMESTAMP(3) NULL`(可空、無 default)。
  - 其餘事件時間(`opened_at`/`closed_at`/`credited_at`/`snapshot_at`…)依語意標 NULL / NOT NULL;值一律 **UTC**,由應用層負責寫入(不用 DB 時區函式)。
  - `rate_date` 為 `DATE`(非時間戳),不套用上述規則。
- 金額精度：ppm（累積速率/RTP）、ppb（FX）、micro-cents（池值,= USD cent × 10⁻⁶）、cents（一般金額）；全整數,除法只在派彩取金額時出現一次、放最後、向下取整
- ObjectId 主鍵存 `VARCHAR(24)`（對齊 campaign 慣例）
- 本 DDL 僅涵蓋 10 張 jackpot 表；**不含**須「修改的既有表」`game_math` / `game_feature_support`（GameServer 側 schema 遷移），亦不含共用 `outbox_msg`

> ⚠ OceanBase 相容 MySQL 語法,4 張 OceanBase 表沿用 MySQL DDL 風格;分區 / replica / locality 規格未定義,依環境 DBA 慣例另補。

---

## MySQL（6 張）

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
  COMMENT='彩金群組主檔(規格 Option B:每 game group 一個隔離池)';
```

### 2. jackpot_game_mapping — game → pool 對應

```sql
CREATE TABLE `jackpot_game_mapping` (
  `game_id`       VARCHAR(64) NOT NULL COMMENT '一個 game 只屬一個 pool(會議防呆,PK 強制)',
  `pool_group_id` VARCHAR(24) NOT NULL COMMENT '所屬池',
  `created_at`    TIMESTAMP   NOT NULL COMMENT 'UTC',
  PRIMARY KEY (`game_id`),
  KEY `ix_pool_group_id` (`pool_group_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='寫入語意=full-set replace(UpsertJackpotGameMapping);跨池衝突整批拒絕';
```

### 3. jackpot_operator_setting — per-operator 開關 + RTP

```sql
CREATE TABLE `jackpot_operator_setting` (
  `pool_group_id`        VARCHAR(24)  NOT NULL COMMENT '複合主鍵 1',
  `operator_id`          VARCHAR(64)  NOT NULL COMMENT '複合主鍵 2',
  `enabled`              TINYINT(1)   NOT NULL DEFAULT 0 COMMENT 'per-operator 開關;operator×game 交集才生效',
  `rtp_ppm_by_tier_json` VARCHAR(128) NOT NULL DEFAULT '{}' COMMENT 'RTP by operator×獎項(260715-1),如 {"1":9600,"2":9700};餵 GE 算 Prob=RTP/Price',
  `updated_by`           VARCHAR(64)  NOT NULL COMMENT '後台操作者',
  `created_at`           TIMESTAMP    NOT NULL COMMENT 'UTC',
  `updated_at`           TIMESTAMP    NULL     COMMENT 'UTC',
  PRIMARY KEY (`pool_group_id`, `operator_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='RTP by operator、不 by game;pool 值仍是 global house 池';
```

### 4. jackpot_config — 累積速率 / seed / cap / quota（版本化）

```sql
CREATE TABLE `jackpot_config` (
  `id`                    BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT '自增主鍵',
  `pool_group_id`         VARCHAR(24)      NOT NULL COMMENT '所屬池',
  `tier`                  TINYINT UNSIGNED NOT NULL COMMENT '1=grand、2=major、3=minor、4=mini(四層皆 option);Super Gems 首發只開 1/2',
  `version`               INT UNSIGNED     NOT NULL COMMENT '每次修改遞增;變更軌跡由 jackpot_admin_audit 涵蓋',
  `contribution_rate_ppm` INT UNSIGNED     NOT NULL COMMENT '累積速率 ppm(入池方向,原 rtp_ppm);與中獎 RTP 是兩個獨立旋鈕,不校核',
  `min_per_day_cents`     BIGINT UNSIGNED  NOT NULL DEFAULT 0 COMMENT '最低每日累積 floor(USD cents):昨日 turnover 低於此則以此計',
  `reset_min_cents`       BIGINT UNSIGNED  NOT NULL COMMENT '中獎/撞頂後 seed(USD cents):Grand $20k / Major $2k',
  `reset_threshold_cents` BIGINT UNSIGNED  NOT NULL COMMENT '池增長硬上限 cap(USD cents):撞頂 reset + 溢位補 seed + 假中獎廣播',
  `roll_range_json`       VARCHAR(64)      NULL     COMMENT 'PoolTicker 盤中滾動 range(min/max step),供顯示用',
  `win_count_quota`       INT UNSIGNED     NOT NULL COMMENT '中獎名額:Grand 1 / Major 100。軟限流:quota<1 機率趨零但可為負,非硬上限',
  `updated_by`            VARCHAR(64)      NOT NULL COMMENT '後台操作者',
  `created_at`            TIMESTAMP        NOT NULL COMMENT 'UTC',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pool_tier_version` (`pool_group_id`, `tier`, `version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='config 版本化;每 tier 最新版=max(version)。RTP 不在此,見 jackpot_operator_setting';
```

### 5. jackpot_fx_rate — 雙向匯率（版本化）

```sql
CREATE TABLE `jackpot_fx_rate` (
  `currency_sn`           INT             NOT NULL COMMENT '幣別代碼(複合主鍵 1)',
  `version`               INT UNSIGNED    NOT NULL COMMENT '版本(複合主鍵 2);latest=max(version),寫入即生效',
  `rate_local_to_usd_ppb` BIGINT UNSIGNED NOT NULL COMMENT '貢獻方向匯率,ppb 精度(IDR 等高面額幣別必需)',
  `rate_usd_to_local_ppb` BIGINT UNSIGNED NOT NULL COMMENT '派彩方向匯率;雙向分開存,不得倒數推算(有損)',
  `created_by`            VARCHAR(64)     NOT NULL COMMENT '維護者',
  `created_at`            TIMESTAMP       NOT NULL COMMENT 'UTC',
  PRIMARY KEY (`currency_sn`, `version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='fixed rate、無排程生效;歷史版本可回查(派彩重試/爭議/稽核)';
```

### 6. jackpot_admin_audit — 後台稽核

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

## OceanBase（4 張）

> Valkey 是投影;真相在此,恢復與稽核都從這裡出發。

### 7. jackpot_round — 回合狀態機（恢復錨點）

```sql
CREATE TABLE `jackpot_round` (
  `id`                                     VARCHAR(24)      NOT NULL COMMENT 'round 識別(ObjectId)',
  `pool_group_id`                          VARCHAR(24)      NOT NULL COMMENT '所屬池',
  `tier`                                   TINYINT UNSIGNED NOT NULL COMMENT '1=grand、2=major、3=minor、4=mini',
  `round_seq`                              INT UNSIGNED     NOT NULL COMMENT '回合序號;UNIQUE 防重開',
  `config_version`                         INT UNSIGNED     NOT NULL COMMENT '開啟當下生效的 config 版本',
  `seed_microcents`                        BIGINT UNSIGNED  NOT NULL COMMENT '本回合 seed(micro-cents)',
  `opened_increment_watermark_microcents`  BIGINT UNSIGNED  NOT NULL COMMENT '開啟當下 cum_increment 錨點 — 池值合成公式用',
  `quota_remaining_at_open`                INT              NOT NULL COMMENT '開啟當下 quota;Valkey 遺失時 quota=此值 − count(wins in round)',
  `status`                                 TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '1=open、2=hit(含撞頂 reset)、3=closed(manual reset)',
  `clamp_overflow_microcents`              BIGINT UNSIGNED  NULL     COMMENT '觸頂溢出累計(對帳公式顯式項,唯一記錄點)',
  `opened_at`                              TIMESTAMP(3)     NOT NULL COMMENT 'UTC',
  `closed_at`                              TIMESTAMP(3)     NULL     COMMENT 'UTC',
  `created_at`                             TIMESTAMP(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'UTC(貼 OB 表慣例補上;規格 Ch05 僅列 opened_at/closed_at)',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pool_tier_seq` (`pool_group_id`, `tier`, `round_seq`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='RotateJackpotRound 關舊開新單交易;UNIQUE(pool,tier,round_seq) 防重開';
```

### 8. jackpot_win — 中獎名單（win_id 冪等）

```sql
CREATE TABLE `jackpot_win` (
  `id`                           VARCHAR(24)      NOT NULL COMMENT 'win_id;GE 上報冪等鍵、亦是派彩全鏈冪等鍵',
  `bet_txn_id`                   VARCHAR(64)      NOT NULL COMMENT '觸發中獎的注單號(GE 上報帶入);供會員下注紀錄查詢',
  `pool_group_id`                VARCHAR(24)      NOT NULL COMMENT '所屬池',
  `tier`                         TINYINT UNSIGNED NOT NULL COMMENT '層',
  `round_id`                     VARCHAR(24)      NOT NULL COMMENT '所屬回合',
  `config_version`               INT UNSIGNED     NOT NULL COMMENT '結算當下生效 config',
  `operator_id`                  VARCHAR(64)      NOT NULL COMMENT '中獎者 operator',
  `member_id`                    VARCHAR(64)      NOT NULL COMMENT '中獎者 member',
  `member_account`               VARCHAR(64)      NOT NULL COMMENT '中獎者帳號(中獎名單欄位)',
  `game_id`                      VARCHAR(64)      NOT NULL COMMENT '觸發遊戲',
  `win_amount_usd_cents`         BIGINT UNSIGNED  NOT NULL COMMENT '中獎金額(USD)=本服務原子結算值(server 為準);須併入 total win',
  `pool_value_at_hit_microcents` BIGINT UNSIGNED  NOT NULL COMMENT '結算當下池值(micro-cents 精度來源;win_amount=此值÷1e6 floor)',
  `currency_sn`                  INT              NOT NULL COMMENT '派彩幣別',
  `fx_rate_version`              INT UNSIGNED     NOT NULL COMMENT '使用的 FX 版本(可回查)',
  `win_amount_local_cents`       BIGINT           NOT NULL COMMENT '當地幣別金額',
  `payout_status`                TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '1=pending、2=credited、3=notified、4=failed',
  `failure_reason`               VARCHAR(255)     NULL     COMMENT '派彩失敗原因(卡單診斷)',
  `retry_count`                  INT UNSIGNED     NOT NULL DEFAULT 0 COMMENT '重試次數',
  `created_at`                   TIMESTAMP(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'UTC',
  `credited_at`                  TIMESTAMP(3)     NULL     COMMENT 'UTC',
  `notified_at`                  TIMESTAMP(3)     NULL     COMMENT 'UTC',
  `updated_at`                   TIMESTAMP(3)     NULL     COMMENT 'UTC',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pool_tier_bettxn` (`pool_group_id`, `tier`, `bet_txn_id`),
  KEY `ix_round_id` (`round_id`),
  KEY `ix_status_updated` (`payout_status`, `updated_at`),
  KEY `ix_operator_member_created` (`operator_id`, `member_id`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='UNIQUE(pool,tier,bet_txn_id) 兼任不變量告警:同筆注單同 tier 不可重複中';
```

### 9. jackpot_daily_increment — 日終落帳（對帳錨點）

```sql
CREATE TABLE `jackpot_daily_increment` (
  `pool_group_id`         VARCHAR(24)      NOT NULL COMMENT '複合主鍵 1',
  `tier`                  TINYINT UNSIGNED NOT NULL COMMENT '複合主鍵 2',
  `rate_date`             DATE             NOT NULL COMMENT '複合主鍵 3;UTC 日界',
  `source_turnover_cents` BIGINT UNSIGNED  NOT NULL COMMENT '前一日 turnover(USD cents);本服務自 per-currency×自有 FX 換算',
  `increment_microcents`  BIGINT UNSIGNED  NOT NULL COMMENT '當日總增量 = turnover × 累積速率(contribution_rate)',
  `config_version`        INT UNSIGNED     NOT NULL COMMENT '計算當下 config 版本',
  `fx_versions_json`      VARCHAR(1024)    NOT NULL COMMENT '各幣別使用的 FX 版本,如 {"156":3,"360":2}',
  `created_at`            TIMESTAMP(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'UTC',
  PRIMARY KEY (`pool_group_id`, `tier`, `rate_date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='DailyReconJob 日終落帳(PK 冪等,可重跑);Valkey input 由 DAL 即時維護,本表不驅動池值';
```

### 10. jackpot_pool_snapshot — 彩金滾動紀錄 / 恢復加速

```sql
CREATE TABLE `jackpot_pool_snapshot` (
  `pool_group_id`   VARCHAR(24)      NOT NULL COMMENT '自然鍵複合主鍵 1',
  `tier`            TINYINT UNSIGNED NOT NULL COMMENT '自然鍵複合主鍵 2',
  `snapshot_at`     TIMESTAMP(3)     NOT NULL COMMENT '自然鍵複合主鍵 3(本身即冪等,免 ObjectId);UTC',
  `round_id`        VARCHAR(24)      NOT NULL COMMENT '所屬回合',
  `value_microcents` BIGINT UNSIGNED NOT NULL COMMENT '合成池值(exhausted 可由 quota_remaining≤0 推導,不另存 status)',
  `quota_remaining` INT              NOT NULL COMMENT '當下剩餘名額',
  PRIMARY KEY (`pool_group_id`, `tier`, `snapshot_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='兼作後台彩金滾動紀錄頁(每分鐘一筆,每 pool×tier 每日~1,440 筆,需訂保留期)+ 恢復加速;存合成真值';
```

---

## 備註與待確認

- **時間欄位型別**：已用 MCP 實測兩庫慣例對齊 —— MySQL 用 `TIMESTAMP`(`explicit_defaults_for_timestamp=ON`,無隱式 ON UPDATE)、OceanBase 用 `TIMESTAMP(3)`;`created_at` 於 OB 帶 `DEFAULT CURRENT_TIMESTAMP`、MySQL 不帶;`updated_at` 兩庫皆 `NULL` 可空無 default。
- **`jackpot_round.created_at`（偏離 Ch05）**：規格 Ch05 round 表僅 `opened_at`/`closed_at`,無 `created_at`;為對齊現有 OB 表慣例補上 `created_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP`。
- **`jackpot_win.updated_at`（偏離 Ch05）**：Ch05 標「一律 UTC」未言可空;為對齊現有 OB 表慣例改為 `NULL` 可空。
- **`jackpot_win.member_account`**：規格 Ch05 win 表列「operator/player/tier/amount + member_account」為中獎名單欄位（[index.html:1051](jackpot/index.html#L1051)）;若貴專案會員帳號欄位命名不同,請 DBA 對齊。
- **`status` / `enabled` / `payout_status` 預設值**：規格未逐欄指定 DEFAULT,以上為合理推斷(pool/config status、operator enabled=0、payout_status=1 pending、round status=1 open、retry_count=0)。若與團隊慣例不符請調整。
- **OceanBase 分區 / 副本 / locality**：規格未定義,4 張 OB 表沿用 MySQL DDL,實際建置時依環境補上。
- **不含於本 DDL**：須「修改的既有表」`game_math`（加 `MathFeatureFlags` 欄）與 `game_feature_support`（遷移後移除舊資料）屬 GameServer 側 schema 遷移;共用 `outbox_msg` 為 msg-center 表。三者皆非本 10 張表範圍。
- 覆蓋範圍：這 10 張表可支援 Ch06 的 17/19 個 rpc;`GetJackpotPoolDailyTurnover`(讀 DAL 側 turnover)與 `GetJackpotReconciliationSums`(需交叉 wallet credit)另依賴非 jackpot 表,詳見 [Q&A](./qa.html) 與規格。
