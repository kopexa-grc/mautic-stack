<?php
// Dependency-free self-test for the signature path (run: php Tests/selftest.php).
declare(strict_types=1);
require __DIR__.'/../Service/JwkConverter.php';
use MauticPlugin\KopexaPostalBundle\Service\JwkConverter;

$fail = static function (string $m): never { fwrite(STDERR, "FAIL $m\n"); exit(1); };
foreach ([2048, 4096] as $bits) {
    $key  = openssl_pkey_new(['private_key_bits' => $bits, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
    $d    = openssl_pkey_get_details($key);
    $b64u = static fn (string $s): string => rtrim(strtr(base64_encode($s), '+/', '-_'), '=');
    $pem  = JwkConverter::toPem(['kty' => 'RSA', 'n' => $b64u($d['rsa']['n']), 'e' => $b64u($d['rsa']['e'])]);
    if (trim($pem) !== trim($d['key'])) { $fail("$bits: PEM differs from OpenSSL's"); }
    $body = json_encode(['event' => 'MessageBounced', 'payload' => ['original_message' => ['to' => 'a@b.c']]]);
    openssl_sign($body, $sig, $key, OPENSSL_ALGO_SHA256);
    if (1 !== openssl_verify($body, $sig, openssl_pkey_get_public($pem), OPENSSL_ALGO_SHA256)) { $fail("$bits: verify"); }
    if (1 === openssl_verify($body.'x', $sig, openssl_pkey_get_public($pem), OPENSSL_ALGO_SHA256)) { $fail("$bits: tampered body verified"); }
    echo "ok   RSA-$bits: JWK→PEM identical to OpenSSL, signature verifies, tampering detected\n";
}
try { JwkConverter::toPem(['kty' => 'EC']); $fail('EC accepted'); } catch (InvalidArgumentException) { echo "ok   non-RSA keys rejected\n"; }
