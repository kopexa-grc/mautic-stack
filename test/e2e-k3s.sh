#!/usr/bin/env bash
# Full end-to-end test on k3s (real ingress controller: Traefik with TLS).
#
#   1. Mautic behind HTTPS ingress generates https:// URLs (trusted proxies)
#   2. An email sent through the API travels queue → worker → SMTP and
#      arrives in Mailpit with https:// tracking links
#   3. A restic backup restores into a second, fresh release
#
#   test/e2e-k3s.sh <image-tarball> <image-ref-inside-tarball>
#
# Expects: k3s installed (KUBECONFIG set), helm, curl, jq.
set -euo pipefail
TARBALL="${1:?image tarball}"
IMAGE_REF="${2:?image ref, e.g. mautic:e2e}"
CHART="${CHART:-charts/mautic}"
HOST=mautic.e2e.test
RESTORED_HOST=restored.e2e.test
NS=mautic
MAILPIT_IMAGE="${MAILPIT_IMAGE:-axllent/mailpit:v1.33.0}"
REST_SERVER_IMAGE="${REST_SERVER_IMAGE:-restic/rest-server:0.14.0}"
RESTIC_IMAGE="${RESTIC_IMAGE:-ghcr.io/kopexa-grc/restic:0.19}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
https() { curl -sk --resolve "$HOST:443:127.0.0.1" "$@"; }

step "Import image into k3s containerd"
sudo k3s ctr images import "$TARBALL" >/dev/null
repo="docker.io/library/${IMAGE_REF%%:*}"; tag="${IMAGE_REF##*:}"
pass "imported $repo:$tag"

step "Wait for Traefik"
for _ in $(seq 1 60); do kubectl -n kube-system get deploy traefik >/dev/null 2>&1 && break; sleep 5; done
kubectl -n kube-system rollout status deploy/traefik --timeout=5m

step "Mailpit and restic rest-server"
kubectl create namespace mail
kubectl -n mail create deployment mailpit --image="$MAILPIT_IMAGE"
kubectl -n mail apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: mailpit
spec:
  selector: {app: mailpit}
  ports:
    - {name: smtp, port: 1025}
    - {name: http, port: 8025}
EOF
kubectl create namespace backup-target
kubectl -n backup-target create deployment rest-server --image="$REST_SERVER_IMAGE"
kubectl -n backup-target set env deployment/rest-server DISABLE_AUTHENTICATION=1
kubectl -n backup-target expose deployment rest-server --port 8000
kubectl -n mail rollout status deploy/mailpit --timeout=3m
kubectl -n backup-target rollout status deploy/rest-server --timeout=3m

common=(
  --set image.repository="$repo" --set image.tag="$tag" --set image.pullPolicy=Never
  --set-json 'mautic.configParameters={"api_enabled":true,"api_enable_basic_auth":true}'
  --set backup.repository=rest:http://rest-server.backup-target:8000/mautic
  --set backup.existingSecret=mautic-backup
)

step "Install Mautic behind HTTPS ingress"
kubectl create namespace "$NS"
kubectl -n "$NS" create secret generic mautic-backup --from-literal=RESTIC_PASSWORD=e2e-backup
helm install mautic "$CHART" -n "$NS" "${common[@]}" \
  --set mautic.siteUrl="https://$HOST" \
  --set mautic.mailer.dsn=smtp://mailpit.mail:1025 \
  --set mautic.mailer.fromEmail=mautic@e2e.test --set mautic.mailer.fromName=E2E \
  --set ingress.enabled=true --set ingress.className=traefik \
  --set "ingress.hosts[0].host=$HOST" \
  --set "ingress.hosts[0].paths[0].path=/" --set "ingress.hosts[0].paths[0].pathType=Prefix" \
  --set "ingress.tls[0].hosts[0]=$HOST" \
  --set backup.enabled=true \
  --wait --timeout 15m
pass "installed"

ADMIN_PW="$(kubectl -n "$NS" get secret mautic -o jsonpath='{.data.admin-password}' | base64 -d)"
api() { https -u "admin:$ADMIN_PW" -H 'Accept: application/json' "$@"; }

