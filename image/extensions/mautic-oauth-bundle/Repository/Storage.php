<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOAuthBundle\Repository;

use Doctrine\DBAL\Connection;

/**
 * Persistence for registered clients and issued grants (authorization codes,
 * refresh tokens). Access tokens are stateless JWTs and are not stored.
 * Tables are created on first use, so the bundle needs no install step.
 */
class Storage
{
    private bool $schemaChecked = false;

    public function __construct(private readonly Connection $connection)
    {
    }

    public function clientsTable(): string
    {
        return $this->prefix().'kopexa_oauth_clients';
    }

    public function grantsTable(): string
    {
        return $this->prefix().'kopexa_oauth_grants';
    }

    public function connection(): Connection
    {
        $this->ensureSchema();

        return $this->connection;
    }

    private function prefix(): string
    {
        return defined('MAUTIC_TABLE_PREFIX') ? (string) MAUTIC_TABLE_PREFIX : '';
    }

    private function ensureSchema(): void
    {
        if ($this->schemaChecked) {
            return;
        }
        $this->connection->executeStatement(sprintf(
            'CREATE TABLE IF NOT EXISTS %s (
                client_id VARCHAR(64) NOT NULL PRIMARY KEY,
                client_name VARCHAR(255) NOT NULL,
                redirect_uris TEXT NOT NULL,
                created_at DATETIME NOT NULL,
                last_used_at DATETIME NULL
            ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci',
            $this->clientsTable()
        ));
        $this->connection->executeStatement(sprintf(
            'CREATE TABLE IF NOT EXISTS %s (
                id VARCHAR(128) NOT NULL PRIMARY KEY,
                type VARCHAR(16) NOT NULL,
                client_id VARCHAR(64) NOT NULL,
                user_id VARCHAR(64) NULL,
                expires_at DATETIME NOT NULL,
                revoked TINYINT(1) NOT NULL DEFAULT 0,
                created_at DATETIME NOT NULL,
                INDEX idx_expires (expires_at)
            ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci',
            $this->grantsTable()
        ));
        $this->schemaChecked = true;
    }
}
