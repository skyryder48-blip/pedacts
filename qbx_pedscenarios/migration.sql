-- ============================================================================
-- qbx_pedscenarios — Database Migration
-- Run this once against your QBX database before starting the resource.
-- ============================================================================

-- Per-player, per-zone drug dealing reputation
CREATE TABLE IF NOT EXISTS `pedscenarios_drug_rep` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `citizenid` VARCHAR(50) NOT NULL,
    `zone_id` VARCHAR(50) NOT NULL,
    `reputation` FLOAT NOT NULL DEFAULT 0,
    `total_sales` INT UNSIGNED NOT NULL DEFAULT 0,
    `total_earned` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `last_sale_at` TIMESTAMP NULL DEFAULT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uk_citizen_zone` (`citizenid`, `zone_id`),
    KEY `idx_citizenid` (`citizenid`),
    KEY `idx_zone_id` (`zone_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Persistent zone heat (survives restarts)
CREATE TABLE IF NOT EXISTS `pedscenarios_zone_heat` (
    `zone_id` VARCHAR(50) NOT NULL,
    `heat` FLOAT NOT NULL DEFAULT 0,
    `lockdown_until` TIMESTAMP NULL DEFAULT NULL,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`zone_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
