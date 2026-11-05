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
# Email preference center (Helm: mautic.preferenceCenter).
env+=(-e 'MAUTIC_PREFERENCE_CENTER={"topics":[{"name":"Webinare & Events","description":"Einladungen zu Online-Terminen"},{"name":"Ressourcen & Downloads"},{"name":"Produkt-Updates"}],"page":{"alias":"einstellungen"}}')
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
init2="$(docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" "$IMG" init 2>&1)" \
  || { echo "$init2" | tail -20; fail "second init failed"; }
pass "second init completed"
grep -q 'page "einstellungen": unchanged' <<<"$init2" && grep -q 'settings: unchanged' <<<"$init2" \
  && pass "preference center: second init changes nothing (topics, page, settings)" || { echo "$init2" | grep -iE 'topic|page|settings|prefer'; fail "preference center sync not idempotent"; }

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
for v in kopexa-confirm kopexa-hero kopexa-page kopexa-preferences; do
  [[ "$(code "/themes/$v/thumbnail.png")" == 200 ]] && pass "theme variant $v installed" || fail "theme variant $v missing"
done
[[ "$(code /themes/kopexa/assets/placeholder/card-1.png)" == 200 ]] && pass "placeholder images served" || fail "placeholder images missing"
[[ "$(code /themes/kopexa/assets/fonts/kopexa-fonts.css)" == 200 ]] && ! curl -s "$base/s/login" | grep -q 'fonts.googleapis.com' \
  && pass "no Google Fonts: Mautic's editor fonts are the self-hosted brand fonts" || fail "Google Fonts linked (editor_fonts)"

echo "Postal bounce webhook (signing key from MAUTIC_POSTAL_WEBHOOK_PUBLIC_KEY)"
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
[[ "$(postal "$bounce" "$postal_key")" == 200 ]] && jq -e '.handled == true' /tmp/postal-resp >/dev/null \
  && pass "signed MessageBounced accepted" || { cat /tmp/postal-resp; fail "signed bounce"; }
dnc="$(api "$base/api/contacts/$cid" | jq -r '.contact.doNotContact[0].reason // empty')"
[[ "$dnc" == 2 ]] && pass "contact marked Do Not Contact: bounced" || fail "contact not marked bounced (reason=$dnc)"
echo "Email preference center (mautic.preferenceCenter, theme kopexa-preferences)"
webinar_cat="$(api "$base/api/categories?search=Webinare" | jq -r '[.categories[] | select(.title == "Webinare & Events")][0].id')"
pref_cid="$(api -X POST "$base/api/contacts/new" -d email=prefs@example.com | jq -r .contact.id)"
pref_eid="$(api -X POST "$base/api/emails/new" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Webinar\",\"subject\":\"Webinar\",\"emailType\":\"template\",\"isPublished\":true,\"category\":$webinar_cat,\"template\":\"kopexa\",\"customHtml\":\"<html><body><a href='{unsubscribe_url}'>Abmelden</a></body></html>\"}" | jq -r .email.id)"
api -X POST "$base/api/emails/$pref_eid/contact/$pref_cid/send" >/dev/null
pref_hash="$(docker exec "$run_id-db" mariadb -umautic -pmautic mautic -N -e "SELECT tracking_hash FROM email_stats WHERE lead_id = $pref_cid ORDER BY id DESC LIMIT 1" 2>/dev/null)"
pref_jar="$(mktemp)"
curl -s -c "$pref_jar" -b "$pref_jar" "$base/email/unsubscribe/$pref_hash" -o /tmp/prefs.html
grep -q 'Du entscheidest, was in deinem Postfach landet' /tmp/prefs.html && grep -q 'name="lead_contact_frequency_rules"' /tmp/prefs.html \
  && [[ "$(grep -c '<html' /tmp/prefs.html)" == 1 ]] && ! grep -q 'fonts.googleapis.com' /tmp/prefs.html \
  && pass "unsubscribe link opens the Kopexa preference page (Mautic's form inside, one document, no Google Fonts)" || { head -c 600 /tmp/prefs.html; fail "preference page"; }
