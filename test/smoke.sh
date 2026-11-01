#!/usr/bin/env bash
# End-to-end smoke test for the Mautic image:
# MariaDB → init (auto-install + migrations) → web → HTTP checks → console → worker.
#
#   test/smoke.sh <image-ref>
set -euo pipefail
IMG="${1:?usage: smoke.sh <image-ref>}"
DB_IMAGE="${DB_IMAGE:-mariadb:11.4}"
run_id="mautic-smoke-$$"
net="$run_id"

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; dump; exit 1; }
dump() {
  echo "--- web logs";  docker logs "$run_id-web" 2>&1 | tail -40 || true
  echo "--- db logs";   docker logs "$run_id-db" 2>&1 | tail -10 || true
}
cleanup() {
  docker rm -f "$run_id-db" "$run_id-web" >/dev/null 2>&1 || true
  docker volume rm -f "$run_id-config" "$run_id-media" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$net" >/dev/null
docker volume create "$run_id-config" >/dev/null
docker volume create "$run_id-media" >/dev/null

docker run -d --name "$run_id-db" --network "$net" \
  -e MARIADB_DATABASE=mautic -e MARIADB_USER=mautic -e MARIADB_PASSWORD=mautic \
  -e MARIADB_RANDOM_ROOT_PASSWORD=1 "$DB_IMAGE" \
  --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci >/dev/null

# Same hardening as the Helm chart: read-only rootfs, no capabilities,
# writable /tmp + var, persistent config + media.
# shellcheck disable=SC2054  # commas belong to the tmpfs mount options
hardening=(
  --read-only --tmpfs /tmp --tmpfs /app/var:uid=65532,gid=65532
  --cap-drop ALL --security-opt no-new-privileges
  -v "$run_id-config:/app/config" -v "$run_id-media:/app/docroot/media/images"
)
env=(
  -e MAUTIC_DB_HOST="$run_id-db" -e MAUTIC_DB_NAME=mautic
  -e MAUTIC_DB_USER=mautic -e MAUTIC_DB_PASSWORD_FILE=/run/secrets/db-password
  -e MAUTIC_SITE_URL=http://localhost:8080
  -e MAUTIC_ADMIN_EMAIL=admin@example.com -e MAUTIC_ADMIN_PASSWORD='Sm0ke-Test-Passw0rd!'
  -e MAUTIC_TRUSTED_PROXIES=172.16.0.0/12
  -e MAUTIC_MESSENGER_DSN_EMAIL=doctrine://default -e MAUTIC_MESSENGER_DSN_HIT=doctrine://default
)
secret="$(mktemp)"; echo mautic >"$secret"; chmod 644 "$secret"
env+=(-v "$secret:/run/secrets/db-password:ro")

# Volumes are created root-owned; the chart uses fsGroup, here we chown once.
docker run --rm -u 0 --entrypoint /usr/bin/php -v "$run_id-config:/c" -v "$run_id-media:/m" "$IMG" \
  -r 'foreach (["/c","/m"] as $d) { chown($d, 65532); chgrp($d, 65532); }'

echo "init (install + migrations)"
docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" "$IMG" init \
  || fail "init failed"
pass "init completed"

echo "init is idempotent"
docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" "$IMG" init >/dev/null 2>&1 \
  || fail "second init failed"
pass "second init completed"

docker run -d --name "$run_id-web" --network "$net" "${hardening[@]}" "${env[@]}" \
  -p 127.0.0.1::8080 "$IMG" web >/dev/null
port="$(docker port "$run_id-web" 8080/tcp | head -1 | sed 's/.*://')"
base="http://127.0.0.1:$port"
for _ in $(seq 1 60); do curl -fs "$base/healthz" >/dev/null && break; sleep 1; done

code() { curl -s -o /dev/null -w '%{http_code}' "$base$1"; }

login="$(curl -s -L "$base/s/login")"
grep -q 'name="_username"' <<<"$login" && pass "login page renders" || fail "login page"
[[ "$(code /healthz)" == 200 ]] && pass "/healthz" || fail "/healthz"
[[ "$(code /mtc.js)" == 200 ]] && pass "tracking script /mtc.js" || fail "/mtc.js"
[[ "$(code /mtracking.gif)" == 200 ]] && pass "tracking pixel" || fail "/mtracking.gif"
[[ "$(code /composer.json)" =~ ^(403|404)$ ]] && pass "composer.json not served" || fail "composer.json served"
[[ "$(code /.htaccess)" == 403 ]] && pass ".htaccess denied" || fail ".htaccess served"
[[ "$(code /media/files/x.php)" =~ ^(403|404)$ ]] && pass "media/files denied" || fail "media/files"
[[ "$(code /app/bundles/CoreBundle/Config/config.php)" =~ ^(403|404)$ ]] && pass "bundle PHP not reachable" || fail "bundle PHP reachable"

# A PHP file dropped into the uploads volume must not execute.
docker exec "$run_id-web" /usr/bin/php -r 'file_put_contents("/app/docroot/media/images/evil.php", "<?php echo \"PWNED\";");'
body="$(curl -s "$base/media/images/evil.php")"
[[ "$body" != *PWNED* ]] && pass "uploaded PHP does not execute" || fail "uploaded PHP executed"

# Login with the auto-installed admin.
jar="$(mktemp)"
csrf="$(curl -s -c "$jar" -b "$jar" "$base/s/login" | sed -n 's/.*name="_csrf_token" value="\([^"]*\)".*/\1/p' | head -1)"
[[ -n "$csrf" ]] || fail "no CSRF token on login page"
login_to="$(curl -s -o /dev/null -c "$jar" -b "$jar" -w '%{redirect_url}' \
  -H "Origin: $base" -H "Referer: $base/s/login" \
  --data-urlencode _username=admin --data-urlencode '_password=Sm0ke-Test-Passw0rd!' \
  --data-urlencode "_csrf_token=$csrf" "$base/s/login_check")"
echo "  login_check -> $login_to"
final="$(curl -s -L -c "$jar" -b "$jar" -o /tmp/mautic-smoke-page.html -w '%{http_code} %{url_effective}' "$base/s/dashboard")"
echo "  dashboard   -> $final"
if grep -q 'name="_username"' /tmp/mautic-smoke-page.html || [[ "$final" != 200* ]]; then
  grep -o '<div class="alert[^<]*<[^<]*' /tmp/mautic-smoke-page.html | head -3 || true
  fail "admin login"
fi
pass "admin login works"

echo "console + worker"
docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" "$IMG" console mautic:segments:update \
  >/dev/null 2>&1 && pass "console mautic:segments:update" || fail "console command"
docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" \
  -e MAUTIC_WORKER_TIME_LIMIT=5 "$IMG" worker >/dev/null 2>&1 \
  && pass "worker starts and exits on time limit" || fail "worker"

echo "built-in extensions (image/plugins.txt)"
installed="$(docker run --rm "$IMG" plugins)"
while read -r spec; do
  pkg="${spec%%:*}"
  grep -q "^$pkg " <<<"$installed" && pass "installed: $pkg ($(grep "^$pkg " <<<"$installed" | cut -d' ' -f2))" \
    || fail "missing extension $pkg"
done < <(grep -vE '^\s*(#|$)' "$(dirname "$0")/../image/plugins.txt")
init_out="$(docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" "$IMG" init 2>&1)"
grep -qiE 'plugins? (were|was) (installed|updated)|0 updated' <<<"$init_out" && pass "plugins registered with Mautic" || { echo "$init_out" | tail -5; fail "plugin reload"; }

v="$(docker run --rm "$IMG" version)"
pass "mautic version $v"
