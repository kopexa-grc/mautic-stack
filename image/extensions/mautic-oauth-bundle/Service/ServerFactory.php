<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOAuthBundle\Service;

use League\OAuth2\Server\AuthorizationServer;
use League\OAuth2\Server\CryptKey;
use League\OAuth2\Server\Grant\AuthCodeGrant;
use League\OAuth2\Server\Grant\RefreshTokenGrant;
use MauticPlugin\KopexaOAuthBundle\Repository\ClientRepository;
use MauticPlugin\KopexaOAuthBundle\Repository\GrantRepository;
use MauticPlugin\KopexaOAuthBundle\Repository\ScopeRepository;

/**
 * OAuth 2.1 profile: authorization code with PKCE (required for every
 * client, S256 enforced by the controllers) and refresh token rotation.
 * No implicit, password or client credentials grants.
 */
class ServerFactory
{
    private ?AuthorizationServer $server = null;

    public function __construct(
        private readonly Settings $settings,
        private readonly ClientRepository $clients,
        private readonly GrantRepository $grants,
        private readonly ScopeRepository $scopes,
    ) {
    }

    public function server(): AuthorizationServer
    {
        if (null !== $this->server) {
            return $this->server;
        }

        $server = new AuthorizationServer(
            $this->clients,
            $this->grants,
            $this->scopes,
            new CryptKey($this->settings->privateKey(), null, false),
            $this->settings->encryptionKey()
        );
        $server->setDefaultScope('mcp:read');

        $accessTtl  = new \DateInterval('PT'.$this->settings->accessTtl().'S');
        $refreshTtl = new \DateInterval('PT'.$this->settings->refreshTtl().'S');

        $authCode = new AuthCodeGrant($this->grants, $this->grants, new \DateInterval('PT10M'));
        $authCode->setRefreshTokenTTL($refreshTtl);
        $server->enableGrantType($authCode, $accessTtl);

        $refresh = new RefreshTokenGrant($this->grants);
        $refresh->setRefreshTokenTTL($refreshTtl);
        $server->enableGrantType($refresh, $accessTtl);

        return $this->server = $server;
    }
}
