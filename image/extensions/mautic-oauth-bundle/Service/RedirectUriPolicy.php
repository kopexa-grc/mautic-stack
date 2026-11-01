<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOAuthBundle\Service;

/**
 * Which redirect URIs dynamically registered clients may use: https on an
 * allow-listed host (or a subdomain of one), or http on a loopback address
 * (RFC 8252 native apps) if "localhost"/"127.0.0.1" is allow-listed.
 */
class RedirectUriPolicy
{
    private const LOOPBACK = ['localhost', '127.0.0.1', '[::1]', '::1'];

    public function __construct(private readonly Settings $settings)
    {
    }

    public function isAllowed(string $uri): bool
    {
        if (strlen($uri) > 2000 || str_contains($uri, '#')) {
            return false;
        }
        $parts = parse_url($uri);
        if (!is_array($parts) || !isset($parts['scheme'], $parts['host']) || isset($parts['user']) || isset($parts['pass'])) {
            return false;
        }
        $scheme = strtolower($parts['scheme']);
        $host   = strtolower($parts['host']);
        $hosts  = array_map('strtolower', $this->settings->redirectHosts());

        if (in_array($host, self::LOOPBACK, true)) {
            $loopbackAllowed = [] !== array_intersect(['localhost', '127.0.0.1'], $hosts);

            return $loopbackAllowed && in_array($scheme, ['http', 'https'], true);
        }
        if ('https' !== $scheme) {
            return false;
        }
        foreach ($hosts as $allowed) {
            if ($host === $allowed || str_ends_with($host, '.'.$allowed)) {
                return true;
            }
        }

        return false;
    }
}
