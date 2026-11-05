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
 *   plugins             list built-in extensions and their versions
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
    // SAML SSO. Mautic stores metadata/certificate/key base64-encoded; plain
    // XML / PEM (e.g. from a mounted ConfigMap or TLS Secret) is encoded here.
    'MAUTIC_SAML_IDP_METADATA'            => ['saml_idp_metadata', 'base64'],
    'MAUTIC_SAML_IDP_ENTITY_ID'           => ['saml_idp_entity_id', 'string'],
    'MAUTIC_SAML_IDP_OWN_CERTIFICATE'     => ['saml_idp_own_certificate', 'base64'],
    'MAUTIC_SAML_IDP_OWN_PRIVATE_KEY'     => ['saml_idp_own_private_key', 'base64'],
    'MAUTIC_SAML_IDP_OWN_PASSWORD'        => ['saml_idp_own_password', 'string'],
    'MAUTIC_SAML_IDP_EMAIL_ATTRIBUTE'     => ['saml_idp_email_attribute', 'string'],
    'MAUTIC_SAML_IDP_USERNAME_ATTRIBUTE'  => ['saml_idp_username_attribute', 'string'],
    'MAUTIC_SAML_IDP_FIRSTNAME_ATTRIBUTE' => ['saml_idp_firstname_attribute', 'string'],
    'MAUTIC_SAML_IDP_LASTNAME_ATTRIBUTE'  => ['saml_idp_lastname_attribute', 'string'],
    'MAUTIC_SAML_IDP_DEFAULT_ROLE'        => ['saml_idp_default_role', 'string'],
    // kopexa/mautic-postal-bundle: verify Postal webhook signatures.
    'MAUTIC_POSTAL_JWKS_URL'              => ['postal_jwks_url', 'string'],
    'MAUTIC_POSTAL_WEBHOOK_PUBLIC_KEY'    => ['postal_webhook_public_key', 'string'],
    'MAUTIC_OAUTH_PRIVATE_KEY'            => ['kopexa_oauth_private_key', 'string'],
    'MAUTIC_OAUTH_ENCRYPTION_KEY'         => ['kopexa_oauth_encryption_key', 'string'],
    'MAUTIC_OAUTH_REDIRECT_HOSTS'         => ['kopexa_oauth_redirect_hosts', 'list'],
    'MAUTIC_OAUTH_RESOURCE'               => ['kopexa_oauth_resource', 'string'],
    'MAUTIC_MCP_LIVE_CAMPAIGN_EDITS'      => ['kopexa_mcp_live_campaign_edits', 'bool'],
    'MAUTIC_CORS_RESTRICT_DOMAINS'        => ['cors_restrict_domains', 'bool'],
    'MAUTIC_CORS_VALID_DOMAINS'           => ['cors_valid_domains', 'list'],
    'MAUTIC_IP_LOOKUP_SERVICE'            => ['ip_lookup_service', 'string'],
    'MAUTIC_IP_LOOKUP_AUTH'               => ['ip_lookup_auth', 'string'],
    // Redis/Valkey cache: see buildParameters().
    'MAUTIC_REDIS_URL'                    => ['_redis_url', 'string'],
    'MAUTIC_REDIS_PASSWORD'               => ['_redis_password', 'string'],
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
        $params[$key] = match ($type) {
            'list'   => array_values(array_filter(preg_split('/[\s,]+/', $value) ?: [])),
            'bool'   => in_array(strtolower(trim($value)), ['1', 'true', 'yes', 'on'], true),
            // Already base64 (as Mautic stores it) is kept; XML/PEM is encoded.
            'base64' => preg_match('/^\s*(<|-----BEGIN)/', $value) ? base64_encode(trim($value)) : trim($value),
            default  => $value,
        };
    }

    // MAUTIC_REDIS_URL (redis://host:6379) switches Mautic's cache to Redis /
    // Valkey. Passed as a one-element list of URI strings: given a plain URL,
    // Mautic (PRedisConnectionHelper) resolves the host into an array of
    // endpoint arrays, which Predis rejects without a cluster option ("Array
    // of connection parameters requires cluster, replication or aggregate").
    // A list of one string is turned into a single connection, and Predis
    // takes the password from the URI.
    $redisUrl      = $params['_redis_url'] ?? null;
    $redisPassword = $params['_redis_password'] ?? null;
    unset($params['_redis_url'], $params['_redis_password']);
    if (null !== $redisUrl && '' !== $redisUrl) {
        if (null !== $redisPassword && '' !== $redisPassword) {
            $redisUrl = preg_replace('#^(rediss?)://#', '$1://:'.rawurlencode($redisPassword).'@', $redisUrl, 1);
        }
        $params['cache_adapter']           = 'mautic.cache.adapter.redis';
        $params['cache_adapter_tag_aware'] = 'mautic.cache.adapter.redis_tag_aware';
        $params['cache_adapter_redis']     = [
            'dsn'     => [$redisUrl],
            'options' => ['lazy' => true, 'persistent' => 0, 'timeout' => 5, 'read_timeout' => 5, 'retry_interval' => 100],
        ];
    }

    // Fonts of the builders (editor_fonts). Mautic injects every entry with a
    // URL as a stylesheet into the pages it renders; its defaults load eight
    // Google Fonts, sending every visitor's IP to Google. Ours: the Kopexa
    // brand fonts, self-hosted by the theme, and system fonts. Override with
    // MAUTIC_CONFIG_PARAMETERS {"editor_fonts": [...]}.
    $site = rtrim((string) ($params['site_url'] ?? ''), '/');
    $params['editor_fonts'] = [
        ['name' => 'Inter', 'font' => "Inter, 'Segoe UI', Helvetica, Arial, sans-serif", 'url' => $site.'/themes/kopexa/assets/fonts/kopexa-fonts.css'],
        ['name' => 'IBM Plex Sans', 'font' => "'IBM Plex Sans', Inter, Helvetica, Arial, sans-serif"],
        ['name' => 'Geist Mono', 'font' => "'Geist Mono', 'Courier New', monospace"],
        ['name' => 'Arial', 'font' => 'Arial, Helvetica Neue, Helvetica, sans-serif'],
        ['name' => 'Courier New', 'font' => 'Courier New, Courier, Lucida Sans Typewriter, Lucida Typewriter, monospace'],
        ['name' => 'Georgia', 'font' => 'Georgia, Times, Times New Roman, serif'],
        ['name' => 'Helvetica', 'font' => 'Helvetica Neue, Helvetica, Arial, sans-serif'],
        ['name' => 'Tahoma', 'font' => 'Tahoma, Verdana, Segoe, sans-serif'],
        ['name' => 'Times New Roman', 'font' => 'TimesNewRoman, Times New Roman, Times, Baskerville, Georgia, serif'],
        ['name' => 'Trebuchet MS', 'font' => 'Trebuchet MS, Lucida Grande, Lucida Sans Unicode, Lucida Sans, Tahoma, sans-serif'],
        ['name' => 'Verdana', 'font' => 'Verdana, Geneva, sans-serif'],
    ];

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

