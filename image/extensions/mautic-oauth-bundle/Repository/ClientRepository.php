<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOAuthBundle\Repository;

use League\OAuth2\Server\Entities\ClientEntityInterface;
use League\OAuth2\Server\Repositories\ClientRepositoryInterface;
use MauticPlugin\KopexaOAuthBundle\Entity\Client;

class ClientRepository implements ClientRepositoryInterface
{
    public function __construct(private readonly Storage $storage)
    {
    }

    public function getClientEntity(string $clientIdentifier): ?ClientEntityInterface
    {
        $row = $this->storage->connection()->fetchAssociative(
            sprintf('SELECT client_id, client_name, redirect_uris FROM %s WHERE client_id = ?', $this->storage->clientsTable()),
            [$clientIdentifier]
        );
        if (false === $row) {
            return null;
        }

        return new Client($row['client_id'], $row['client_name'], json_decode($row['redirect_uris'], true) ?: []);
    }

    public function validateClient(string $clientIdentifier, ?string $clientSecret, ?string $grantType): bool
    {
        // Public clients only (OAuth 2.1 + PKCE): a client is valid if it is
        // registered and uses a grant we support.
        return null !== $this->getClientEntity($clientIdentifier)
            && in_array($grantType, ['authorization_code', 'refresh_token'], true);
    }

    /**
     * @param list<string> $redirectUris
     */
    public function register(string $name, array $redirectUris): Client
    {
        $id  = bin2hex(random_bytes(16));
        $now = (new \DateTimeImmutable())->format('Y-m-d H:i:s');
        $this->storage->connection()->insert($this->storage->clientsTable(), [
            'client_id'     => $id,
            'client_name'   => mb_substr($name, 0, 255),
            'redirect_uris' => json_encode(array_values($redirectUris), JSON_UNESCAPED_SLASHES),
            'created_at'    => $now,
        ]);

        return new Client($id, $name, $redirectUris);
    }

    /**
     * Registration is open (RFC 7591), so clients that never completed a
     * token request are removed after a day.
     */
    public function purgeUnused(): int
    {
        return (int) $this->storage->connection()->executeStatement(
            sprintf('DELETE FROM %s WHERE last_used_at IS NULL AND created_at < ?', $this->storage->clientsTable()),
            [(new \DateTimeImmutable('-1 day'))->format('Y-m-d H:i:s')]
        );
    }

    public function touch(string $clientIdentifier): void
    {
        $this->storage->connection()->update(
            $this->storage->clientsTable(),
            ['last_used_at' => (new \DateTimeImmutable())->format('Y-m-d H:i:s')],
            ['client_id' => $clientIdentifier]
        );
    }
}
