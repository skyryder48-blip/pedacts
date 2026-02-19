-- free-trapsales database tables
-- Run this before first use.

CREATE TABLE IF NOT EXISTS `pedscenarios_drug_rep` (
    `citizenid` VARCHAR(50) NOT NULL,
    `zone_id` VARCHAR(50) NOT NULL,
    `reputation` FLOAT NOT NULL DEFAULT 0,
    `total_sales` INT NOT NULL DEFAULT 0,
    `total_earned` INT NOT NULL DEFAULT 0,
    `last_sale_at` TIMESTAMP NULL DEFAULT NULL,
    PRIMARY KEY (`citizenid`, `zone_id`),
    INDEX `idx_citizenid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `pedscenarios_zone_heat` (
    `zone_id` VARCHAR(50) NOT NULL,
    `heat` FLOAT NOT NULL DEFAULT 0,
    `lockdown_until` TIMESTAMP NULL DEFAULT NULL,
    PRIMARY KEY (`zone_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
