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
  docker rm -f "$run_id-db" "$run_id-web" "$run_id-web2" "$run_id-tls" "$run_id-valkey" "$run_id-replica" >/dev/null 2>&1 || true
  docker volume rm -f "$run_id-config" "$run_id-media" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
}
# SMOKE_KEEP=1 keeps the containers for inspection (debugging).
[[ "${SMOKE_KEEP:-}" == 1 ]] || trap cleanup EXIT

docker network create "$net" >/dev/null
docker volume create "$run_id-config" >/dev/null
docker volume create "$run_id-media" >/dev/null

docker run -d --name "$run_id-db" --network "$net" \
  -e MARIADB_DATABASE=mautic -e MARIADB_USER=mautic -e MARIADB_PASSWORD=mautic \
  -e MARIADB_RANDOM_ROOT_PASSWORD=1 "$DB_IMAGE" \
  --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci >/dev/null
# Valkey for Mautic's cache and the PHP sessions (as the chart does by default).
VALKEY_IMAGE="${VALKEY_IMAGE:-ghcr.io/kopexa-grc/valkey:9.1}"
docker run -d --name "$run_id-valkey" --network "$net" --read-only --cap-drop ALL "$VALKEY_IMAGE" \
  --requirepass valkey-smoke --save "" --appendonly no >/dev/null
