-- =====================================================================
-- Super Gems Jackpot — OceanBase DDL (v4.0 / 每日增量盤中注入)
-- 依規格 Ch05 — Data Model。權威帳本、高頻寫。
-- Valkey 是投影;真相在此,恢復與稽核都從這裡出發。
-- 通則:utf8mb4 / utf8mb4_unicode_ci。
-- 時間欄位:一律 TIMESTAMP(3),值為 UTC(應用層負責寫入)。
--   created_at = TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP;
--   updated_at / 事件時間 = TIMESTAMP(3) NULL(依語意)。
-- 主鍵慣例:ObjectId 命名 id(VARCHAR(24));自增序號命名 sn;唯一性用 UNIQUE。
-- FX:不建 jackpot 匯率表,用既有 currency.fixed_rate。
-- snapshot 移 MongoDB(見 schema.md),不在本檔。
-- 執行順序:round → accounting_jackpot(round_id 參照) → daily_increment
--
-- 註:OceanBase 相容 MySQL 語法。分區 / 副本 / locality 規格未定義,依環境 DBA 另補。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 6. jackpot_round — 回合狀態機(恢復錨點)
-- ---------------------------------------------------------------------
CREATE TABLE `jackpot_round` (
  `id`                                    VARCHAR(24)      NOT NULL COMMENT 'round 識別(ObjectId)',
  `pool_group_id`                         VARCHAR(24)      NOT NULL COMMENT '所屬池',
  `tier`                                  TINYINT UNSIGNED NOT NULL COMMENT '1=grand、2=major、3=minor、4=mini',
  `round_seq`                             INT UNSIGNED     NOT NULL COMMENT '回合序號;UNIQUE 防重開',
  `seed_microcents`                       BIGINT UNSIGNED  NOT NULL COMMENT '本回合 seed(micro-cents)',
  `opened_increment_watermark_microcents` BIGINT UNSIGNED  NOT NULL COMMENT '開啟當下 cum_increment 錨點 — 池值合成公式用',
  `quota_remaining_at_open`               INT              NOT NULL COMMENT '開啟當下 quota;Valkey 遺失時 quota=此值 − count(wins in round)',
  `status`                                TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '1=open、2=hit(含撞頂 reset)、3=closed(manual reset)',
  `clamp_overflow_microcents`             BIGINT UNSIGNED  NULL     COMMENT '觸頂溢出累計(對帳公式顯式項,唯一記錄點)',
  `opened_at`                             TIMESTAMP(3)     NOT NULL COMMENT 'UTC',
  `closed_at`                             TIMESTAMP(3)     NULL     COMMENT 'UTC',
  `created_at`                            TIMESTAMP(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'UTC(貼 OB 表慣例;規格僅列 opened_at/closed_at)',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pool_tier_seq` (`pool_group_id`, `tier`, `round_seq`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='RotateJackpotRound 關舊開新單交易;UNIQUE(pool,tier,round_seq) 防重開;config 無版本';

-- ---------------------------------------------------------------------
-- 7. accounting_jackpot — 中獎名單(原 jackpot_win 改名,注單類慣例)
--    身分欄位(operator/member/game/幣別)不存本表,join accounting 取得。
--    無 payout 狀態機:SettleWin 同步結算、GS 當場賠付;credit⟷本表對帳兜底。
-- ---------------------------------------------------------------------
CREATE TABLE `accounting_jackpot` (
  `id`                           VARCHAR(24)      NOT NULL COMMENT 'win_id(ObjectId);GE 上報冪等鍵、亦是派彩全鏈冪等鍵',
  `accounting_id`                VARCHAR(24)      NOT NULL COMMENT '觸發中獎的注單號(GE 上報帶入,平台語彙);供會員下注紀錄查詢',
  `pool_group_id`                VARCHAR(24)      NOT NULL COMMENT '所屬池',
  `tier`                         TINYINT UNSIGNED NOT NULL COMMENT '層',
  `round_id`                     VARCHAR(24)      NOT NULL COMMENT '所屬回合',
  `win_amount_usd_cents`         BIGINT UNSIGNED  NOT NULL COMMENT '中獎金額(USD)=本服務原子結算值(server 為準);須併入 total win',
  `win_amount_local_cents`       BIGINT UNSIGNED  NOT NULL COMMENT '當地幣別金額(結算當下以 currency.fixed_rate 換算一次,不可重算)',
  `pool_value_at_hit_microcents` BIGINT UNSIGNED  NOT NULL COMMENT '結算當下池值(micro-cents 精度來源;win_amount=此值÷1e6 floor)',
  `created_at`                   TIMESTAMP(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'UTC。無 payout_status',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pool_tier_accounting` (`pool_group_id`, `tier`, `accounting_id`),
  KEY `ix_round_id` (`round_id`),
  KEY `ix_pool_tier_created` (`pool_group_id`, `tier`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='中獎名單;身分欄位 join accounting(比照 accounting_bonus);UNIQUE(pool,tier,accounting_id):同筆注單同 tier 不可重複中';

-- ---------------------------------------------------------------------
-- 8. jackpot_daily_increment — 每日增量(對帳錨點)
-- ---------------------------------------------------------------------
CREATE TABLE `jackpot_daily_increment` (
  `sn`                    BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT '自增序號(慣例)',
  `pool_group_id`         VARCHAR(24)      NOT NULL COMMENT '所屬池',
  `tier`                  TINYINT UNSIGNED NOT NULL COMMENT '層',
  `rate_date`             DATE             NOT NULL COMMENT 'UTC 日界',
  `source_turnover_cents` BIGINT UNSIGNED  NOT NULL COMMENT '前一日 turnover(USD cents);以 currency.fixed_rate 換算(無版本欄位)',
  `increment_microcents`  BIGINT UNSIGNED  NOT NULL COMMENT '當日總增量 = turnover × 累積速率(contribution_rate_ppm)',
  `created_at`            TIMESTAMP(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'UTC',
  PRIMARY KEY (`sn`),
  UNIQUE KEY `uq_pool_tier_date` (`pool_group_id`, `tier`, `rate_date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='DailyIncrementJob 每日落帳(UQ 冪等、可重算錨點);當日總增量交 PoolTicker 盤中分次注入 input;對帳 Σ 錨點';
