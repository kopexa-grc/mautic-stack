<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOAuthBundle\Entity;

use League\OAuth2\Server\Entities\UserEntityInterface;

final class User implements UserEntityInterface
{
    public function __construct(private readonly string $identifier)
    {
    }

    public function getIdentifier(): string
    {
        return $this->identifier;
    }
}
