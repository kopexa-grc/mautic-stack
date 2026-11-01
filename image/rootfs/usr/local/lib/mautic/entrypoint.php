<?php

/*
 * Mautic container entrypoint (kopexa-grc/mautic-stack).
 *
 * Written in PHP because the hardened runtime image has no shell.
 *
 *   web                 run Apache httpd (default)
 *   init                wait for the database, install Mautic on first start
 *                       (if MAUTIC_ADMIN_PASSWORD is set), run migrations
 *   worker [transport…] consume Messenger queues (default: email hit)
 *   console <args…>     run bin/console (skipped with exit 0 until installed)
 *   version             print the Mautic version
 *
 * Configuration comes from the environment and is handed to Mautic through
 * MAUTIC_CONFIG_PARAMETERS, which Mautic merges over config/local.php:
 *
 *   MAUTIC_DB_HOST, MAUTIC_DB_PORT, MAUTIC_DB_NAME, MAUTIC_DB_USER,
 *   MAUTIC_DB_PASSWORD, MAUTIC_DB_TABLE_PREFIX, MAUTIC_SITE_URL,
 *   MAUTIC_SECRET_KEY, MAUTIC_TRUSTED_PROXIES, MAUTIC_TRUSTED_HOSTS,
 *   MAUTIC_MAILER_DSN, MAUTIC_MAILER_FROM_EMAIL, MAUTIC_MAILER_FROM_NAME,
 *   MAUTIC_MESSENGER_DSN_EMAIL, MAUTIC_MESSENGER_DSN_HIT,
 *   MAUTIC_MESSENGER_DSN_FAILED
 *
 * Every variable also accepts a <NAME>_FILE variant pointing to a file
 * (e.g. a mounted Kubernetes secret). A user-supplied MAUTIC_CONFIG_PARAMETERS
 * (JSON object) is merged last and wins.
 */

declare(strict_types=1);

const APP_ROOT = '/app';
const CONSOLE  = APP_ROOT.'/bin/console';
const HTTPD    = '/usr/bin/httpd';
const PHP      = '/usr/bin/php';

/** env var => [mautic parameter, type] */
const PARAMETER_MAP = [
    'MAUTIC_DB_HOST'              => ['db_host', 'string'],
    'MAUTIC_DB_PORT'              => ['db_port', 'string'],
    'MAUTIC_DB_NAME'              => ['db_name', 'string'],
    'MAUTIC_DB_USER'              => ['db_user', 'string'],
    'MAUTIC_DB_PASSWORD'          => ['db_password', 'string'],
    'MAUTIC_DB_TABLE_PREFIX'      => ['db_table_prefix', 'string'],
    'MAUTIC_SITE_URL'             => ['site_url', 'string'],
    'MAUTIC_SECRET_KEY'           => ['secret_key', 'string'],
    'MAUTIC_TRUSTED_PROXIES'      => ['trusted_proxies', 'list'],
    'MAUTIC_TRUSTED_HOSTS'        => ['trusted_hosts', 'list'],
    'MAUTIC_MAILER_DSN'           => ['mailer_dsn', 'string'],
    'MAUTIC_MAILER_FROM_EMAIL'    => ['mailer_from_email', 'string'],
    'MAUTIC_MAILER_FROM_NAME'     => ['mailer_from_name', 'string'],
    'MAUTIC_MESSENGER_DSN_EMAIL'  => ['messenger_dsn_email', 'string'],
    'MAUTIC_MESSENGER_DSN_HIT'    => ['messenger_dsn_hit', 'string'],
    'MAUTIC_MESSENGER_DSN_FAILED' => ['messenger_dsn_failed', 'string'],
];

function logmsg(string $msg): void
{
    fwrite(STDERR, sprintf("[mautic-entrypoint] %s\n", $msg));
}

function fail(string $msg, int $code = 1): never
{
    logmsg('ERROR: '.$msg);
    exit($code);
}

/** Read NAME or the file referenced by NAME_FILE. */
function env(string $name, ?string $default = null): ?string
{
    $value = getenv($name);
    if (false !== $value && '' !== $value) {
        return $value;
    }
    $file = getenv($name.'_FILE');
    if (false !== $file && '' !== $file) {
        if (!is_readable($file)) {
            fail("{$name}_FILE points to unreadable file $file");
        }

        return rtrim((string) file_get_contents($file), "\r\n");
    }

    return $default;
}

