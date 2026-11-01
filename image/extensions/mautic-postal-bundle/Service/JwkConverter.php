<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaPostalBundle\Service;

/**
 * Converts an RSA JSON Web Key (n, e) into a PEM SubjectPublicKeyInfo, so
 * it can be used with openssl_verify(). No external dependencies.
 */
final class JwkConverter
{
    /**
     * @param array{kty?: string, n?: string, e?: string} $jwk
     */
    public static function toPem(array $jwk): string
    {
        if (($jwk['kty'] ?? '') !== 'RSA' || empty($jwk['n']) || empty($jwk['e'])) {
            throw new \InvalidArgumentException('Only RSA JWKs with n and e are supported.');
        }

        $modulus  = self::base64UrlDecode($jwk['n']);
        $exponent = self::base64UrlDecode($jwk['e']);

        $rsaPublicKey = self::der(0x30, self::der(0x02, self::unsigned($modulus)).self::der(0x02, self::unsigned($exponent)));
        // AlgorithmIdentifier: rsaEncryption (1.2.840.113549.1.1.1), NULL parameters
        $algorithm = hex2bin('300d06092a864886f70d0101010500');
        $spki      = self::der(0x30, $algorithm.self::der(0x03, "\x00".$rsaPublicKey));

        return "-----BEGIN PUBLIC KEY-----\n".chunk_split(base64_encode($spki), 64, "\n")."-----END PUBLIC KEY-----\n";
    }

    private static function base64UrlDecode(string $value): string
    {
        $decoded = base64_decode(strtr($value, '-_', '+/').str_repeat('=', (4 - strlen($value) % 4) % 4), true);
        if (false === $decoded || '' === $decoded) {
            throw new \InvalidArgumentException('Invalid base64url value in JWK.');
        }

        return $decoded;
    }

    /** DER INTEGERs are signed: prefix 0x00 if the high bit is set. */
    private static function unsigned(string $bytes): string
    {
        $bytes = ltrim($bytes, "\x00");

        return (ord($bytes[0]) > 0x7F) ? "\x00".$bytes : $bytes;
    }

    private static function der(int $tag, string $data): string
    {
        $length = strlen($data);
        if ($length < 0x80) {
            $encoded = chr($length);
        } else {
            $bytes   = ltrim(pack('N', $length), "\x00");
            $encoded = chr(0x80 | strlen($bytes)).$bytes;
        }

        return chr($tag).$encoded.$data;
    }
}