step "HTTPS through the ingress"
for _ in $(seq 1 30); do [[ "$(https -o /dev/null -w '%{http_code}' "https://$HOST/s/login")" == 200 ]] && break; sleep 5; done
login_page="$(https "https://$HOST/s/login")"
grep -q 'name="_username"' <<<"$login_page" && pass "login page via ingress" || fail "login page via ingress"
loc="$(https -o /dev/null -w '%{redirect_url}' "https://$HOST/s/dashboard")"
echo "  redirect: $loc"
[[ "$loc" == "https://$HOST/"* ]] && pass "redirects stay on https (X-Forwarded-Proto trusted)" \
  || fail "redirect is not https://$HOST/… — trusted proxies not applied"

step "Send an email: API → queue → worker → SMTP → Mailpit"
cid="$(api -X POST "https://$HOST/api/contacts/new" -d email=e2e@example.com -d firstname=E2E | jq -r '.contact.id')"
[[ "$cid" =~ ^[0-9]+$ ]] && pass "contact $cid created" || fail "contact creation (API basic auth?)"
subject="E2E $(date +%s)"
eid="$(api -X POST "https://$HOST/api/emails/new" \
  --data-urlencode "name=E2E" --data-urlencode "subject=$subject" \
  --data-urlencode 'customHtml=<html><body><p>Hello {contactfield=firstname}</p><a href="https://kopexa.com">Kopexa</a></body></html>' \
  -d emailType=template -d isPublished=1 | jq -r '.email.id')"
[[ "$eid" =~ ^[0-9]+$ ]] && pass "email $eid created" || fail "email creation"
api -X POST "https://$HOST/api/emails/$eid/contact/$cid/send" | tee /tmp/send.json | jq -e '.success == true' >/dev/null \
  && pass "send accepted" || { cat /tmp/send.json; fail "send"; }

kubectl -n mail port-forward svc/mailpit 18025:8025 >/dev/null 2>&1 &
pf=$!; trap 'kill $pf 2>/dev/null || true' EXIT
mid=""
for _ in $(seq 1 60); do
  mid="$(curl -s localhost:18025/api/v1/messages 2>/dev/null | jq -r --arg s "$subject" '.messages[]? | select(.Subject == $s) | .ID' | head -1)"
  [[ -n "$mid" ]] && break; sleep 5
done
[[ -n "$mid" ]] && pass "email arrived in Mailpit" || {
  kubectl -n "$NS" logs deploy/mautic-worker --tail=50; fail "email not delivered within 5 minutes"; }
msg="$(curl -s "localhost:18025/api/v1/message/$mid")"
jq -e '.To[0].Address == "e2e@example.com"' <<<"$msg" >/dev/null && pass "recipient correct" || fail "recipient"
html="$(jq -r '.HTML' <<<"$msg")"
grep -q 'Hello E2E' <<<"$html" && pass "personalisation token rendered" || fail "token not rendered"
grep -q "https://$HOST/" <<<"$html" && pass "tracking links use https://$HOST" || { echo "$html" | head -20; fail "tracking links"; }

step "Backup"
kubectl -n "$NS" create job backup-e2e --from=cronjob/mautic-backup
kubectl -n "$NS" wait --for=condition=complete job/backup-e2e --timeout=10m
pass "backup completed"

step "Restore into a fresh release"
kubectl create namespace restore
kubectl -n restore create secret generic mautic-backup --from-literal=RESTIC_PASSWORD=e2e-backup
helm install restored "$CHART" -n restore "${common[@]}" \
  --set mautic.siteUrl="https://$RESTORED_HOST" \
  --set web.replicaCount=0 --set worker.enabled=false --set cron.enabled=false \
  --wait --timeout 10m
kubectl -n restore rollout status statefulset/restored-mautic-mariadb --timeout=5m
kubectl -n restore apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: restore
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      initContainers:
        - name: restic
          image: $RESTIC_IMAGE
          args: [restore, latest, --target, /restore, --include, /backup/database.sql]
          env:
            - {name: RESTIC_REPOSITORY, value: "rest:http://rest-server.backup-target:8000/mautic"}
            - {name: RESTIC_PASSWORD, value: e2e-backup}
            - {name: RESTIC_CACHE_DIR, value: /tmp/cache}
          volumeMounts: [{name: restore, mountPath: /restore}, {name: tmp, mountPath: /tmp}]
      containers:
        - name: import
          image: docker.io/library/mariadb:11.4
          command: [/bin/sh, -ec]
          args: ['mariadb -h restored-mautic-mariadb -u mautic mautic < /restore/backup/database.sql']
          env:
            - name: MYSQL_PWD
              valueFrom: {secretKeyRef: {name: restored-mautic-mariadb, key: mariadb-password}}
          volumeMounts: [{name: restore, mountPath: /restore}]
      volumes:
        - {name: restore, emptyDir: {}}
        - {name: tmp, emptyDir: {}}
EOF
kubectl -n restore wait --for=condition=complete job/restore --timeout=10m || {
  kubectl -n restore logs job/restore --all-containers; fail "restore job"; }
pass "database restored"

helm upgrade restored "$CHART" -n restore --reuse-values --set web.replicaCount=1 --wait --timeout 10m
init_log="$(kubectl -n restore logs deploy/restored-mautic -c init)"
grep -q 'database is empty' <<<"$init_log" \
  && fail "init re-installed instead of using the restored database" || pass "init used the restored database"
kubectl -n restore port-forward svc/restored-mautic 18080:80 >/dev/null 2>&1 &
pf2=$!; trap 'kill $pf $pf2 2>/dev/null || true' EXIT
sleep 3
found="$(curl -s -u "admin:$ADMIN_PW" -H "Host: $RESTORED_HOST" -H 'X-Forwarded-Proto: https' \
  "http://127.0.0.1:18080/api/contacts?search=e2e@example.com" | jq -r '.total // empty')"
[[ "$found" == 1 ]] && pass "contact and admin login survived backup + restore" || fail "restored data (total=$found)"

printf '\n\033[32mAll k3s end-to-end checks passed.\033[0m\n'
