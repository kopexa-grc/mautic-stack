<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOAuthBundle\Repository;

use League\OAuth2\Server\Entities\AccessTokenEntityInterface;
use League\OAuth2\Server\Entities\AuthCodeEntityInterface;
use League\OAuth2\Server\Entities\ClientEntityInterface;
use League\OAuth2\Server\Entities\RefreshTokenEntityInterface;
use League\OAuth2\Server\Repositories\AccessTokenRepositoryInterface;
use League\OAuth2\Server\Repositories\AuthCodeRepositoryInterface;
use League\OAuth2\Server\Repositories\RefreshTokenRepositoryInterface;
use MauticPlugin\KopexaOAuthBundle\Entity\AccessToken;
use MauticPlugin\KopexaOAuthBundle\Entity\AuthCode;
use MauticPlugin\KopexaOAuthBundle\Entity\RefreshToken;
use MauticPlugin\KopexaOAuthBundle\Service\Settings;

/**
 * Authorization codes and refresh tokens are stored (single use, revocable);
 * access tokens are short-lived stateless JWTs and are not stored.
 */
class GrantRepository implements AccessTokenRepositoryInterface, AuthCodeRepositoryInterface, RefreshTokenRepositoryInterface
{
    public function __construct(
        private readonly Storage $storage,
        private readonly Settings $settings,
    ) {
    }

    // --- access tokens ------------------------------------------------------

    public function getNewToken(ClientEntityInterface $clientEntity, array $scopes, ?string $userIdentifier = null): AccessTokenEntityInterface
    {
        $token = new AccessToken($this->settings->issuer(), $this->settings->resource(), $this->settings->keyId());
        $token->setClient($clientEntity);
        foreach ($scopes as $scope) {
            $token->addScope($scope);
        }
        if (null !== $userIdentifier) {
            $token->setUserIdentifier($userIdentifier);
        }

        return $token;
    }

    public function persistNewAccessToken(AccessTokenEntityInterface $accessTokenEntity): void
    {
    }

    public function revokeAccessToken(string $tokenId): void
    {
    }

    public function isAccessTokenRevoked(string $tokenId): bool
    {
        return false;
    }

    // --- authorization codes ------------------------------------------------

    public function getNewAuthCode(): AuthCodeEntityInterface
    {
        return new AuthCode();
    }

    public function persistNewAuthCode(AuthCodeEntityInterface $authCodeEntity): void
    {
        $this->insert('code', $authCodeEntity->getIdentifier(), $authCodeEntity->getClient()->getIdentifier(), $authCodeEntity->getUserIdentifier(), $authCodeEntity->getExpiryDateTime());
    }

    public function revokeAuthCode(string $codeId): void
    {
        $this->revoke($codeId);
    }

    public function isAuthCodeRevoked(string $codeId): bool
    {
        return $this->isRevoked($codeId);
    }

    // --- refresh tokens -----------------------------------------------------

    public function getNewRefreshToken(): ?RefreshTokenEntityInterface
    {
        return new RefreshToken();
    }

    public function persistNewRefreshToken(RefreshTokenEntityInterface $refreshTokenEntity): void
    {
        $access = $refreshTokenEntity->getAccessToken();
        $this->insert('refresh', $refreshTokenEntity->getIdentifier(), $access->getClient()->getIdentifier(), $access->getUserIdentifier(), $refreshTokenEntity->getExpiryDateTime());
    }

    public function revokeRefreshToken(string $tokenId): void
    {
        $this->revoke($tokenId);
    }

    public function isRefreshTokenRevoked(string $tokenId): bool
    {
        return $this->isRevoked($tokenId);
    }

    /** Revoke all grants of a user/client pair (token revocation, user removal). */
    public function revokeAllForClientAndUser(string $clientId, string $userId): void
    {
        $this->storage->connection()->update($this->storage->grantsTable(), ['revoked' => 1], ['client_id' => $clientId, 'user_id' => $userId]);
    }

    public function purgeExpired(): int
    {
        return (int) $this->storage->connection()->executeStatement(
            sprintf('DELETE FROM %s WHERE expires_at < ?', $this->storage->grantsTable()),
            [(new \DateTimeImmutable('-1 day'))->format('Y-m-d H:i:s')]
        );
    }

    private function insert(string $type, string $id, string $clientId, ?string $userId, \DateTimeImmutable $expires): void
    {
        $this->storage->connection()->insert($this->storage->grantsTable(), [
            'id'         => hash('sha256', $id),
            'type'       => $type,
            'client_id'  => $clientId,
            'user_id'    => $userId,
            'expires_at' => $expires->format('Y-m-d H:i:s'),
            'revoked'    => 0,
            'created_at' => (new \DateTimeImmutable())->format('Y-m-d H:i:s'),
        ]);
    }

    private function revoke(string $id): void
    {
        $this->storage->connection()->update($this->storage->grantsTable(), ['revoked' => 1], ['id' => hash('sha256', $id)]);
    }

    private function isRevoked(string $id): bool
    {
        $revoked = $this->storage->connection()->fetchOne(
            sprintf('SELECT revoked FROM %s WHERE id = ?', $this->storage->grantsTable()),
            [hash('sha256', $id)]
        );

        // Unknown grants count as revoked.
        return false === $revoked || 1 === (int) $revoked;
    }
}
