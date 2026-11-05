<?php

declare(strict_types=1);

namespace MauticPlugin\KopexaOpsBundle\Command;

use Doctrine\DBAL\Connection;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * kopexa:privacy:strip-third-party-fonts — removes the font stylesheets
 * Mautic itself wrote into stored content (<link … data-source="mautic">
 * pointing to Google Fonts): its builders copy the editor fonts into the
 * saved HTML, so pages kept loading them after editor_fonts was changed.
 * Only those Mautic-injected tags are removed; nothing a person built is
 * touched. Idempotent; run by the init container.
 */
#[AsCommand(name: 'kopexa:privacy:strip-third-party-fonts', description: 'Remove Google Fonts stylesheets Mautic injected into stored pages and emails')]
final class StripThirdPartyFontsCommand extends Command
{
    /** Mautic's own injected tags only (data-source="mautic"), any attribute order. */
    public const PATTERN = '#<link\b(?=[^>]*\bhref="https?://fonts\.(?:googleapis|gstatic)\.com/[^"]*")(?=[^>]*\bdata-source="mautic")[^>]*>\s*#i';

    private const TABLES = ['pages' => 'custom_html', 'emails' => 'custom_html', 'dynamic_content' => 'content'];

    public function __construct(private readonly Connection $connection)
    {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this->addOption('dry-run', null, InputOption::VALUE_NONE, 'Report, change nothing');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $prefix = defined('MAUTIC_TABLE_PREFIX') ? (string) MAUTIC_TABLE_PREFIX : '';
        $dryRun = (bool) $input->getOption('dry-run');
        $total  = 0;
        foreach (self::TABLES as $table => $column) {
            $rows = $this->connection->fetchAllAssociative(
                "SELECT id, {$column} AS html FROM {$prefix}{$table} WHERE {$column} LIKE '%fonts.googleapis.com%' OR {$column} LIKE '%fonts.gstatic.com%'"
            );
            foreach ($rows as $row) {
                $clean = preg_replace(self::PATTERN, '', (string) $row['html'], -1, $count);
                if (null === $clean || 0 === $count) {
                    continue;
                }
                $total += $count;
                $output->writeln(sprintf('%s %d: %d font stylesheet(s)%s', $table, $row['id'], $count, $dryRun ? ' (dry run)' : ' removed'));
                if (!$dryRun) {
                    $this->connection->update($prefix.$table, [$column => $clean], ['id' => $row['id']]);
                }
            }
        }
        $output->writeln(0 === $total ? 'third-party fonts: none stored' : sprintf('third-party fonts: %d stylesheet(s) %s', $total, $dryRun ? 'found' : 'removed'));

        return Command::SUCCESS;
    }
}
