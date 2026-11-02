#!/usr/bin/env bash
# Deliverability checks for the rendered email (dist/<theme>/email.html + .txt):
# send it as a real multipart message to Mailpit with rspamd attached, then
# use Mailpit's checks:
#   - HTML compatibility across email clients (caniemail data)
#   - link check (all external links reachable)
#   - rspamd spam score
#
#   qa/deliverability.sh [theme-dir]   (needs docker, python3, curl, jq; default: the base theme)
set -euo pipefail
cd "$(dirname "$0")"
theme_dir="${1:-..}"
dist="dist/$(jq -r '.extra["install-directory-name"]' "$theme_dir/composer.json")"
MAILPIT_IMAGE="${MAILPIT_IMAGE:-axllent/mailpit:v1.33.0}"
RSPAMD_IMAGE="${RSPAMD_IMAGE:-rspamd/rspamd:latest}"
MIN_CLIENT_SUPPORT="${MIN_CLIENT_SUPPORT:-80}"   # % of HTML/CSS features supported
MAX_SPAM_SCORE="${MAX_SPAM_SCORE:-4}"            # rspamd "add header" default is 6
net="theme-qa-$$"

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=1; }
failed=0
cleanup() { docker rm -f "$net-rspamd" "$net-mailpit" >/dev/null 2>&1 || true; docker network rm "$net" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker network create "$net" >/dev/null
docker run -d --name "$net-rspamd" --network "$net" "$RSPAMD_IMAGE" >/dev/null
docker run -d --name "$net-mailpit" --network "$net" -p 127.0.0.1::1025 -p 127.0.0.1::8025 \
  "$MAILPIT_IMAGE" --enable-rspamd "$net-rspamd:11333" >/dev/null
smtp="$(docker port "$net-mailpit" 1025/tcp | head -1 | sed 's/.*://')"
api="http://127.0.0.1:$(docker port "$net-mailpit" 8025/tcp | head -1 | sed 's/.*://')/api/v1"
for _ in $(seq 1 60); do curl -fs "$api/info" >/dev/null 2>&1 && break; sleep 1; done

# A message as Mautic + Postal would send it (headers incl. RFC 8058 one-click unsubscribe).
python3 - "$smtp" "$dist" <<'PY'
import smtplib, sys
from email.message import EmailMessage
from email.utils import make_msgid, formatdate
msg = EmailMessage()
msg["From"] = "Kopexa <newsletter@kopexa.com>"
msg["To"] = "Alex <alex@example.org>"
msg["Subject"] = open(sys.argv[2] + "/subject.txt", encoding="utf-8").read().strip()
msg["Date"] = formatdate(localtime=True)
msg["Message-ID"] = make_msgid(domain="kopexa.com")
msg["List-Unsubscribe"] = "<https://mautic.example.com/email/unsubscribe/0123456789abcdef>"
msg["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
msg.set_content(open(sys.argv[2] + "/email.txt", encoding="utf-8").read())
msg.add_alternative(open(sys.argv[2] + "/email.html", encoding="utf-8").read(), subtype="html")
with smtplib.SMTP("127.0.0.1", int(sys.argv[1])) as s:
    s.send_message(msg)
PY

id=""
for _ in $(seq 1 30); do id="$(curl -s "$api/messages" | jq -r '.messages[0].ID // empty')"; [[ -n "$id" ]] && break; sleep 1; done
[[ -n "$id" ]] || { echo "message not received"; exit 1; }

# 1. Client compatibility (caniemail.com data, weighted by usage in the HTML).
hc="$(curl -s "$api/message/$id/html-check")"
supported="$(jq -r '(.Total.Supported + .Total.Partial) * 10 | round / 10' <<<"$hc")"
if awk "BEGIN{exit !($supported >= $MIN_CLIENT_SUPPORT)}"; then
  pass "client compatibility ${supported}% (supported + partial, min ${MIN_CLIENT_SUPPORT}%)"
else
  fail "client compatibility ${supported}% < ${MIN_CLIENT_SUPPORT}%"
fi
jq -r '.Warnings[]? | select(.Score.Unsupported > 30) | "       unsupported in \(.Score.Unsupported | floor)% of clients: \(.Title)"' <<<"$hc" | head -8

# 2. Links: everything except the placeholder Mautic host must resolve.
lc="$(curl -s "$api/message/$id/link-check?follow=true")"
broken="$(jq -r '.Links[] | select((.URL | test("mautic\\.example\\.com")) | not) | select(.StatusCode >= 400 or .StatusCode == 0) | "\(.StatusCode) \(.URL)"' <<<"$lc")"
checked="$(jq '[.Links[] | select((.URL | test("mautic\\.example\\.com")) | not)] | length' <<<"$lc")"
[[ -z "$broken" ]] && pass "$checked external links reachable" || fail "broken links: $broken"

# 3. Spam score.
rs="$(curl -s "$api/message/$id/rspamd-check")"
score="$(jq -r '.Score' <<<"$rs")"; action="$(jq -r '.Action' <<<"$rs")"
[[ "$(jq -r '.Error // empty' <<<"$rs")" == "" ]] || fail "rspamd error: $(jq -r .Error <<<"$rs")"
if awk "BEGIN{exit !($score < $MAX_SPAM_SCORE)}"; then pass "rspamd score $score (< $MAX_SPAM_SCORE), action: $action"; else fail "rspamd score $score >= $MAX_SPAM_SCORE (action: $action)"; fi
jq -r '.Rules | sort_by(-.Score) | .[] | select(.Score != 0) | "       \(.Score)\t\(.Name)\t\(.Description)"' <<<"$rs" | head -10

mkdir -p "$dist"
printf '%s\n' "$hc" > "$dist/html-check.json"; printf '%s\n' "$lc" > "$dist/link-check.json"; printf '%s\n' "$rs" > "$dist/rspamd.json"
exit "$failed"
