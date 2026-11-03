<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOpsBundle\Command;

use MauticPlugin\KopexaOpsBundle\Service\RoleSync;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * kopexa:roles:sync — creates or updates the roles declared in MAUTIC_ROLES
 * (Helm: mautic.roles). Run by the init container after the migrations.
 */
#[AsCommand(name: 'kopexa:roles:sync', description: 'Create or update Mautic roles from MAUTIC_ROLES (Helm values mautic.roles)')]
final class SyncRolesCommand extends Command
{
    public function __construct(private readonly RoleSync $sync)
    {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this
            ->addOption('json', null, InputOption::VALUE_REQUIRED, 'Roles as JSON instead of the MAUTIC_ROLES environment variable')
            ->addOption('dry-run', null, InputOption::VALUE_NONE, 'Validate and report, change nothing');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $json = $input->getOption('json');
        if (!is_string($json)) {
            $env  = getenv('MAUTIC_ROLES');
            $json = false === $env ? '' : $env;
        }
        if ('' === trim($json) || '[]' === trim($json)) {
            $output->writeln('roles: none declared, nothing to do');

            return Command::SUCCESS;
        }

        try {
            $roles = $this->sync->parse($json);
        } catch (\InvalidArgumentException $e) {
            $output->writeln('<error>'.$e->getMessage().'</error>');

            return Command::FAILURE;
        }

        $dryRun = (bool) $input->getOption('dry-run');
        foreach ($roles as $role) {
            $result = $this->sync->apply($role, $dryRun);
            $output->writeln(sprintf(
                'role "%s": %s%s%s',
                $role['name'],
                $result['status'],
                $result['id'] > 0 ? ' (id '.$result['id'].')' : '',
                'updated' === $result['status'] ? ' — '.implode(', ', $result['changed']) : ''
            ));
        }

        return Command::SUCCESS;
    }
}