pref_token="$(perl -0ne 'print $1 if /<input\b[^>]*name="lead_contact_frequency_rules\[_token\]"[^>]*>/ and $& =~ /\bvalue="([^"]*)"/' /tmp/prefs.html)"  # the tag spans lines
other_cats="$(api "$base/api/categories?limit=100" | jq -r --argjson w "$webinar_cat" '[.categories[] | select(.bundle == "global" and .id != $w) | .id] | .[]')"
fields=(--data-urlencode "lead_contact_frequency_rules[_token]=$pref_token" --data-urlencode "lead_contact_frequency_rules[lead_channels][subscribed_channels][0]=email")
for c in $other_cats; do fields+=(--data-urlencode "lead_contact_frequency_rules[global_categories][]=$c"); done
[[ "$(curl -s -o /dev/null -w '%{http_code}' -b "$pref_jar" -c "$pref_jar" -X POST "$base/email/unsubscribe/$pref_hash" "${fields[@]}")" == 302 ]] \
  && [[ "$(docker exec "$run_id-db" mariadb -umautic -pmautic mautic -N -e "SELECT manually_removed FROM lead_categories WHERE lead_id = $pref_cid AND category_id = $webinar_cat" 2>/dev/null)" == 1 ]] \
  && pass "switching a topic off is saved: contact unsubscribed from \"Webinare & Events\" only" || fail "saving preferences"

echo "OAuth 2.1 (keys and issuer from the environment; the bundle tests the protocol)"
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
[[ "$(authz S256 "$jar")" == "200 " ]] && grep -q 'Smoke MCP client' /tmp/oauth-page \
  && pass "consent page shown to the logged-in user" || fail "consent page"
# What a browser submits for the consent page's <form>: its inputs only
# (fields outside the form are not sent), checkboxes only if ticked and not
# disabled; $TICK ticks further checkboxes, only if they exist in the form.
form_fields() {
  # shellcheck disable=SC2086  # $TICK: space-separated scopes
  docker run --rm -i --entrypoint /usr/bin/php "$IMG" -r '
    $d = new DOMDocument(); @$d->loadHTML((string) stream_get_contents(STDIN));
    $x = new DOMXPath($d); $tick = array_slice($argv, 1);
    foreach ($x->query("//form[@method=\"post\"]//input") as $i) {
      $n = $i->getAttribute("name"); $t = strtolower($i->getAttribute("type"));
      if ("" === $n || $i->hasAttribute("disabled")) { continue; }
      if (in_array($t, ["checkbox", "radio"], true) && !$i->hasAttribute("checked") && !in_array($i->getAttribute("value"), $tick, true)) { continue; }
      echo $n, "=", $i->getAttribute("value"), "\n";
    }' -- ${TICK:-} </tmp/oauth-page
}
decide() { # $1 = approve|deny ; posts the last consent page's form like a browser (+ $TICK)
  local fields=() f
  while IFS= read -r f; do [[ -n "$f" ]] && fields+=(--data-urlencode "$f"); done < <(form_fields)
  curl -s -o /dev/null -w '%{redirect_url}' -b "$jar" -c "$jar" -X POST "$base/s/oauth2/authorize" \
    --data-urlencode "decision=$1" "${fields[@]}"
}
location="$(decide approve)"
[[ "$location" == "$redirect?"*"state=smoke-state"* ]] || fail "approve redirect: $location"
code="$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")"
[[ -n "$code" ]] && pass "approval redirects with an authorization code" || fail "no code in $location"

token() { curl -s -o /tmp/oauth-resp -w '%{http_code}' -X POST "$base/oauth2/token" "$@"; }
code_grant() { token --data-urlencode grant_type=authorization_code --data-urlencode "code=$code" \
  --data-urlencode "client_id=$client_id" --data-urlencode "redirect_uri=$redirect" --data-urlencode "code_verifier=$1"; }
[[ "$(code_grant "$verifier")" == 200 ]] || { cat /tmp/oauth-resp; fail "code exchange"; }
access="$(jq -r .access_token /tmp/oauth-resp)"; refresh="$(jq -r .refresh_token /tmp/oauth-resp)"
pass "code exchanged for access + refresh token"

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

SCOPE='mcp:read mcp:write mcp:campaigns:live' authz S256 "$jar" >/dev/null
location="$(TICK=mcp:campaigns:live decide approve)"; code="$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")"
[[ "$(code_grant "$verifier")" == 200 ]] || fail "token with live scope"
live_token="$(jq -r .access_token /tmp/oauth-resp)"
[[ "$(b64url_decode "$(cut -d. -f2 <<<"$live_token")" | jq -r .scope)" == "mcp:read mcp:write mcp:campaigns:live" ]] \
  && pass "ticking it grants mcp:campaigns:live" || fail "live scope not granted"

