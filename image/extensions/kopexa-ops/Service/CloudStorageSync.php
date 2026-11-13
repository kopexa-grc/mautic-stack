<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOpsBundle\Service;

use Doctrine\ORM\EntityManagerInterface;
use Mautic\PluginBundle\Helper\IntegrationHelper;
use Mautic\PluginBundle\Integration\AbstractIntegration;

/**
 * Brings Mautic's Amazon S3 plugin (Cloud Storage bundle) to the state
 * declared in the Helm values (mautic.cloudStorage.amazonS3, passed as
 * MAUTIC_S3_* environment variables):
 *
 * - access key, secret, bucket, region and endpoint are stored the way the
 *   plugin dialog stores them (encrypted with Mautic's secret_key, through
 *   the integration object), and the plugin is published;
 * - nothing is written when the stored settings already match ("unchanged");
 * - declared settings belong to the values: changes made in the plugin
 *   dialog are overwritten at the next start;
 * - without MAUTIC_S3_* the plugin is never touched.
 *
 * The plugin reads from the bucket (remote assets); it does not upload.
 */
class CloudStorageSync
{
    public const INTEGRATION = 'AmazonS3';

    /** Mautic's key name => name in messages (Helm value / environment). */
    private const FIELDS = [
        'client_id'     => 'access key ID',
        'client_secret' => 'secret access key',
        'bucket'        => 'bucket',
        'region'        => 'region',
        'endpoint'      => 'endpoint',
    ];

    private const DEFAULT_REGION = 'us-east-1';

    public function __construct(
        private readonly IntegrationHelper $integrations,
        private readonly EntityManagerInterface $em,
    ) {
    }

    /**
     * @param array<string, string|false|null> $env MAUTIC_S3_* values
     *
     * @return array{client_id: string, client_secret: string, bucket: string, region: string, endpoint: string}
     *
     * @throws \InvalidArgumentException on missing or invalid settings
     */
    public function parse(array $env): array
    {
        $get = static fn (string $name): string => trim((string) ($env[$name] ?? ''));

        $declared = [
            'client_id'     => $get('MAUTIC_S3_ACCESS_KEY_ID'),
            'client_secret' => $get('MAUTIC_S3_SECRET_ACCESS_KEY'),
            'bucket'        => $get('MAUTIC_S3_BUCKET'),
            'region'        => $get('MAUTIC_S3_REGION') ?: self::DEFAULT_REGION,
            'endpoint'      => rtrim($get('MAUTIC_S3_ENDPOINT'), '/'),
        ];

        $errors = [];
        foreach (['client_id' => 'MAUTIC_S3_ACCESS_KEY_ID', 'client_secret' => 'MAUTIC_S3_SECRET_ACCESS_KEY', 'bucket' => 'MAUTIC_S3_BUCKET'] as $key => $var) {
            if ('' === $declared[$key]) {
                $errors[] = "$var is required";
            }
        }
        if ('' !== $declared['bucket'] && 1 !== preg_match('/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/', $declared['bucket'])) {
            $errors[] = 'MAUTIC_S3_BUCKET is not a bucket name (3 to 63 characters: a-z, 0-9, ".", "-")';
        }
        if ('' !== $declared['endpoint'] && 1 !== preg_match('#^https?://[^\s/]+(/\S*)?$#', $declared['endpoint'])) {
            $errors[] = 'MAUTIC_S3_ENDPOINT must be a URL, e.g. https://s3.de.io.cloud.ovh.net';
        }
        if ([] !== $errors) {
            throw new \InvalidArgumentException("invalid Amazon S3 settings:\n  - ".implode("\n  - ", $errors));
        }

        return $declared;
    }

    /**
     * @param array{client_id: string, client_secret: string, bucket: string, region: string, endpoint: string} $declared
     *
     * @return array{status: 'configured'|'updated'|'unchanged', changed: list<string>}
     *
     * @throws \RuntimeException if the Cloud Storage plugin is not installed
     */
    public function apply(array $declared, bool $dryRun = false): array
    {
        $integration = $this->integrations->getIntegrationObject(self::INTEGRATION);
        if (!$integration instanceof AbstractIntegration) {
            throw new \RuntimeException('the Amazon S3 plugin (Cloud Storage bundle) is not installed; run mautic:plugins:reload');
        }
        $settings = $integration->getIntegrationSettings();
        $stored   = (array) $integration->getDecryptedApiKeys($settings);
        $isNew    = [] === array_filter($stored, static fn ($value): bool => '' !== (string) $value);

        $current = [];
        foreach (array_keys(self::FIELDS) as $key) {
            $current[$key] = trim((string) ($stored[$key] ?? ''));
        }
        $current['region']   = $current['region'] ?: self::DEFAULT_REGION;
        $current['endpoint'] = rtrim($current['endpoint'], '/');

        $changed = [];
        foreach (self::FIELDS as $key => $label) {
            if ($current[$key] !== $declared[$key]) {
                $changed[] = $label;
            }
        }
        if (!$settings->isPublished()) {
            $changed[] = 'published';
        }
        if ([] === $changed) {
            return ['status' => 'unchanged', 'changed' => []];
        }
        $status = $isNew ? 'configured' : 'updated';
        if ($dryRun) {
            return ['status' => $status, 'changed' => $changed];
        }

        // Same path as the plugin dialog: Mautic encrypts each key with secret_key.
        $integration->encryptAndSetApiKeys(array_filter($declared, static fn (string $value): bool => '' !== $value), $settings);
        $settings->setIsPublished(true);
        $this->em->persist($settings);
        $this->em->flush();

        return ['status' => $status, 'changed' => $changed];
    }
}
