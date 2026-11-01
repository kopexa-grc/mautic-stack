<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOAuthBundle\Entity;

use League\OAuth2\Server\Entities\ClientEntityInterface;
use League\OAuth2\Server\Entities\Traits\ClientTrait;
use League\OAuth2\Server\Entities\Traits\EntityTrait;

final class Client implements ClientEntityInterface
{
    use ClientTrait;
    use EntityTrait;

    /**
     * @param list<string> $redirectUris
     */
    public function __construct(string $identifier, string $name, array $redirectUris)
    {
        $this->setIdentifier($identifier);
        $this->name         = $name;
        $this->redirectUri  = $redirectUris;
        $this->isConfidential = false; // OAuth 2.1 public client: PKCE instead of a secret
    }
}