/** @return array<string, mixed> */
function buildParameters(): array
{
    $params = [];
    foreach (PARAMETER_MAP as $var => [$key, $type]) {
        $value = env($var);
        if (null === $value) {
            continue;
        }
        $params[$key] = 'list' === $type
            ? array_values(array_filter(preg_split('/[\s,]+/', $value) ?: []))
            : $value;
    }

    $extra = env('MAUTIC_CONFIG_PARAMETERS');
    if (null !== $extra) {
        $decoded = json_decode($extra, true);
        if (!is_array($decoded)) {
            fail('MAUTIC_CONFIG_PARAMETERS must be a JSON object');
        }
        $params = array_merge($params, $decoded);
    }

    return $params;
}

/** Environment for child processes: current env + resolved parameters. */
function childEnv(array $params): array
{
    $environment = getenv();
    foreach (array_keys(PARAMETER_MAP) as $var) {
        unset($environment[$var.'_FILE']);
    }
    $environment['MAUTIC_CONFIG_PARAMETERS'] = json_encode($params, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);

    return $environment;
}

function db(array $params): PDO
{
    foreach (['db_host', 'db_name', 'db_user'] as $required) {
        if (empty($params[$required])) {
            fail('missing database setting '.strtoupper('mautic_'.$required));
        }
    }
    $dsn = sprintf('mysql:host=%s;port=%s;dbname=%s;charset=utf8mb4',
        $params['db_host'], $params['db_port'] ?? '3306', $params['db_name']);

    return new PDO($dsn, $params['db_user'], $params['db_password'] ?? '', [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_TIMEOUT => 5,
    ]);
}

function waitForDb(array $params, int $timeout): PDO
{
    $deadline = time() + $timeout;
    $attempt  = 0;
    while (true) {
        try {
            return db($params);
        } catch (PDOException $e) {
            if (time() >= $deadline) {
                fail('database not reachable after '.$timeout.'s: '.$e->getMessage());
            }
            if (0 === $attempt++ % 6) {
                logmsg('waiting for database: '.$e->getMessage());
            }
            sleep(5);
        }
    }
}

/** Installed = Mautic's users table exists in the configured schema. */
function isInstalled(PDO $pdo, array $params): bool
{
    $stmt = $pdo->prepare(
        'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = ? AND table_name = ?'
    );
    $stmt->execute([$params['db_name'], ($params['db_table_prefix'] ?? '').'users']);

    return (int) $stmt->fetchColumn() > 0;
}

/** Run a console command as a child process, streaming its output. */
function console(array $args, array $environment): int
{
    $cmd  = array_merge([PHP, CONSOLE], $args, ['--no-interaction']);
    $proc = proc_open($cmd, [0 => ['file', '/dev/null', 'r'], 1 => STDOUT, 2 => STDERR], $pipes, APP_ROOT, $environment);
    if (!is_resource($proc)) {
        fail('could not start '.implode(' ', $cmd));
    }

    return proc_close($proc);
}

/** Replace this process (keeps PID 1 / signal handling with the real service). */
function execProgram(string $path, array $args, array $environment): never
{
    chdir(APP_ROOT);
    pcntl_exec($path, $args, $environment);
    fail('exec failed: '.$path.' '.pcntl_strerror(pcntl_get_last_error()));
}

/** var/ is usually an emptyDir; recreate the layout Mautic expects. */
function ensureVarDirs(): void
{
    foreach (['cache', 'logs', 'tmp', 'spool'] as $sub) {
        $dir = APP_ROOT.'/var/'.$sub;
        if (!is_dir($dir) && !@mkdir($dir, 0o775, true) && !is_dir($dir)) {
            fail("cannot create $dir (is /app/var writable?)");
        }
    }
}

function ensureLocalConfig(): void
{
    // Mautic writes local.php (installer, settings UI) into config/, which is
    // expected to be a persistent volume. Make sure it is writable.
    $dir = APP_ROOT.'/config';
    if (!is_dir($dir) || !is_writable($dir)) {
        fail("$dir must be a writable directory (mount a persistent volume)");
    }
}

