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
  echo "--- mautic logs"
  docker exec "$run_id-web" /usr/bin/php -r 'foreach (glob("/app/var/logs/*.php") as $f) { echo "$f\n", implode("", array_slice(file($f), -15)); }' 2>&1 | cut -c1-1500 || true
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
# Postal webhook signing key (the test plays the Postal server).
postal_key="$(mktemp)"; openssl genrsa -out "$postal_key" 2048 2>/dev/null
env+=(-e MAUTIC_POSTAL_WEBHOOK_PUBLIC_KEY="$(openssl rsa -in "$postal_key" -pubout 2>/dev/null)")
# OAuth 2.1 authorization server (kopexa/mautic-oauth-bundle).
oauth_key="$(mktemp)"; openssl genrsa -out "$oauth_key" 2048 2>/dev/null
env+=(-e MAUTIC_OAUTH_PRIVATE_KEY="$(cat "$oauth_key")" -e MAUTIC_OAUTH_ENCRYPTION_KEY="$(openssl rand -hex 32)")
env+=(-e 'MAUTIC_CONFIG_PARAMETERS={"api_enabled":true,"api_enable_basic_auth":true}')
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
login_as_admin() { # $1 = cookie jar; prints where login_check redirects to
  local csrf
  csrf="$(curl -s -c "$1" -b "$1" "$base/s/login" | sed -n 's/.*name="_csrf_token" value="\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$csrf" ]] || fail "no CSRF token on login page"
  curl -s -o /dev/null -c "$1" -b "$1" -w '%{redirect_url}' \
    -H "Origin: $base" -H "Referer: $base/s/login" \
    --data-urlencode _username=admin --data-urlencode '_password=Sm0ke-Test-Passw0rd!' \
    --data-urlencode "_csrf_token=$csrf" "$base/s/login_check"
}
jar="$(mktemp)"
login_to="$(login_as_admin "$jar")"
echo "  login_check -> $login_to"
final="$(curl -s -L -c "$jar" -b "$jar" -o /tmp/mautic-smoke-page.html -w '%{http_code} %{url_effective}' "$base/s/dashboard")"
echo "  dashboard   -> $final"
if grep -q 'name="_username"' /tmp/mautic-smoke-page.html || [[ "$final" != 200* ]]; then
  grep -o '<div class="alert[^<]*<[^<]*' /tmp/mautic-smoke-page.html | head -3 || true
  fail "admin login"
fi
pass "admin login works"

echo "Kopexa email theme"
[[ "$(code /themes/kopexa/assets/logo-light.png)" == 200 ]] && pass "theme assets served" || fail "theme assets not served"
[[ "$(code /themes/kopexa/thumbnail.png)" == 200 ]] && pass "theme thumbnail present" || fail "theme thumbnail missing"
[[ "$(code /themes/kopexa/qa/package.json)" =~ ^(403|404)$ ]] && pass "theme QA tooling not shipped" || fail "theme QA files reachable"
grep -q '^kopexa/mautic-theme-kopexa ' <<<"$(docker run --rm "$IMG" plugins)" && pass "theme installed via Composer" || fail "theme not installed"

echo "Postal bounce webhook (kopexa/mautic-postal-bundle)"
api() { curl -s -u 'admin:Sm0ke-Test-Passw0rd!' -H 'Accept: application/json' "$@"; }
cid="$(api -X POST "$base/api/contacts/new" -d email=bounce@example.com | jq -r '.contact.id')"
[[ "$cid" =~ ^[0-9]+$ ]] || fail "contact for bounce test"
postal() { # $1 = body, $2 = key used for signing
  local sig; sig="$(printf '%s' "$1" | openssl dgst -sha256 -sign "$2" | base64 -w0)"
  curl -s -o /tmp/postal-resp -w '%{http_code}' -X POST "$base/mailer/callback" \
    -H 'Content-Type: application/json' -H "X-Postal-Signature-256: $sig" --data-binary "$1"
}
bounce='{"event":"MessageBounced","timestamp":1793500000.1,"uuid":"e2e-1","payload":{"original_message":{"id":1,"direction":"outgoing","to":"bounce@example.com","subject":"E2E"},"bounce":{"id":2}}}'
wrong_key="$(mktemp)"; openssl genrsa -out "$wrong_key" 2048 2>/dev/null
[[ "$(postal "$bounce" "$wrong_key")" == 403 ]] && pass "webhook with wrong signature rejected (403)" || fail "bad signature accepted"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/mailer/callback" -d '{}')" == 404 ]] \
  && pass "unsigned request left to other transports (404)" || fail "unsigned request handled"
[[ "$(postal "$bounce" "$postal_key")" == 200 ]] && jq -e '.handled == true' /tmp/postal-resp >/dev/null \
  && pass "signed MessageBounced accepted" || { cat /tmp/postal-resp; fail "signed bounce"; }
