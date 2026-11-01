<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOAuthBundle\Service;

use Mautic\CoreBundle\Helper\CoreParametersHelper;

/**
 * Configuration of the authorization server, read from Mautic parameters
 * (set through the environment in the kopexa image).
 */
class Settings
{
    public function __construct(private readonly CoreParametersHelper $parameters)
    {
    }

    public function isConfigured(): bool
    {
        return '' !== $this->privateKey() && '' !== $this->encryptionKey() && '' !== $this->issuer();
    }

    public function privateKey(): string
    {
        return trim((string) $this->parameters->get('kopexa_oauth_private_key'));
    }

    public function encryptionKey(): string
    {
        return trim((string) $this->parameters->get('kopexa_oauth_encryption_key'));
    }

    /** Issuer identifier: the Mautic site URL without trailing slash. */
    public function issuer(): string
    {
        return rtrim((string) $this->parameters->get('site_url'), '/');
    }

    /** The protected resource tokens are issued for (RFC 8707). */
    public function resource(): string
    {
        $resource = trim((string) $this->parameters->get('kopexa_oauth_resource'));

        return '' !== $resource ? rtrim($resource, '/') : $this->issuer().'/mcp';
    }

    /** @return array<string, string> scope => description */
    public function scopes(): array
    {
        $scopes = $this->parameters->get('kopexa_oauth_scopes');

        return is_array($scopes) ? $scopes : [];
    }

    /** @return list<string> */
    public function redirectHosts(): array
    {
        $hosts = $this->parameters->get('kopexa_oauth_redirect_hosts');

        return array_values(array_filter(is_array($hosts) ? $hosts : (preg_split('/[\s,]+/', (string) $hosts) ?: [])));
    }

    public function accessTtl(): int
    {
        return max(60, (int) $this->parameters->get('kopexa_oauth_access_ttl', 3600));
    }

    public function refreshTtl(): int
    {
        return max(3600, (int) $this->parameters->get('kopexa_oauth_refresh_ttl', 2592000));
    }

    /** RFC 7638 thumbprint of the public key, used as "kid". */
    public function keyId(): string
    {
        $jwk = $this->publicJwkParameters();

        return self::base64Url(hash('sha256', json_encode(['e' => $jwk['e'], 'kty' => 'RSA', 'n' => $jwk['n']], JSON_UNESCAPED_SLASHES), true));
    }

    /** @return array<string, string> */
    public function publicJwk(): array
    {
        return $this->publicJwkParameters() + ['kid' => $this->keyId(), 'use' => 'sig', 'alg' => 'RS256'];
    }

    /** @return array{kty: string, n: string, e: string} */
    private function publicJwkParameters(): array
    {
        $key = openssl_pkey_get_private($this->privateKey());
        if (false === $key) {
            throw new \RuntimeException('kopexa_oauth_private_key is not a valid RSA private key');
        }
        $details = openssl_pkey_get_details($key);
        if (!is_array($details) || OPENSSL_KEYTYPE_RSA !== ($details['type'] ?? null)) {
            throw new \RuntimeException('kopexa_oauth_private_key must be an RSA key');
        }

        return ['kty' => 'RSA', 'n' => self::base64Url($details['rsa']['n']), 'e' => self::base64Url($details['rsa']['e'])];
    }

    public static function base64Url(string $bytes): string
    {
        return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
    }
}