/**
 * Environment for child processes.
 *
 * Mautic itself maps every parameter to an env var MAUTIC_<KEY> (lists as
 * JSON) and lets real OS env vars win. Our convenience variables share those
 * names but not the format (e.g. comma lists), so they are removed here and
 * handed over only through MAUTIC_CONFIG_PARAMETERS; Mautic then derives its
 * MAUTIC_* variables consistently from the merged configuration.
 */
function childEnv(array $params): array
{
    $environment = getenv();
    foreach (array_keys(PARAMETER_MAP) as $var) {
        unset($environment[$var], $environment[$var.'_FILE']);
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

function roleIdByName(PDO $pdo, array $params, string $name): ?int
{
    $stmt = $pdo->prepare(sprintf('SELECT id FROM `%sroles` WHERE name = ?', $params['db_table_prefix'] ?? ''));
    $stmt->execute([$name]);
    $id = $stmt->fetchColumn();

    return false === $id ? null : (int) $id;
}

/**
 * MAUTIC_SAML_IDP_DEFAULT_ROLE_NAME: Mautic stores the SAML default role as
 * an ID; web, worker and cron build their configuration from the
 * environment at start, so each resolves the name here. If the role is
 * missing, SSO starts without a default role (logged) instead of failing
 * the service; the init container fails in that case.
 */
function resolveSamlDefaultRole(array &$params): void
{
    $name = env('MAUTIC_SAML_IDP_DEFAULT_ROLE_NAME');
    if (null === $name) {
        return;
    }
    try {
        $id = roleIdByName(db($params), $params, $name);
    } catch (Throwable $e) {
        logmsg(sprintf('WARNING: cannot look up SAML default role "%s" (%s); SSO starts without a default role', $name, $e->getMessage()));
        unset($params['saml_idp_default_role']);

        return;
    }
    if (null === $id) {
        logmsg(sprintf('WARNING: SAML default role "%s" does not exist; SSO starts without a default role', $name));
        unset($params['saml_idp_default_role']);

        return;
    }
    $params['saml_idp_default_role'] = (string) $id;
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

/**
 * Mautic's HTTP middlewares (TrustMiddleware: trusted_proxies, trusted_hosts;
 * CORS, HSTS) run before the kernel boots and read only config/local.php and
 * config/parameters_local.php — they ignore MAUTIC_CONFIG_PARAMETERS. Without
 * this file, trusted proxies set through the environment have no effect and
 * Mautic behind a TLS-terminating ingress sees every request as plain HTTP.
 *
 * parameters_local.php has the same precedence as the environment (both
 * override local.php), so reading the environment here changes nothing else.
 */
const PARAMETERS_LOCAL = <<<'PHP'
<?php
// Managed by the container entrypoint (kopexa-grc/mautic-stack); rewritten at
// every start. Makes MAUTIC_CONFIG_PARAMETERS visible to Mautic's middlewares.
$parameters = json_decode((string) getenv('MAUTIC_CONFIG_PARAMETERS'), true) ?: [];

PHP;

function writeParametersLocal(): void
{
    $file = APP_ROOT.'/config/parameters_local.php';
    if (is_file($file) && PARAMETERS_LOCAL === file_get_contents($file)) {
        return;
    }
    if (!is_writable(dirname($file)) || false === @file_put_contents($file.'.tmp', PARAMETERS_LOCAL) || !@rename($file.'.tmp', $file)) {
        logmsg("WARNING: cannot write $file — trusted proxies/hosts from the environment will not apply");
    }
}

function ensureLocalConfig(): void
{
    // Mautic writes local.php (installer, settings UI) into config/, which is
    // expected to be a persistent volume. Make sure it is writable.
    $dir = APP_ROOT.'/config';
    if (!is_dir($dir) || !is_writable($dir)) {
        $stat = @stat($dir);
        fail(sprintf('%s must be a writable directory (mount a persistent volume); owner uid=%s mode=%s, running as uid=%d',
            $dir, $stat['uid'] ?? '?', isset($stat['mode']) ? decoct($stat['mode'] & 0o7777) : '?', posix_getuid()));
    }
}

function init(array $params, array $environment): void
{
    ensureLocalConfig();
    $pdo = waitForDb($params, (int) env('MAUTIC_DB_WAIT_TIMEOUT', '300'));

    // Several replicas may start at once: serialise install + migrations
    // with a MySQL advisory lock (released automatically on disconnect).
    $lockName = 'mautic-init-'.$params['db_name'];
    logmsg('acquiring init lock');
    $lock = $pdo->prepare('SELECT GET_LOCK(?, ?)');
    $lock->execute([$lockName, (int) env('MAUTIC_INIT_LOCK_TIMEOUT', '900')]);
    if (1 !== (int) $lock->fetchColumn()) {
        fail('timed out waiting for the init lock held by another replica');
    }

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

    // Pages and emails saved with Mautic's default editor fonts still link
    // Google Fonts in their stored HTML; editor_fonts no longer adds them.
    if (0 !== $rc = console(['kopexa:privacy:strip-third-party-fonts'], $environment)) {
        fail('removing third-party fonts failed', $rc);
    }

    // Roles from the Helm values (mautic.roles), matched by name.
    $roles = trim((string) env('MAUTIC_ROLES', ''));
    if ('' !== $roles && '[]' !== $roles) {
        logmsg('syncing roles');
        if (0 !== $rc = console(['kopexa:roles:sync'], $environment)) {
            fail('role sync failed', $rc);
        }
    }

    // The SAML default role by name must exist now (declared in mautic.roles
    // or created in Mautic): fail the init rather than start SSO without it.
    $name = env('MAUTIC_SAML_IDP_DEFAULT_ROLE_NAME');
    if (null !== $name && null === roleIdByName($pdo, $params, $name)) {
        fail(sprintf('SAML default role "%s" does not exist: declare it in mautic.roles or create it in Mautic', $name));
    }
    logmsg('init complete');
}

// ---------------------------------------------------------------------------

$argv0  = array_slice($argv, 1);
$cmd    = $argv0[0] ?? 'web';
$rest   = array_slice($argv0, 1);
$params = buildParameters();
if (in_array($cmd, ['web', 'worker', 'console'], true)) {
    resolveSamlDefaultRole($params);
}
$envOut = childEnv($params);
if (in_array($cmd, ['web', 'init', 'worker', 'console'], true)) {
    ensureVarDirs();
    writeParametersLocal();
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

    case 'plugins':
        // Built-in extensions (image/plugins.txt) with installed versions.
        $installed = json_decode((string) file_get_contents(APP_ROOT.'/vendor/composer/installed.json'), true);
        foreach ($installed['packages'] ?? [] as $package) {
            if (in_array($package['type'] ?? '', ['mautic-plugin', 'mautic-theme', 'symfony-mailer-bridge'], true)
                || str_ends_with($package['name'], '-mailer')) {
                printf("%s %s\n", $package['name'], $package['version']);
            }
        }
        exit(0);

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
        fail("unknown command '$cmd' (web|init|worker|console|plugins|version)");
}