function init(array $params, array $environment): void
{
    ensureLocalConfig();
    $pdo = waitForDb($params, (int) env('MAUTIC_DB_WAIT_TIMEOUT', '300'));

    if (!isInstalled($pdo, $params)) {
        $password = env('MAUTIC_ADMIN_PASSWORD');
        if (null === $password) {
            fail('Mautic is not installed and MAUTIC_ADMIN_PASSWORD is not set — set it to install automatically');
        }
        if (empty($params['site_url'])) {
            fail('MAUTIC_SITE_URL is required for installation');
        }
        logmsg('database is empty, installing Mautic');
        // Mautic considers itself installed as soon as site_url is set, so
        // the installer must not see it through MAUTIC_CONFIG_PARAMETERS.
        $installEnv = $environment;
        $installParams = $params;
        unset($installParams['site_url']);
        $installEnv['MAUTIC_CONFIG_PARAMETERS'] = json_encode($installParams, JSON_UNESCAPED_SLASHES);
        $args = [
            'mautic:install', $params['site_url'], '--force',
            '--db_host='.$params['db_host'],
            '--db_port='.($params['db_port'] ?? '3306'),
            '--db_name='.$params['db_name'],
            '--db_user='.$params['db_user'],
            '--db_password='.($params['db_password'] ?? ''),
            '--admin_username='.env('MAUTIC_ADMIN_USERNAME', 'admin'),
            '--admin_email='.env('MAUTIC_ADMIN_EMAIL', 'admin@example.com'),
            '--admin_password='.$password,
            '--admin_firstname='.env('MAUTIC_ADMIN_FIRSTNAME', 'Admin'),
            '--admin_lastname='.env('MAUTIC_ADMIN_LASTNAME', 'Mautic'),
        ];
        if (!empty($params['db_table_prefix'])) {
            $args[] = '--db_table_prefix='.$params['db_table_prefix'];
        }
        if (0 !== $rc = console($args, $installEnv)) {
            fail('installation failed', $rc);
        }
        logmsg('installation finished');
    }

    if (!is_file(APP_ROOT.'/config/local.php')) {
        // Database exists (e.g. restored from backup) but the config volume is
        // fresh: write a minimal local.php so Mautic uses env parameters.
        file_put_contents(APP_ROOT.'/config/local.php', "<?php\n\$parameters = [];\n");
        logmsg('created empty config/local.php (settings come from the environment)');
    }

    logmsg('running database migrations');
    if (0 !== $rc = console(['doctrine:migrations:migrate', '--allow-no-migration'], $environment)) {
        fail('migrations failed', $rc);
    }
    if (0 !== $rc = console(['mautic:plugins:reload'], $environment)) {
        fail('plugin reload failed', $rc);
    }
    logmsg('init complete');
}

// ---------------------------------------------------------------------------

$argv0  = array_slice($argv, 1);
$cmd    = $argv0[0] ?? 'web';
$rest   = array_slice($argv0, 1);
$params = buildParameters();
$envOut = childEnv($params);
if (in_array($cmd, ['web', 'init', 'worker', 'console'], true)) {
    ensureVarDirs();
}

switch ($cmd) {
    case 'web':
        execProgram(HTTPD, ['-DFOREGROUND', '-f', '/etc/kopexa/httpd/httpd.conf'], $envOut);

    case 'init':
        init($params, $envOut);
        exit(0);

    case 'worker':
        $pdo = waitForDb($params, (int) env('MAUTIC_DB_WAIT_TIMEOUT', '300'));
        while (!isInstalled($pdo, $params)) {
            logmsg('waiting for Mautic to be installed');
            sleep(15);
        }
        $transports = $rest ?: ['email', 'hit'];
        execProgram(PHP, array_merge([CONSOLE, 'messenger:consume'], $transports, [
            '--time-limit='.env('MAUTIC_WORKER_TIME_LIMIT', '3600'),
            '--memory-limit='.env('MAUTIC_WORKER_MEMORY_LIMIT', '256M'),
            '--no-interaction',
        ]), $envOut);

    case 'console':
        if ([] === $rest) {
            fail('usage: console <command> [args…]');
        }
        if (!isInstalled(waitForDb($params, 60), $params)) {
            logmsg('Mautic is not installed yet, skipping: '.implode(' ', $rest));
            exit(0);
        }
        execProgram(PHP, array_merge([CONSOLE], $rest), $envOut);

    case 'version':
        $composer = json_decode((string) file_get_contents(APP_ROOT.'/vendor/composer/installed.json'), true);
        foreach ($composer['packages'] ?? [] as $package) {
            if ('mautic/core-lib' === $package['name']) {
                echo $package['version'], "\n";
                exit(0);
            }
        }
        fail('could not determine Mautic version');

    default:
        fail("unknown command '$cmd' (web|init|worker|console|version)");
}
