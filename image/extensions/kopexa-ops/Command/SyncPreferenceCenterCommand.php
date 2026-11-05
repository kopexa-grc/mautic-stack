<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOpsBundle\Command;

use MauticPlugin\KopexaOpsBundle\Service\PreferenceCenterSync;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * kopexa:preferences:sync — topics, preference page and settings of the
 * email preference center from MAUTIC_PREFERENCE_CENTER (Helm:
 * mautic.preferenceCenter). Run by the init container after the roles.
 */
#[AsCommand(name: 'kopexa:preferences:sync', description: 'Set up the email preference center from MAUTIC_PREFERENCE_CENTER (Helm values mautic.preferenceCenter)')]
final class SyncPreferenceCenterCommand extends Command
{
    public function __construct(private readonly PreferenceCenterSync $sync)
    {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this
            ->addOption('json', null, InputOption::VALUE_REQUIRED, 'Declaration as JSON instead of the MAUTIC_PREFERENCE_CENTER environment variable')
            ->addOption('dry-run', null, InputOption::VALUE_NONE, 'Validate and report, change nothing');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $json = $input->getOption('json');
        if (!is_string($json)) {
            $env  = getenv('MAUTIC_PREFERENCE_CENTER');
            $json = false === $env ? '' : $env;
        }
        if ('' === trim($json) || '{}' === trim($json)) {
            $output->writeln('preference center: none declared, nothing to do');

            return Command::SUCCESS;
        }

        try {
            $declared = $this->sync->parse($json);
            foreach ($this->sync->apply($declared, (bool) $input->getOption('dry-run')) as $line) {
                $output->writeln($line);
            }
        } catch (\InvalidArgumentException|\RuntimeException $e) {
            $output->writeln('<error>'.$e->getMessage().'</error>');

            return Command::FAILURE;
        }

        return Command::SUCCESS;
    }
}
