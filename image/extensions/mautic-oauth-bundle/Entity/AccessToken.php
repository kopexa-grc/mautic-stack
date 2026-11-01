<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOAuthBundle\Entity;

use DateTimeImmutable;
use Lcobucci\JWT\Configuration;
use Lcobucci\JWT\Signer\Key\InMemory;
use Lcobucci\JWT\Signer\Rsa\Sha256;
use League\OAuth2\Server\CryptKeyInterface;
use League\OAuth2\Server\Entities\AccessTokenEntityInterface;
use League\OAuth2\Server\Entities\ScopeEntityInterface;
use League\OAuth2\Server\Entities\Traits\EntityTrait;
use League\OAuth2\Server\Entities\Traits\TokenEntityTrait;

/**
 * JWT access token per RFC 9068 (OAuth 2.0 access token JWT profile):
 * typ "at+jwt", iss = this Mautic, aud = the protected resource (MCP
 * endpoint), sub = Mautic user id, scope as a space-separated string,
 * client_id, jti, iat/nbf/exp. Signed RS256, verifiable via /oauth2/jwks.json.
 */
final class AccessToken implements AccessTokenEntityInterface
{
    use EntityTrait;
    use TokenEntityTrait;

    private CryptKeyInterface $privateKey;

    public function __construct(
        private readonly string $issuer,
        private readonly string $audience,
        private readonly string $keyId,
    ) {
    }

    public function setPrivateKey(CryptKeyInterface $privateKey): void
    {
        $this->privateKey = $privateKey;
    }

    public function toString(): string
    {
        $config = Configuration::forAsymmetricSigner(
            new Sha256(),
            InMemory::plainText($this->privateKey->getKeyContents(), $this->privateKey->getPassPhrase() ?? ''),
            InMemory::plainText('unused-verification-key'),
        );
        $now    = new DateTimeImmutable();
        $scopes = implode(' ', array_map(static fn (ScopeEntityInterface $s): string => $s->getIdentifier(), $this->getScopes()));

        return $config->builder()
            ->withHeader('typ', 'at+jwt')
            ->withHeader('kid', $this->keyId)
            ->issuedBy($this->issuer)
            ->permittedFor($this->audience)
            ->identifiedBy($this->getIdentifier())
            ->relatedTo((string) ($this->getUserIdentifier() ?? $this->getClient()->getIdentifier()))
            ->issuedAt($now)
            ->canOnlyBeUsedAfter($now)
            ->expiresAt($this->getExpiryDateTime())
            ->withClaim('client_id', $this->getClient()->getIdentifier())
            ->withClaim('scope', $scopes)
            ->getToken($config->signer(), $config->signingKey())
            ->toString();
    }
}
