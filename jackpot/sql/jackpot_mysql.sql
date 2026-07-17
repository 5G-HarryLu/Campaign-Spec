-- =====================================================================
-- Super Gems Jackpot — MySQL DDL (v4.0)
-- 依規格 Ch05 — Data Model。config 真值、低頻寫。
-- 通則:utf8mb4 / utf8mb4_unicode_ci。DB 已設 explicit_defaults_for_timestamp=ON,
--   故 TIMESTAMP NOT NULL 不會被隱式套用 DEFAULT/ON UPDATE。
-- 時間欄位:一律 TIMESTAMP,值為 UTC(應用層負責寫入)。慣例對齊現有 campaign 表:
--   created_at = TIMESTAMP NOT NULL(無 default);updated_at = TIMESTAMP NULL(可空、無 default)。
-- 金額:ppm(累積速率/RTP)、ppb(FX)、micro-cents(池值)、cents(一般金額),全整數。
-- 執行順序:pool_group → game_mapping / operator_setting / config → fx_rate / admin_audit
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. jackpot_pool_group — PoolGroupID 主檔
-- ---------------------------------------------------------------------
CREATE TABLE `jackpot_pool_group` (
  `id`         VARCHAR(24)      NOT NULL COMMENT 'ObjectId,與 campaign 慣例一致',
  `name`       VARCHAR(64)      NOT NULL COMMENT 'pool 顯示名稱',
  `status`     TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '0=disabled、1=active',
  `created_at` TIMESTAMP        NOT NULL COMMENT 'UTC',
  `updated_at` TIMESTAMP        NULL     COMMENT 'UTC',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='彩金群組主檔(規格 Option B:每 game group 一個隔離池)';

-- ---------------------------------------------------------------------
-- 2. jackpot_game_mapping — game → pool 對應
-- ---------------------------------------------------------------------
CREATE TABLE `jackpot_game_mapping` (
  `game_id`       VARCHAR(64) NOT NULL COMMENT '一個 game 只屬一個 pool(會議防呆,PK 強制)',
  `pool_group_id` VARCHAR(24) NOT NULL COMMENT '所屬池',
  `created_at`    TIMESTAMP   NOT NULL COMMENT 'UTC',
  PRIMARY KEY (`game_id`),
  KEY `ix_pool_group_id` (`pool_group_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='寫入語意=full-set replace(UpsertJackpotGameMapping);跨池衝突整批拒絕';

-- ---------------------------------------------------------------------
-- 3. jackpot_operator_setting — per-operator 開關 + RTP
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 4. jackpot_config — 累積速率 / seed / cap / quota(版本化)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 5. jackpot_fx_rate — 雙向匯率(版本化)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 6. jackpot_admin_audit — 後台稽核
-- ---------------------------------------------------------------------
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
