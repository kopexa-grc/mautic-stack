<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOpsBundle\Command;

use MauticPlugin\KopexaOpsBundle\Service\CloudStorageSync;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * kopexa:cloud-storage:sync — configures and publishes Mautic's Amazon S3
 * plugin from MAUTIC_S3_* (Helm: mautic.cloudStorage.amazonS3). Run by the
 * init container after the plugin reload. The credentials are read from the
 * environment only, never from the command line, and never printed.
 */
#[AsCommand(name: 'kopexa:cloud-storage:sync', description: 'Configure the Amazon S3 plugin from MAUTIC_S3_* (Helm values mautic.cloudStorage.amazonS3)')]
final class SyncCloudStorageCommand extends Command
{
    private const VARIABLES = [
        'MAUTIC_S3_ACCESS_KEY_ID',
        'MAUTIC_S3_SECRET_ACCESS_KEY',
        'MAUTIC_S3_BUCKET',
        'MAUTIC_S3_REGION',
        'MAUTIC_S3_ENDPOINT',
    ];

    public function __construct(private readonly CloudStorageSync $sync)
    {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this->addOption('dry-run', null, InputOption::VALUE_NONE, 'Validate and report, change nothing');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $env = [];
        foreach (self::VARIABLES as $name) {
            $value = getenv($name);
            if (false !== $value && '' !== trim($value)) {
                $env[$name] = $value;
            }
        }
        if ([] === $env) {
            $output->writeln('cloud storage: nothing declared, nothing to do');

            return Command::SUCCESS;
        }

        try {
            $declared = $this->sync->parse($env);
            $result   = $this->sync->apply($declared, (bool) $input->getOption('dry-run'));
        } catch (\InvalidArgumentException|\RuntimeException $e) {
            $output->writeln('<error>'.$e->getMessage().'</error>');

            return Command::FAILURE;
        }

        $output->writeln(sprintf(
            'cloud storage "Amazon S3": %s%s (bucket %s, region %s%s)',
            $result['status'],
            'updated' === $result['status'] ? ' — '.implode(', ', $result['changed']) : '',
            $declared['bucket'],
            $declared['region'],
            '' !== $declared['endpoint'] ? ', endpoint '.$declared['endpoint'] : ''
        ));

        return Command::SUCCESS;
    }
}
