<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOAuthBundle\Repository;

use League\OAuth2\Server\Entities\ClientEntityInterface;
use League\OAuth2\Server\Entities\ScopeEntityInterface;
use League\OAuth2\Server\Repositories\ScopeRepositoryInterface;
use MauticPlugin\KopexaOAuthBundle\Entity\Scope;
use MauticPlugin\KopexaOAuthBundle\Service\Settings;

class ScopeRepository implements ScopeRepositoryInterface
{
    public function __construct(private readonly Settings $settings)
    {
    }

    public function getScopeEntityByIdentifier(string $identifier): ?ScopeEntityInterface
    {
        return array_key_exists($identifier, $this->settings->scopes()) ? new Scope($identifier) : null;
    }

    public function finalizeScopes(array $scopes, string $grantType, ClientEntityInterface $clientEntity, ?string $userIdentifier = null, ?string $authCodeId = null): array
    {
        // No scope requested: grant read access only.
        if ([] === $scopes && 'authorization_code' === $grantType) {
            return [new Scope('mcp:read')];
        }

        return array_values(array_filter($scopes, fn (ScopeEntityInterface $s): bool => array_key_exists($s->getIdentifier(), $this->settings->scopes())));
    }
}
