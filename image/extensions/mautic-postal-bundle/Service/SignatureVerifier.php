<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaPostalBundle\Service;

use Mautic\CoreBundle\Helper\CoreParametersHelper;
use Psr\Log\LoggerInterface;

/**
 * Verifies the X-Postal-Signature-256 header (base64 RSA-SHA256 over the raw
 * request body) against a configured PEM or the Postal server's JWKS.
 */
class SignatureVerifier
{
    public function __construct(
        private readonly CoreParametersHelper $parameters,
        private readonly LoggerInterface $logger,
    ) {
    }

    public function isConfigured(): bool
    {
        return '' !== trim((string) $this->parameters->get('postal_webhook_public_key'))
            || '' !== trim((string) $this->parameters->get('postal_jwks_url'));
    }

    public function verify(string $body, string $signature, ?string $keyId = null): bool
    {
        $raw = base64_decode($signature, true);
        if (false === $raw || '' === $raw) {
            return false;
        }

        foreach ($this->publicKeys($keyId) as $pem) {
            $key = openssl_pkey_get_public($pem);
            if (false === $key) {
                $this->logger->warning('Postal: unusable public key');
                continue;
            }
            if (1 === openssl_verify($body, $raw, $key, OPENSSL_ALGO_SHA256)) {
                return true;
            }
        }

        return false;
    }

    /**
     * @return list<string> PEM-encoded candidate keys
     */
    private function publicKeys(?string $keyId): array
    {
        $pem = trim((string) $this->parameters->get('postal_webhook_public_key'));
        if ('' !== $pem) {
            return [$pem];
        }

        $keys = $this->jwks();
        if (null !== $keyId && isset($keys[$keyId])) {
            return [$keys[$keyId]];
        }

        return array_values($keys);
    }

    /**
     * @return array<string, string> kid => PEM
     */
    private function jwks(): array
    {
        $url = trim((string) $this->parameters->get('postal_jwks_url'));
        if ('' === $url) {
            return [];
        }

        $cacheKey = 'kopexa_postal_jwks_'.sha1($url);
        if (function_exists('apcu_fetch')) {
            $cached = apcu_fetch($cacheKey, $hit);
            if ($hit && is_array($cached)) {
                return $cached;
            }
        }

        $context = stream_context_create(['http' => ['timeout' => 5, 'ignore_errors' => false]]);
        $json    = @file_get_contents($url, false, $context);
        $data    = is_string($json) ? json_decode($json, true) : null;
        if (!is_array($data) || !isset($data['keys']) || !is_array($data['keys'])) {
            $this->logger->error('Postal: could not load JWKS', ['url' => $url]);

            return [];
        }

        $keys = [];
        foreach ($data['keys'] as $index => $jwk) {
            try {
                $keys[(string) ($jwk['kid'] ?? $index)] = JwkConverter::toPem($jwk);
            } catch (\InvalidArgumentException $e) {
                $this->logger->warning('Postal: skipping JWK', ['reason' => $e->getMessage()]);
            }
        }

        if (function_exists('apcu_store') && [] !== $keys) {
            apcu_store($cacheKey, $keys, (int) $this->parameters->get('postal_jwks_cache_ttl', 3600));
        }

        return $keys;
    }
}
