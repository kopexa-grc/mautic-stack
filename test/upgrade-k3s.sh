#!/usr/bin/env bash
# Upgrade test on k3s: install the last published chart with its published
# image, then upgrade to this commit (chart + locally built image).
#
#   test/upgrade-k3s.sh <image-tarball> <image-ref-inside-tarball>
set -euo pipefail
TARBALL="${1:?image tarball}"
IMAGE_REF="${2:?image ref, e.g. mautic:e2e}"
CHART="${CHART:-charts/mautic}"
OCI="${OCI:-oci://ghcr.io/kopexa-grc/charts/mautic}"
NS=mautic-upgrade

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }

sudo k3s ctr images import "$TARBALL" >/dev/null
repo="docker.io/library/${IMAGE_REF%%:*}"; tag="${IMAGE_REF##*:}"

prev="$(helm show chart "$OCI" | sed -n 's/^version: //p')"
echo "upgrading from published chart $prev"
kubectl create namespace "$NS"
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=restricted
helm install mautic "$OCI" --version "$prev" -n "$NS" -f "$CHART/ci/default-values.yaml" --wait --timeout 15m
helm test mautic -n "$NS" >/dev/null && pass "chart $prev installed and healthy" || fail "previous release"
before="$(kubectl -n "$NS" get secret mautic -o jsonpath='{.data.admin-password}')"

helm upgrade mautic "$CHART" -n "$NS" -f "$CHART/ci/default-values.yaml" \
  --set image.repository="$repo" --set image.tag="$tag" --set image.pullPolicy=Never \
  --set mautic.oauth.enabled=true \
  --wait --timeout 15m
helm test mautic -n "$NS" >/dev/null && pass "upgraded to this commit" || fail "after upgrade"
after="$(kubectl -n "$NS" get secret mautic -o jsonpath='{.data.admin-password}')"
[[ "$before" == "$after" ]] && pass "generated secrets kept across upgrade" || fail "secrets changed"
init_log="$(kubectl -n "$NS" logs deploy/mautic -c init)"
grep -q 'database is empty' <<<"$init_log" && fail "upgrade re-installed Mautic" || pass "upgrade kept the database (migrations only)"
grep -q 'syncing roles' <<<"$init_log" && fail "roles synced without mautic.roles" || pass "without mautic.roles the init leaves roles alone"

oauth_key="$(kubectl -n "$NS" get secret mautic -o jsonpath='{.data.oauth-private-key}')"
helm upgrade mautic "$CHART" -n "$NS" --reuse-values --wait --timeout 15m >/dev/null
[[ -n "$oauth_key" && "$oauth_key" == "$(kubectl -n "$NS" get secret mautic -o jsonpath='{.data.oauth-private-key}')" ]] \
  && pass "OAuth signing key generated once and kept on upgrade" || fail "OAuth signing key changed"