dnc="$(api "$base/api/contacts/$cid" | jq -r '.contact.doNotContact[0].reason // empty')"
[[ "$dnc" == 2 ]] && pass "contact marked Do Not Contact: bounced" || fail "contact not marked bounced (reason=$dnc)"
delayed='{"event":"MessageDelayed","payload":{"message":{"direction":"outgoing","to":"bounce@example.com"},"status":"SoftFail"}}'
[[ "$(postal "$delayed" "$postal_key")" == 200 ]] && jq -e '.handled == false' /tmp/postal-resp >/dev/null \
  && pass "soft failures are ignored" || fail "soft failure handling"

echo "OAuth 2.1 authorization server (kopexa/mautic-oauth-bundle)"
b64url_decode() { local s; s="$(tr '_-' '/+' <<<"$1")"; while (( ${#s} % 4 )); do s+='='; done; base64 -d <<<"$s"; }
b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
meta="$(curl -s "$base/.well-known/oauth-authorization-server")"
jq -e '.issuer == "http://localhost:8080" and .code_challenge_methods_supported == ["S256"]
       and .token_endpoint_auth_methods_supported == ["none"]
       and (.authorization_endpoint | endswith("/s/oauth2/authorize"))' <<<"$meta" >/dev/null \
  && pass "RFC 8414 metadata (S256 only, public clients)" || { echo "$meta"; fail "authorization server metadata"; }
jwks_n="$(curl -s "$base/oauth2/jwks.json" | jq -r '.keys[0].n')"
key_n="$(openssl rsa -in "$oauth_key" -noout -modulus 2>/dev/null | cut -d= -f2 \
  | python3 -c 'import sys, base64; print(base64.urlsafe_b64encode(bytes.fromhex(sys.stdin.read().strip())).decode().rstrip("="))')"
[[ "$jwks_n" == "$key_n" ]] && pass "JWKS publishes the signing key" || fail "JWKS key mismatch"

reg() { curl -s -o /tmp/oauth-resp -w '%{http_code}' -X POST "$base/oauth2/register" -H 'Content-Type: application/json' -d "$1"; }
[[ "$(reg '{"client_name":"Evil","redirect_uris":["https://evil.example/cb"]}')" == 400 ]] \
  && pass "registration with foreign redirect host rejected" || fail "foreign redirect host accepted"
[[ "$(reg '{"client_name":"Plain","redirect_uris":["http://evil.example/cb"]}')" == 400 ]] \
  && pass "registration with non-https redirect rejected" || fail "http redirect accepted"
redirect="http://127.0.0.1:33418/callback"
[[ "$(reg '{"client_name":"Smoke MCP client","redirect_uris":["'"$redirect"'"],"token_endpoint_auth_method":"client_secret_post"}')" == 201 ]] \
  || { cat /tmp/oauth-resp; fail "dynamic client registration"; }
client_id="$(jq -r .client_id /tmp/oauth-resp)"
jq -e '.token_endpoint_auth_method == "none" and (has("client_secret") | not)' /tmp/oauth-resp >/dev/null \
  && pass "dynamic client registration (public client)" || fail "registration response"

verifier="$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')"
challenge="$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | b64url)"
resource="http://localhost:8080/mcp"
authz() { # $1 = code_challenge_method, $2 = curl cookie jar (or empty)
  curl -s -G -o /tmp/oauth-page -w '%{http_code} %{redirect_url}' ${2:+-b "$2" -c "$2"} "$base/s/oauth2/authorize" \
    --data-urlencode response_type=code --data-urlencode "client_id=$client_id" \
    --data-urlencode "redirect_uri=$redirect" --data-urlencode "code_challenge=$challenge" \
    --data-urlencode "code_challenge_method=$1" --data-urlencode state=smoke-state \
    --data-urlencode 'scope=mcp:read mcp:write' --data-urlencode "resource=$resource"
}
fresh_jar="$(mktemp)"
[[ "$(authz S256 "$fresh_jar")" == *"/s/login"* ]] && pass "authorization requires Mautic login" || fail "authorize without login"
[[ "$(login_as_admin "$fresh_jar")" == *"/s/oauth2/authorize?"*"client_id=$client_id"* ]] \
  && pass "login returns to the authorization request" || fail "login does not return to consent"
[[ "$(authz plain "$jar")" == "302 $redirect?"*"error=invalid_request"* ]] \
  && pass "PKCE plain rejected (S256 required)" || fail "PKCE plain accepted"
[[ "$(authz S256 "$jar")" == "200 " ]] && grep -q 'Smoke MCP client' /tmp/oauth-page \
  && pass "consent page shown to the logged-in user" || fail "consent page"
decide() { # $1 = approve|deny ; reads token + txn from the last consent page
  local token txn
  token="$(sed -n 's/.*name="_token" value="\([^"]*\)".*/\1/p' /tmp/oauth-page)"
  txn="$(sed -n 's/.*name="txn" value="\([^"]*\)".*/\1/p' /tmp/oauth-page)"
  curl -s -o /dev/null -w '%{redirect_url}' -b "$jar" -c "$jar" -X POST "$base/s/oauth2/authorize" \
    --data-urlencode "_token=$token" --data-urlencode "txn=$txn" --data-urlencode "decision=$1"
}
location="$(decide approve)"
[[ "$location" == "$redirect?"*"state=smoke-state"* ]] || fail "approve redirect: $location"
code="$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")"
[[ -n "$code" ]] && pass "approval redirects with an authorization code" || fail "no code in $location"

token() { curl -s -o /tmp/oauth-resp -w '%{http_code}' -X POST "$base/oauth2/token" "$@"; }
code_grant() { token --data-urlencode grant_type=authorization_code --data-urlencode "code=$code" \
  --data-urlencode "client_id=$client_id" --data-urlencode "redirect_uri=$redirect" --data-urlencode "code_verifier=$1"; }
[[ "$(code_grant wrong-verifier-wrong-verifier-wrong-verifier-123)" == 400 ]] \
  && pass "token request with wrong PKCE verifier rejected" || fail "wrong verifier accepted"
[[ "$(code_grant "$verifier")" == 200 ]] || { cat /tmp/oauth-resp; fail "code exchange"; }
access="$(jq -r .access_token /tmp/oauth-resp)"; refresh="$(jq -r .refresh_token /tmp/oauth-resp)"
pass "code exchanged for access + refresh token"
[[ "$(code_grant "$verifier")" == 400 ]] && pass "authorization code is single-use" || fail "code reused"

IFS=. read -r jwt_h jwt_p jwt_s <<<"$access"
header="$(b64url_decode "$jwt_h")"; claims="$(b64url_decode "$jwt_p")"
jq -e '.typ == "at+jwt" and .alg == "RS256" and (.kid | length > 0)' <<<"$header" >/dev/null \
  && jq -e --arg c "$client_id" --arg r "$resource" '.iss == "http://localhost:8080" and .aud == $r
       and .sub == "1" and .client_id == $c and .scope == "mcp:read mcp:write" and .exp > .iat' <<<"$claims" >/dev/null \
  && pass "access token is an RFC 9068 JWT (iss, aud=resource, sub, scope)" || { echo "$header $claims"; fail "JWT claims"; }
openssl rsa -in "$oauth_key" -pubout -out /tmp/oauth-pub.pem 2>/dev/null
b64url_decode "$jwt_s" >/tmp/oauth-sig
printf '%s.%s' "$jwt_h" "$jwt_p" | openssl dgst -sha256 -verify /tmp/oauth-pub.pem -signature /tmp/oauth-sig >/dev/null \
  && pass "JWT signature verifies against the JWKS key" || fail "JWT signature"

refresh_grant() { token --data-urlencode grant_type=refresh_token --data-urlencode "refresh_token=$1" --data-urlencode "client_id=$client_id"; }
[[ "$(refresh_grant "$refresh")" == 200 ]] || { cat /tmp/oauth-resp; fail "refresh"; }
refresh2="$(jq -r .refresh_token /tmp/oauth-resp)"
pass "refresh token grant"
[[ "$(refresh_grant "$refresh")" == 400 ]] && pass "refresh tokens rotate (old one rejected)" || fail "old refresh token accepted"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/oauth2/revoke" --data-urlencode "token=$refresh2" --data-urlencode "client_id=$client_id")" == 200 ]] \
  && [[ "$(refresh_grant "$refresh2")" == 400 ]] && pass "revoked refresh token rejected (RFC 7009)" || fail "revocation"

authz S256 "$jar" >/dev/null
[[ "$(decide deny)" == "$redirect?"*"error=access_denied"* ]] && pass "denied consent returns access_denied" || fail "deny"

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
docker run --rm --entrypoint /usr/bin/php "$IMG" -r '
  require "/app/vendor/autoload.php";
  foreach (["Amazon\\Transport\\SesTransportFactory", "Postmark\\Transport\\PostmarkTransportFactory",
            "Brevo\\Transport\\BrevoTransportFactory", "Mailgun\\Transport\\MailgunTransportFactory",
            "Sendgrid\\Transport\\SendgridTransportFactory", "Mailjet\\Transport\\MailjetTransportFactory"] as $c) {
    $class = "Symfony\\Component\\Mailer\\Bridge\\".$c;
    if (!class_exists($class)) { fwrite(STDERR, "missing $class\n"); exit(1); }
  }' && pass "mailer API bridges loadable" || fail "mailer bridges"
init_out="$(docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" "$IMG" init 2>&1)"
grep -qiE 'plugins? (were|was) (installed|updated)|0 updated' <<<"$init_out" && pass "plugins registered with Mautic" || { echo "$init_out" | tail -5; fail "plugin reload"; }

v="$(docker run --rm "$IMG" version)"
pass "mautic version $v"