valkey() { docker exec "$run_id-valkey" valkey-cli -a valkey-smoke --no-auth-warning "$@"; }

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
  -e "MAUTIC_CORS_VALID_DOMAINS=https://www.kopexa.com https://kopexa.com"
  -e MAUTIC_MESSENGER_DSN_EMAIL=doctrine://default -e MAUTIC_MESSENGER_DSN_HIT=doctrine://default
  -e "MAUTIC_REDIS_URL=redis://$run_id-valkey:6379" -e MAUTIC_REDIS_PASSWORD=valkey-smoke
  -e PHP_SESSION_SAVE_HANDLER=redis -e "PHP_SESSION_SAVE_PATH=tcp://$run_id-valkey:6379?auth=valkey-smoke&prefix=mautic_sess:"
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
preflight() { curl -s -o /dev/null -D - -X OPTIONS -H "Origin: $1" -H 'Access-Control-Request-Headers: content-type' "$base/mtc/event" | tr -d '\r' | sed -n 's/^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: //p'; }
[[ "$(preflight https://www.kopexa.com)" == https://www.kopexa.com && -z "$(preflight https://evil.example)" ]] \
  && pass "CORS from MAUTIC_CORS_VALID_DOMAINS (allowed origin yes, others no)" || fail "CORS: allowed='$(preflight https://www.kopexa.com)' other='$(preflight https://evil.example)'"
# Behind Cloudflare (or any public hop) X-Forwarded-For carries public IPs.
# A replica with an https site URL, reached through a trusted proxy that says
# https, must answer instead of redirecting to itself (301 loop).
docker run -d --name "$run_id-tls" --network "$net" "${hardening[@]}" "${env[@]}" \
  -e MAUTIC_SITE_URL=https://mautic.example.com -p 127.0.0.1::8080 "$IMG" web >/dev/null
tls="http://127.0.0.1:$(docker port "$run_id-tls" 8080/tcp | head -1 | sed 's/.*://')"
for _ in $(seq 1 60); do curl -fs "$tls/healthz" >/dev/null && break; sleep 1; done
for xff in 10.1.1.1 173.245.48.1 '1.2.3.4, 173.245.48.1'; do
  got="$(curl -s -o /dev/null -w '%{http_code} %header{location}' -H 'Host: mautic.example.com' \
    -H 'X-Forwarded-Proto: https' -H "X-Forwarded-For: $xff" "$tls/s/login")"
  [[ "$got" == "200 " ]] || { docker rm -f "$run_id-tls" >/dev/null; fail "https site behind proxy, X-Forwarded-For '$xff': $got"; }
done
docker rm -f "$run_id-tls" >/dev/null
pass "https site behind a proxy: no redirect loop with public IPs in X-Forwarded-For (Cloudflare)"
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
login_as_admin() { # $1 = cookie jar, [$2 = user, $3 = password]; prints where login_check redirects to
  local csrf
  csrf="$(curl -s -c "$1" -b "$1" "$base/s/login" | sed -n 's/.*name="_csrf_token" value="\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$csrf" ]] || fail "no CSRF token on login page"
  curl -s -o /dev/null -c "$1" -b "$1" -w '%{redirect_url}' \
    -H "Origin: $base" -H "Referer: $base/s/login" \
    --data-urlencode "_username=${2:-admin}" --data-urlencode "_password=${3:-Sm0ke-Test-Passw0rd!}" \
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

echo "Valkey (cache + sessions)"
[[ "$(valkey --scan --pattern 'mautic_sess:*' | wc -l)" -ge 1 ]] && pass "PHP sessions stored in Valkey" || fail "no sessions in Valkey"
[[ "$(valkey --scan | grep -vc '^mautic_sess:')" -ge 1 ]] && pass "Mautic cache entries in Valkey" || fail "no cache entries in Valkey"
docker run -d --name "$run_id-replica" --network "$net" "${hardening[@]}" "${env[@]}" -p 127.0.0.1::8080 "$IMG" web >/dev/null
replica="http://127.0.0.1:$(docker port "$run_id-replica" 8080/tcp | head -1 | sed 's/.*://')"
for _ in $(seq 1 60); do curl -fs "$replica/healthz" >/dev/null && break; sleep 1; done
[[ "$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" "$replica/s/dashboard")" == 200 ]] \
  && pass "login on one web pod is valid on another (shared sessions)" || fail "session not shared between web pods"
docker rm -f "$run_id-replica" >/dev/null

echo "Kopexa email theme"
[[ "$(code /themes/kopexa/assets/logo-light.png)" == 200 ]] && pass "theme assets served" || fail "theme assets not served"
[[ "$(code /themes/kopexa/thumbnail.png)" == 200 ]] && pass "theme thumbnail present" || fail "theme thumbnail missing"
[[ "$(code /themes/kopexa/qa/package.json)" =~ ^(403|404)$ ]] && pass "theme QA tooling not shipped" || fail "theme QA files reachable"
grep -q '^kopexa/mautic-theme-kopexa ' <<<"$(docker run --rm "$IMG" plugins)" && pass "theme installed via Composer" || fail "theme not installed"
for v in kopexa-confirm kopexa-hero; do
  [[ "$(code "/themes/$v/thumbnail.png")" == 200 ]] && pass "theme variant $v installed" || fail "theme variant $v missing"
done
[[ "$(code /themes/kopexa/assets/placeholder/card-1.png)" == 200 ]] && pass "placeholder images served" || fail "placeholder images missing"

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
    --data-urlencode "scope=${SCOPE:-mcp:read mcp:write}" --data-urlencode "resource=$resource"
}
fresh_jar="$(mktemp)"
[[ "$(authz S256 "$fresh_jar")" == *"/s/login"* ]] && pass "authorization requires Mautic login" || fail "authorize without login"
[[ "$(login_as_admin "$fresh_jar")" == *"/s/oauth2/authorize?"*"client_id=$client_id"* ]] \
  && pass "login returns to the authorization request" || fail "login does not return to consent"
[[ "$(authz plain "$jar")" == "302 $redirect?"*"error=invalid_request"* ]] \
  && pass "PKCE plain rejected (S256 required)" || fail "PKCE plain accepted"
[[ "$(authz S256 "$jar")" == "200 " ]] && grep -q 'Smoke MCP client' /tmp/oauth-page \
  && pass "consent page shown to the logged-in user" || fail "consent page"
decide() { # $1 = approve|deny ; reads the last consent page; posts the ticked scopes (+ $TICK) like a browser
  local token txn scopes=()
  token="$(sed -n 's/.*name="_token" value="\([^"]*\)".*/\1/p' /tmp/oauth-page)"
  txn="$(sed -n 's/.*name="txn" value="\([^"]*\)".*/\1/p' /tmp/oauth-page)"
  while read -r scope; do [[ -n "$scope" ]] && scopes+=(--data-urlencode "scopes[]=$scope"); done \
    < <(grep -o 'name="scopes\[\]" value="[^"]*" checked' /tmp/oauth-page | sed 's/.*value="\([^"]*\)".*/\1/'; for t in ${TICK:-}; do echo "$t"; done)
  curl -s -o /dev/null -w '%{redirect_url}' -b "$jar" -c "$jar" -X POST "$base/s/oauth2/authorize" \
    --data-urlencode "_token=$token" --data-urlencode "txn=$txn" --data-urlencode "decision=$1" "${scopes[@]}"
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
printf "campaign=%s base=%s\ntoken=%s\nrun=%s\n" "" "$base" "$access" "$run_id" > "${SMOKE_INFO:-/dev/null}"
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
# Opt-in scope: "change RUNNING campaigns" is offered unticked; approving
# with the defaults does not grant it, ticking it does.
SCOPE='mcp:read mcp:write mcp:campaigns:live' authz S256 "$jar" >/dev/null
grep -q 'value="mcp:campaigns:live">' /tmp/oauth-page && grep -q 'value="mcp:write" checked' /tmp/oauth-page \
  && pass "consent page: mcp:campaigns:live is offered unticked (opt-in)" || { grep -o '<li.*</li>' /tmp/oauth-page; fail "consent checkboxes"; }
location="$(decide approve)"; code="$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")"
[[ "$(code_grant "$verifier")" == 200 ]] || fail "token with default ticks"
[[ "$(b64url_decode "$(jq -r .access_token /tmp/oauth-resp | cut -d. -f2)" | jq -r .scope)" == "mcp:read mcp:write" ]] \
  && pass "default approval does not grant mcp:campaigns:live" || fail "live scope granted without ticking"
SCOPE='mcp:read mcp:write mcp:campaigns:live' authz S256 "$jar" >/dev/null
location="$(TICK=mcp:campaigns:live decide approve)"; code="$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")"
[[ "$(code_grant "$verifier")" == 200 ]] || fail "token with live scope"
live_token="$(jq -r .access_token /tmp/oauth-resp)"
[[ "$(b64url_decode "$(cut -d. -f2 <<<"$live_token")" | jq -r .scope)" == "mcp:read mcp:write mcp:campaigns:live" ]] \
  && pass "ticking it grants mcp:campaigns:live" || fail "live scope not granted"

echo "MCP server (kopexa/mautic-mcp-bundle)"
# A second, read-only token for the scope checks.
SCOPE=mcp:read authz S256 "$jar" >/dev/null
location="$(decide approve)"; code="$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")"
[[ "$(code_grant "$verifier")" == 200 ]] || fail "read-only token"
read_token="$(jq -r .access_token /tmp/oauth-resp)"
# A token for the contact tools (scope mcp:contacts:write).
SCOPE='mcp:read mcp:contacts:write' authz S256 "$jar" >/dev/null
location="$(decide approve)"; code="$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")"
[[ "$(code_grant "$verifier")" == 200 ]] || fail "contacts token"
contacts_token="$(jq -r .access_token /tmp/oauth-resp)"

prm="$(curl -s "$base/.well-known/oauth-protected-resource/mcp")"
jq -e --arg r "$resource" '.resource == $r and .authorization_servers == ["http://localhost:8080"]' <<<"$prm" >/dev/null \
  && pass "RFC 9728 protected resource metadata" || { echo "$prm"; fail "resource metadata"; }
mcp() { # $1 = token, $2 = JSON-RPC body; prints the JSON-RPC response (JSON or SSE)
  local out
  out="$(curl -s -D /tmp/mcp-headers -X POST "$base/mcp" -H 'Host: localhost:8080' \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' ${MCP_SESSION:+-H "Mcp-Session-Id: $MCP_SESSION"} --data-binary "$2")"
  if grep -qi '^content-type: text/event-stream' /tmp/mcp-headers; then sed -n 's/^data: //p' <<<"$out" | tail -1; else printf '%s' "$out"; fi
}
unauth="$(curl -s -o /dev/null -D - -X POST "$base/mcp" -H 'Host: localhost:8080' -H 'Content-Type: application/json' -d '{}')"
grep -q '^HTTP/1.1 401' <<<"$unauth" && grep -qi '^www-authenticate: Bearer.*resource_metadata=' <<<"$unauth" \
  && pass "no token: 401 with WWW-Authenticate resource_metadata" || { echo "$unauth"; fail "unauthenticated MCP request"; }
[[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/mcp" -H 'Host: localhost:8080' -H 'Authorization: Bearer x.y.z' -H 'Content-Type: application/json' -d '{}')" == 401 ]] \
  && pass "forged token rejected" || fail "forged token accepted"

init="$(mcp "$access" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}')"
MCP_SESSION="$(sed -n 's/^[Mm]cp-[Ss]ession-[Ii]d: *\([^[:space:]]*\).*/\1/p' /tmp/mcp-headers)"
jq -e '.result.serverInfo.name == "Mautic"' <<<"$init" >/dev/null && [[ -n "$MCP_SESSION" ]] \
  && pass "initialize (session stored in the database)" || { echo "$init"; cat /tmp/mcp-headers; fail "MCP initialize"; }
mcp "$access" '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
tools="$(mcp "$access" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
[[ "$(jq '.result.tools | length' <<<"$tools")" == 36 ]] && jq -e '[.result.tools[].name] | index("create_email_draft") and index("search_contacts") and index("upsert_contacts")' <<<"$tools" >/dev/null \
  && pass "tools/list: 36 tools" || { echo "$tools" | head -c 600; fail "tools/list"; }
call() { mcp "$1" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"'"$2"'","arguments":'"$3"'}}'; }
result() { jq -r '.result.content[0].text // empty' <<<"$1"; }
found="$(call "$access" search_contacts '{"search":"bounce@example.com"}')"
jq -e '.contacts[0].email == "bounce@example.com"' <<<"$(result "$found")" >/dev/null \
  && pass "search_contacts finds the contact" || { echo "$found" | head -c 600; fail "search_contacts"; }
contact="$(result "$(call "$access" get_contact "{\"id\":$cid}")")"
jq -e '.do_not_contact[0].reason == "bounced"' <<<"$contact" >/dev/null \
  && pass "get_contact shows Do Not Contact (bounced)" || { echo "$contact" | head -c 600; fail "get_contact"; }
draft="$(call "$access" create_email_draft '{"name":"MCP smoke draft","subject":"Hallo","html":"<html><body><p>Hi</p>{unsubscribe_text}</body></html>","type":"template"}')"
eid="$(result "$draft" | jq -r '.id // empty')"
[[ "$eid" =~ ^[0-9]+$ ]] && [[ "$(result "$draft" | jq -r .published)" == false ]] \
  && pass "create_email_draft creates an unpublished email" || { echo "$draft" | head -c 600; fail "create_email_draft"; }
upd="$(call "$access" update_email_draft "{\"id\":$eid,\"subject\":\"Hallo Welt\"}")"
[[ "$(api "$base/api/emails/$eid" | jq -r .email.subject)" == "Hallo Welt" ]] \
  && pass "update_email_draft changes the draft" || { echo "$upd" | head -c 600; fail "update_email_draft"; }
api -X PATCH "$base/api/emails/$eid/edit" -d isPublished=1 >/dev/null
locked="$(call "$access" update_email_draft "{\"id\":$eid,\"subject\":\"changed\"}")"
grep -q 'Only unpublished drafts' <<<"$(result "$locked")" && [[ "$(api "$base/api/emails/$eid" | jq -r .email.subject)" == "Hallo Welt" ]] \
  && pass "published emails cannot be changed via MCP" || { echo "$locked" | head -c 600; fail "published email changed"; }
denied="$(call "$read_token" create_email_draft '{"name":"x","subject":"x","html":"<p>x</p>"}')"
grep -q '^HTTP/1.1 403' /tmp/mcp-headers && grep -qi '^www-authenticate:.*insufficient_scope' /tmp/mcp-headers \
  && pass "write tools need the mcp:write scope (403 insufficient_scope)" || { cat /tmp/mcp-headers; echo "$denied" | head -c 600; fail "read-only token could write"; }
reads="$(call "$read_token" list_emails '{"search":"MCP smoke"}')"
jq -e '.total >= 1' <<<"$(result "$reads")" >/dev/null && pass "read tools work with the mcp:read scope" || { echo "$reads" | head -c 600; fail "list_emails"; }
sid="$(api -X POST "$base/api/segments/new" -d name='MCP smoke segment' -d isPublished=1 | jq -r '.list.id')"
segs="$(result "$(call "$access" list_segments '{"search":"MCP smoke"}')")"
jq -e --argjson id "$sid" '.segments[0].id == $id' <<<"$segs" >/dev/null && pass "list_segments" || { echo "$segs"; fail "list_segments"; }
camp="$(call "$access" create_campaign_draft "{\"name\":\"MCP smoke campaign\",\"segmentIds\":[$sid]}")"
campid="$(result "$camp" | jq -r '.id // empty')"
[[ "$campid" =~ ^[0-9]+$ ]] && jq -e --argjson id "$sid" '.segments[0].id == $id and .published == false' <<<"$(result "$(call "$access" get_campaign "{\"id\":$campid}")")" >/dev/null \
  && pass "create_campaign_draft + get_campaign (unpublished, segment source)" || { echo "$camp" | head -c 600; fail "campaign draft"; }
types="$(result "$(call "$access" list_campaign_step_types '{}')")"
jq -e '[.actions[].type] | index("email.send")' <<<"$types" >/dev/null && jq -e '[.decisions[].type] | index("email.open")' <<<"$types" >/dev/null \
  && pass "list_campaign_step_types (actions, decisions, conditions)" || { echo "$types" | head -c 600; fail "step types"; }
desc="$(result "$(call "$access" describe_campaign_step_type '{"type":"email.send"}')")"
jq -e '[.properties[].name] | index("email")' <<<"$desc" >/dev/null && pass "describe_campaign_step_type (properties from the step form)" || { echo "$desc" | head -c 800; fail "describe step type"; }
# Welcome email -> opened? yes: +10 points / no (after 3 days): reminder.
flow='[{"key":"welcome","type":"email.send","properties":{"email":'"$eid"',"email_type":"marketing"}},
       {"key":"opened","type":"email.open","parent":"welcome"},
       {"key":"engaged","type":"lead.changepoints","parent":"opened","path":"yes","properties":{"points":10}},
       {"key":"reminder","type":"email.send","parent":"opened","path":"no","wait":{"interval":3,"unit":"d"},"properties":{"email":'"$eid"',"email_type":"marketing"}}]'
set_steps() { call "$access" set_campaign_steps "{\"id\":$campid,\"steps\":$(jq -c . <<<"$1")}"; }
saved="$(set_steps "$flow")"
jq -e '.steps | length == 4' <<<"$(result "$saved")" >/dev/null || { echo "$saved" | head -c 1200; fail "set_campaign_steps"; }
camp_api="$(api "$base/api/campaigns/$campid")"
jq -e '(.campaign.events | length == 4)
  and ([.campaign.events[] | select(.name != null and .type == "email.send" and .decisionPath == "no" and .triggerMode == "interval" and .triggerInterval == 3)] | length == 1)
  and ([.campaign.canvasSettings.nodes[].id | tostring | select(startswith("new"))] | length == 0)
  and (.campaign.canvasSettings.connections | length == 4)
  and (.campaign.isPublished == false)' <<<"$camp_api" >/dev/null \
  && pass "set_campaign_steps: 4 steps with yes/no branches and wait, builder canvas, still unpublished" || { jq -c '.campaign | {events: [.events[] | {name,type,decisionPath,triggerMode,triggerInterval,parent: .parent.id}], canvasSettings}' <<<"$camp_api" | head -c 1500; fail "campaign flow not stored correctly"; }
bad="$(set_steps '[{"key":"a","type":"email.send","properties":{"email":'"$eid"'}},{"key":"b","type":"email.open","parent":"a"},{"key":"c","type":"email.send","parent":"b","path":"no","properties":{"email":'"$eid"'}}]')"
grep -q 'set \\"wait\\"\|set "wait"' <<<"$bad$(result "$bad")" && pass "flow rules enforced (no-path of a decision needs a wait)" || { echo "$bad" | head -c 600; fail "missing wait accepted"; }
bad="$(set_steps '[{"key":"x","type":"email.open"}]')"
grep -q 'cannot be the first step' <<<"$(result "$bad")" && pass "flow rules enforced (email.open must follow email.send)" || { echo "$bad" | head -c 600; fail "email.open as first step accepted"; }
[[ "$(api "$base/api/campaigns/$campid" | jq '.campaign.events | length')" == 4 ]] && pass "rejected flows leave the saved one untouched" || fail "rejected flow changed the campaign"
# The flow really runs: publish it (a human step), add a contact, run Mautic's campaign cron.
api -X POST "$base/api/contacts/new" -d email=flow@example.com -d firstname=Flow >/dev/null
flow_cid="$(api "$base/api/contacts?search=flow@example.com" | jq -r '.contacts | keys[0]')"
api -X POST "$base/api/segments/$sid/contact/$flow_cid/add" >/dev/null
api -X PATCH "$base/api/campaigns/$campid/edit" -d isPublished=1 >/dev/null
docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" "$IMG" console mautic:campaigns:update -i "$campid" >/dev/null 2>&1
trigger="$(docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" "$IMG" console mautic:campaigns:trigger -i "$campid" 2>&1)"
grep -qE '[1-9][0-9]* total events? (were|was) executed' <<<"$trigger" \
  && pass "Mautic executes the flow (campaigns:trigger: $(grep -oE '[0-9]+ total events? (were|was) executed' <<<"$trigger" | head -1))" || { echo "$trigger" | tail -15; fail "campaign flow did not run"; }
# Editing the RUNNING campaign (published, one contact on its way).
live="$(result "$(call "$access" get_campaign "{\"id\":$campid}")")"
blocked="$(call "$access" update_campaign_step "{\"campaignId\":$campid,\"key\":\"$(jq -r '.steps[] | select(.path == "no") | .key' <<<"$live")\",\"wait\":{\"interval\":5,\"unit\":\"d\"}}")"
preview="$(result "$(call "$access" update_campaign_step "{\"campaignId\":$campid,\"key\":\"$(jq -r '.steps[] | select(.path == "no") | .key' <<<"$live")\",\"wait\":{\"interval\":5,\"unit\":\"d\"},\"dryRun\":true}")")"
grep -q 'needs the permission "mcp:campaigns:live"' <<<"$(result "$blocked")" && jq -e '.live_effects.save_allowed == false' <<<"$preview" >/dev/null \
  && pass "running campaign locked without mcp:campaigns:live (dry run shows save_allowed=false)" || { echo "$blocked $preview" | head -c 1500; fail "running campaign not locked"; }
reminder_id="$(jq -r '.steps[] | select(.path == "no") | .key' <<<"$live")"
welcome_id="$(jq -r '.steps[] | select(.parent == null) | .key' <<<"$live")"
jq -e '(.steps | length == 4) and all(.steps[]; .key | test("^[0-9]+$")) and .published == true' <<<"$live" >/dev/null \
  && pass "get_campaign returns the flow in set_campaign_steps format (keys = step IDs; welcome executed for $(jq -r --arg k "$welcome_id" '.steps[] | select(.key == $k) | .contacts.executed' <<<"$live") contact)" || { echo "$live" | head -c 1500; fail "get_campaign steps"; }
same="$(call "$live_token" set_campaign_steps "{\"id\":$campid,\"steps\":$(jq -c '[.steps[] | del(.kind, .contacts)]' <<<"$live")}")"
jq -e '(.changes.added | length) == 0 and (.changes.changed | length) == 0 and (.changes.removed | length) == 0 and (.changes.unchanged | length) == 4' <<<"$(result "$same")" >/dev/null \
  && pass "round trip: get_campaign -> set_campaign_steps changes nothing" || { echo "$same" | head -c 1500; fail "round trip"; }
upd="$(result "$(call "$live_token" update_campaign_step "{\"campaignId\":$campid,\"key\":\"$reminder_id\",\"wait\":{\"interval\":5,\"unit\":\"d\"}}")")"
jq -e --arg k "$reminder_id" '(.changes.changed == [{"key": $k, "name": .changes.changed[0].name, "fields": ["wait"]}]) and ([.steps[] | select(.key == $k) | .wait] == [{"interval": 5, "unit": "d"}]) and .published == true' <<<"$upd" >/dev/null \
  && pass "update_campaign_step on a running campaign: wait 3 -> 5 days, same step ID" || { echo "$upd" | head -c 1500; fail "update_campaign_step"; }
jq -e --arg k "$reminder_id" '.live_effects.contacts_in_campaign >= 1 and .live_effects.outbound_steps == [{"key": $k, "type": "email.send", "name": .live_effects.outbound_steps[0].name, "change": "changed"}] and (.live_effects.warning | test("Confirm with the user"))' <<<"$upd" >/dev/null \
  && pass "running campaign: result warns that the changed email step is live (live_effects)" || { jq -c .live_effects <<<"$upd"; fail "live_effects missing"; }
added="$(result "$(call "$live_token" add_campaign_step "{\"campaignId\":$campid,\"step\":{\"key\":\"bonus\",\"type\":\"lead.changepoints\",\"parent\":\"$reminder_id\",\"properties\":{\"points\":5}}}")")"
bonus_id="$(jq -r '.steps[] | select(.parent == "'"$reminder_id"'") | .key' <<<"$added")"
jq -e '(.changes.added | length == 1) and (.steps | length == 5)' <<<"$added" >/dev/null && [[ "$bonus_id" =~ ^[0-9]+$ ]] \
  && pass "add_campaign_step on a running campaign" || { echo "$added" | head -c 1500; fail "add_campaign_step"; }
moved="$(call "$live_token" set_campaign_steps "{\"id\":$campid,\"steps\":$(jq -c --arg r "$reminder_id" --arg w "$welcome_id" '[.steps[] | del(.kind, .contacts) | if .key == $r then .parent = $w | del(.path) else . end]' <<<"$added")}")"
grep -q 'cannot be moved' <<<"$(result "$moved")" && pass "steps of a running campaign cannot be moved" || { echo "$moved" | head -c 800; fail "move on running campaign accepted"; }
haskids="$(call "$live_token" remove_campaign_step "{\"campaignId\":$campid,\"key\":\"$reminder_id\"}")"
grep -q 'has following steps' <<<"$(result "$haskids")" && pass "steps with following steps are not removed" || { echo "$haskids" | head -c 800; fail "removed step with children"; }
noconfirm="$(call "$live_token" remove_campaign_step "{\"campaignId\":$campid,\"key\":\"$bonus_id\"}")"
dry="$(result "$(call "$live_token" remove_campaign_step "{\"campaignId\":$campid,\"key\":\"$bonus_id\",\"dryRun\":true}")")"
grep -q 'allow_deletions' <<<"$(result "$noconfirm")" && jq -e --arg k "$bonus_id" '.dry_run == true and .changes.removed[0].key == $k and (.changes.removed[0] | has("contacts_scheduled"))' <<<"$dry" >/dev/null \
  && [[ "$(api "$base/api/campaigns/$campid" | jq '.campaign.events | length')" == 5 ]] \
  && pass "removing from a running campaign needs confirmation; dryRun reports affected contacts" || { echo "$noconfirm $dry" | head -c 1500; fail "removal safeguards"; }
gone="$(result "$(call "$live_token" remove_campaign_step "{\"campaignId\":$campid,\"key\":\"$bonus_id\",\"confirm\":true,\"redirectTo\":\"$reminder_id\"}")")"
row="$(docker exec "$run_id-db" mariadb -umautic -pmautic mautic -N -e "SELECT deleted IS NOT NULL, redirect_event_id FROM campaign_events WHERE id = $bonus_id" 2>/dev/null)"
jq -e '(.changes.removed | length == 1) and (.steps | length == 4)' <<<"$gone" >/dev/null && [[ "$(tr -s '[:space:]' ' ' <<<"$row" | sed 's/ $//')" == "1 $reminder_id" ]] \
  && pass "remove_campaign_step with confirm (contacts redirected to the reminder)" || { echo "$gone" | head -c 1500; fail "remove_campaign_step"; }
docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" "$IMG" console mautic:campaigns:trigger -i "$campid" >/dev/null 2>&1 \
  && pass "campaign keeps running after the edits (campaigns:trigger)" || fail "campaigns:trigger after edits"
# Operator switch: a second replica with mautic.mcp.liveCampaignEdits=false
# refuses even a token with mcp:campaigns:live (same MCP session, from the DB).
docker run -d --name "$run_id-web2" --network "$net" "${hardening[@]}" "${env[@]}" \
  -e MAUTIC_MCP_LIVE_CAMPAIGN_EDITS=false -p 127.0.0.1::8080 "$IMG" web >/dev/null
base_main="$base"; base="http://127.0.0.1:$(docker port "$run_id-web2" 8080/tcp | head -1 | sed 's/.*://')"
for _ in $(seq 1 60); do curl -fs "$base/healthz" >/dev/null && break; sleep 1; done
off="$(result "$(call "$live_token" update_campaign_step "{\"campaignId\":$campid,\"key\":\"$reminder_id\",\"wait\":{\"interval\":6,\"unit\":\"d\"}}")")"
base="$base_main"; docker rm -f "$run_id-web2" >/dev/null
grep -q 'disabled on this Mautic instance' <<<"$off" \
  && pass "liveCampaignEdits=false locks running campaigns even with the scope (2nd replica, shared MCP session)" || { echo "$off" | head -c 800; fail "operator switch"; }
stats="$(result "$(call "$access" get_email_stats "{\"id\":$eid}")")"
jq -e '.sent == 1 and (.links | type == "array")' <<<"$stats" >/dev/null && pass "get_email_stats (the campaign sent the welcome email)" || { echo "$stats"; fail "get_email_stats"; }
# A user whose role may only work on their own emails sees no contacts.
rid="$(api -X POST "$base/api/roles/new" -d name='AI Editor (smoke)' -d isAdmin=0 \
  -d 'rawPermissions[email:emails][]=viewown' -d 'rawPermissions[email:emails][]=create' -d 'rawPermissions[email:emails][]=editown' | jq -r '.role.id')"
api -X POST "$base/api/users/new" -d username=ai-editor -d firstName=AI -d lastName=Editor -d email=ai-editor@example.com \
  -d "role=$rid" -d 'plainPassword[password]=Ai-Ed1tor-Passw0rd!' -d 'plainPassword[confirm]=Ai-Ed1tor-Passw0rd!' >/dev/null
jar="$(mktemp)"; login_as_admin "$jar" ai-editor 'Ai-Ed1tor-Passw0rd!' >/dev/null
authz S256 "$jar" >/dev/null; location="$(decide approve)"; code="$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")"
[[ "$(code_grant "$verifier")" == 200 ]] || fail "token for restricted user"
editor_token="$(jq -r .access_token /tmp/oauth-resp)"
nope="$(call "$editor_token" search_contacts '{"search":"bounce"}')"
own="$(call "$editor_token" create_email_draft '{"name":"Editor draft","subject":"x","html":"<p>x</p>"}')"
grep -q 'role does not allow' <<<"$(result "$nope")" && [[ "$(result "$own" | jq -r '.published')" == false ]] \
  && pass "tools respect the Mautic role of the user (no contacts, own email drafts)" || { echo "$nope $own" | head -c 800; fail "Mautic permissions not applied"; }

# shellcheck source=test/mcp-scenarios.sh
source "$(dirname "$0")/mcp-scenarios.sh"
# shellcheck source=test/mcp-contacts.sh
source "$(dirname "$0")/mcp-contacts.sh"
# shellcheck source=test/mcp-crm.sh
source "$(dirname "$0")/mcp-crm.sh"
# shellcheck source=test/roles.sh
source "$(dirname "$0")/roles.sh"

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
printf "campaign=%s base=%s\ntoken=%s\nrun=%s\n%s\n" "$campid" "$base" "$access" "$run_id" "${SCENARIO_INFO:-}" > "${SMOKE_INFO:-/dev/null}"