echo "MCP server (public URL, sessions across replicas, operator switch; the bundle tests the tools)"
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
[[ "$(jq '.result.tools | length' <<<"$tools")" == 61 ]] && jq -e '[.result.tools[].name] | index("create_email_draft") and index("search_contacts") and index("upsert_contacts") and index("adjust_contact_points") and index("set_contact_stage") and index("add_to_project") and index("list_email_topics")' <<<"$tools" >/dev/null \
  && pass "tools/list: 61 tools on one page" || { echo "$tools" | head -c 600; fail "tools/list"; }
call() { mcp "$1" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"'"$2"'","arguments":'"$3"'}}'; }
result() { jq -r '.result.content[0].text // empty' <<<"$1"; }
found="$(call "$access" search_contacts '{"search":"bounce@example.com"}')"
jq -e '.contacts[0].email == "bounce@example.com"' <<<"$(result "$found")" >/dev/null \
  && pass "search_contacts finds the contact" || { echo "$found" | head -c 600; fail "search_contacts"; }
contact="$(result "$(call "$access" get_contact "{\"id\":$cid}")")"
jq -e '.do_not_contact[0].reason == "bounced"' <<<"$contact" >/dev/null \
  && pass "get_contact shows Do Not Contact (bounced)" || { echo "$contact" | head -c 600; fail "get_contact"; }
draft="$(result "$(call "$access" create_email_draft '{"name":"MCP smoke draft","subject":"Hallo","html":"<html><body><p>Hi</p></body></html>"}')")"
jq -e '.published == false and (.id | type == "number")' <<<"$draft" >/dev/null \
  && pass "create_email_draft creates an unpublished email" || { echo "$draft" | head -c 600; fail "create_email_draft"; }
# Operator switch: MAUTIC_MCP_LIVE_CAMPAIGN_EDITS=false on a second replica
# refuses changes to live items even with mcp:campaigns:live (same MCP
# session, from the database). A published point trigger is such an item.
trig="$(result "$(call "$access" create_point_trigger '{"name":"Smoke live switch","points":10,"events":[{"type":"lead.changetags","name":"tag","properties":{"add_tags":["smoke"]}}]}')")"
tid="$(jq -r .id <<<"$trig")"
[[ "$(api -X PATCH "$base/api/points/triggers/$tid/edit" -d isPublished=1 | jq -r .trigger.isPublished)" == true ]] || fail "publish trigger via API"
docker run -d --name "$run_id-web2" --network "$net" "${hardening[@]}" "${env[@]}" \
  -e MAUTIC_MCP_LIVE_CAMPAIGN_EDITS=false -p 127.0.0.1::8080 "$IMG" web >/dev/null
base2="http://127.0.0.1:$(docker port "$run_id-web2" 8080/tcp | head -1 | sed 's/.*://')"
for _ in $(seq 1 60); do curl -fs "$base2/healthz" >/dev/null && break; sleep 1; done
base_main="$base"; base="$base2"
off="$(result "$(call "$live_token" update_point_trigger "{\"id\":$tid,\"points\":20}")")"
base="$base_main"; docker rm -f "$run_id-web2" >/dev/null
on="$(result "$(call "$live_token" update_point_trigger "{\"id\":$tid,\"points\":20}")")"
grep -q 'disabled on this Mautic instance' <<<"$off" && jq -e '.points == 20' <<<"$on" >/dev/null \
  && pass "MAUTIC_MCP_LIVE_CAMPAIGN_EDITS=false locks live items (2nd replica, shared MCP session); default allows them with the scope" || { echo "$off $on" | head -c 800; fail "operator switch"; }

# shellcheck source=test/mcp-layouts.sh
source "$(dirname "$0")/mcp-layouts.sh"
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
printf "base=%s\ntoken=%s\nrun=%s\n" "$base" "$access" "$run_id" > "${SMOKE_INFO:-/dev/null}"
