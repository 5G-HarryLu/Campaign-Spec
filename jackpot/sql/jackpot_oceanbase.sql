-- =====================================================================
-- Super Gems Jackpot — OceanBase DDL (v4.0)
-- 依規格 Ch05 — Data Model。權威帳本、高頻寫。
-- Valkey 是投影;真相在此,恢復與稽核都從這裡出發。
-- 通則:utf8mb4 / utf8mb4_unicode_ci。
-- 時間欄位:一律 TIMESTAMP(3),值為 UTC(應用層負責寫入)。慣例對齊現有 five_game_trans 表:
--   created_at = TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP;
--   updated_at = TIMESTAMP(3) NULL(可空、無 default);其餘事件時間依語意 NULL/NOT NULL。
-- 金額:micro-cents(池值,= USD cent × 10^-6)、cents(一般金額),全整數。
-- 執行順序:round → win(round_id 參照) → daily_increment / pool_snapshot
--
-- 註:OceanBase 相容 MySQL 語法。分區 / 副本 / locality 規格未定義,依環境 DBA 慣例另補。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 7. jackpot_round — 回合狀態機(恢復錨點)
-- ---------------------------------------------------------------------
CREATE TABLE `jackpot_round` (
  `id`                                    VARCHAR(24)      NOT NULL COMMENT 'round 識別(ObjectId)',
  `pool_group_id`                         VARCHAR(24)      NOT NULL COMMENT '所屬池',
  `tier`                                  TINYINT UNSIGNED NOT NULL COMMENT '1=grand、2=major、3=minor、4=mini',
  `round_seq`                             INT UNSIGNED     NOT NULL COMMENT '回合序號;UNIQUE 防重開',
  `config_version`                        INT UNSIGNED     NOT NULL COMMENT '開啟當下生效的 config 版本',
  `seed_microcents`                       BIGINT UNSIGNED  NOT NULL COMMENT '本回合 seed(micro-cents)',
  `opened_increment_watermark_microcents` BIGINT UNSIGNED  NOT NULL COMMENT '開啟當下 cum_increment 錨點 — 池值合成公式用',
  `quota_remaining_at_open`               INT              NOT NULL COMMENT '開啟當下 quota;Valkey 遺失時 quota=此值 − count(wins in round)',
  `status`                                TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '1=open、2=hit(含撞頂 reset)、3=closed(manual reset)',
  `clamp_overflow_microcents`             BIGINT UNSIGNED  NULL     COMMENT '觸頂溢出累計(對帳公式顯式項,唯一記錄點)',
  `opened_at`                             TIMESTAMP(3)     NOT NULL COMMENT 'UTC',
  `closed_at`                             TIMESTAMP(3)     NULL     COMMENT 'UTC',
  `created_at`                            TIMESTAMP(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'UTC',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pool_tier_seq` (`pool_group_id`, `tier`, `round_seq`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='RotateJackpotRound 關舊開新單交易;UNIQUE(pool,tier,round_seq) 防重開';

-- ---------------------------------------------------------------------
-- 8. jackpot_win — 中獎名單(win_id 冪等)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 9. jackpot_daily_increment — 日終落帳(對帳錨點)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 10. jackpot_pool_snapshot — 彩金滾動紀錄 / 恢復加速
-- ---------------------------------------------------------------------
CREATE TABLE `jackpot_pool_snapshot` (
  `pool_group_id`    VARCHAR(24)      NOT NULL COMMENT '自然鍵複合主鍵 1',
  `tier`             TINYINT UNSIGNED NOT NULL COMMENT '自然鍵複合主鍵 2',
  `snapshot_at`      TIMESTAMP(3)     NOT NULL COMMENT '自然鍵複合主鍵 3(本身即冪等,免 ObjectId);UTC',
  `round_id`         VARCHAR(24)      NOT NULL COMMENT '所屬回合',
  `value_microcents` BIGINT UNSIGNED  NOT NULL COMMENT '合成池值(exhausted 可由 quota_remaining≤0 推導,不另存 status)',
  `quota_remaining`  INT              NOT NULL COMMENT '當下剩餘名額',
  PRIMARY KEY (`pool_group_id`, `tier`, `snapshot_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='兼作後台彩金滾動紀錄頁(每分鐘一筆,每 pool×tier 每日~1,440 筆,需訂保留期)+ 恢復加速;存合成真值';
