# shellcheck shell=bash disable=SC2154,SC2034  # shares variables with test/smoke.sh
# Roles from the Helm values (mautic.roles -> MAUTIC_ROLES, kopexa:roles:sync)
# and the SAML default role by name. Sourced by test/smoke.sh (uses api,
# pass, fail, base, run_id, net, hardening, env, IMG).

echo "roles from values (kopexa:roles:sync) + SAML default role by name"
sync() { docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" "$@" "$IMG" console kopexa:roles:sync 2>&1; }
dbq() { docker exec "$run_id-db" mariadb -umautic -pmautic mautic -N -e "$1" 2>/dev/null; }
marketing='[{"name":"Marketing","description":"Kampagnen, E-Mails, Kontakte","permissions":{"lead:leads":["full"],"email:emails":["full"],"campaign:campaigns":["full"]}}]'

out="$(sync -e "MAUTIC_ROLES=$marketing")"
rid="$(dbq "SELECT id FROM roles WHERE name = 'Marketing'")"
perms="$(dbq "SELECT COUNT(*) FROM permissions WHERE role_id = ${rid:-0} AND bitwise = 1024")"
grep -q 'role "Marketing": created' <<<"$out" && [[ "$rid" =~ ^[0-9]+$ ]] && [[ "$perms" == 3 ]] \
  && jq -e '.role.rawPermissions["lead:leads"] == ["full"] and .role.isAdmin == false' <<<"$(api "$base/api/roles/$rid")" >/dev/null \
  && pass "role created through Mautic's RoleModel (3 permission bitmasks, readable permissions)" || { echo "$out"; dbq "SELECT * FROM permissions WHERE role_id = ${rid:-0}"; fail "role not created"; }
grep -q 'role "Marketing": unchanged' <<<"$(sync -e "MAUTIC_ROLES=$marketing")" && pass "second run: unchanged" || fail "second run changed the role"

more="$(jq -c '.[0].permissions["form:forms"] = ["viewown", "editown"]' <<<"$marketing")"
out="$(sync -e "MAUTIC_ROLES=$more")"
grep -q 'role "Marketing": updated.*permissions' <<<"$out" && [[ "$(dbq "SELECT id FROM roles WHERE name = 'Marketing'")" == "$rid" ]] \
  && [[ "$(dbq "SELECT COUNT(*) FROM permissions WHERE role_id = $rid AND CONCAT(bundle, ':', name) IN ('lead:leads', 'email:emails', 'campaign:campaigns', 'form:forms')")" == 4 ]] \
  && [[ "$(dbq "SELECT bitwise FROM permissions WHERE role_id = $rid AND bundle = 'form' AND name = 'forms'")" == 10 ]] \
  && jq -e '.role.rawPermissions["form:forms"] == ["editown", "viewown"]' <<<"$(api "$base/api/roles/$rid")" >/dev/null \
  && pass "changed permissions: updated in place (same role ID; Mautic computes the bitmasks, viewown+editown = 10)" || { echo "$out"; fail "permission update"; }

# A role created in the UI (or API) with the same name is adopted.
uid="$(api -X POST "$base/api/roles/new" -d name=Vertrieb -d isAdmin=0 -d 'rawPermissions[lead:leads][]=viewown' | jq -r '.role.id')"
out="$(sync -e 'MAUTIC_ROLES=[{"name":"Vertrieb","permissions":{"lead:leads":["full"]}}]')"
grep -q 'role "Vertrieb": updated' <<<"$out" && [[ "$(dbq "SELECT id FROM roles WHERE name = 'Vertrieb'")" == "$uid" ]] \
  && jq -e '.role.rawPermissions == {"lead:leads": ["full"]}' <<<"$(api "$base/api/roles/$uid")" >/dev/null \
  && pass "existing role with the same name adopted: same ID, permissions from the values" || { echo "$out"; fail "adopt existing role"; }

rc=0; bad="$(sync -e 'MAUTIC_ROLES=[{"name":"X","permissions":{"lead:leads":["fly"],"nope:things":["full"]},"colour":"red"}]')" || rc=$?
[[ "$rc" != 0 ]] && [[ "$(dbq "SELECT COUNT(*) FROM roles WHERE name = 'X'")" == 0 ]] && grep -q 'unknown permission "lead:leads:fly"' <<<"$bad" \
  && grep -q 'unknown bundle "nope"' <<<"$bad" && grep -q 'unknown key "colour"' <<<"$bad" \
  && pass "unknown permissions, bundles and keys are errors (exit 1, nothing written)" || { echo "rc=$rc $bad"; fail "invalid roles accepted"; }

# Init: syncs MAUTIC_ROLES, checks the SAML default role.
init_out="$(docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" -e "MAUTIC_ROLES=$marketing" -e MAUTIC_SAML_IDP_DEFAULT_ROLE_NAME=Marketing "$IMG" init 2>&1)"
grep -q 'role "Marketing"' <<<"$init_out" && grep -q 'init complete' <<<"$init_out" \
  && pass "init syncs the roles and accepts the SAML default role" || { echo "$init_out" | tail -5; fail "init with roles"; }
rc=0; init_bad="$(docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" -e MAUTIC_SAML_IDP_DEFAULT_ROLE_NAME=Gibtsnicht "$IMG" init 2>&1)" || rc=$?
[[ "$rc" != 0 ]] || fail "init accepted a missing SAML role"
grep -q 'SAML default role "Gibtsnicht" does not exist' <<<"$init_bad" && pass "init fails if the SAML default role does not exist" || { echo "$init_bad" | tail -3; fail "missing SAML role message"; }

# Web, worker, cron resolve the name to the ID at start; a missing role is a
# warning. Read what the web server was really started with (PID 1 env).
web_role() { # $1 = role name -> prints saml_idp_default_role of a fresh web container, and its log
  local c="$run_id-samlweb"
  docker run -d --name "$c" --network "$net" "${hardening[@]}" "${env[@]}" -e "MAUTIC_SAML_IDP_DEFAULT_ROLE_NAME=$1" "$IMG" web >/dev/null
  sleep 3
  docker exec "$c" /usr/bin/php -r 'foreach (explode("\0", (string) file_get_contents("/proc/1/environ")) as $kv) {
    if (str_starts_with($kv, "MAUTIC_CONFIG_PARAMETERS=")) { echo json_decode(substr($kv, 25), true)["saml_idp_default_role"] ?? "none"; } }'
  echo; docker logs "$c" 2>&1 | grep -i 'saml' || true
  docker rm -f "$c" >/dev/null
}
ok="$(web_role Marketing)"
[[ "$(head -1 <<<"$ok")" == "$rid" ]] && pass "web started with saml_idp_default_role = ID of \"Marketing\" ($rid)" || { echo "$ok"; fail "SAML role not resolved"; }
warn="$(web_role Gibtsnicht)"
[[ "$(head -1 <<<"$warn")" == none ]] && grep -q 'WARNING: SAML default role "Gibtsnicht" does not exist' <<<"$warn" \
  && pass "missing role at service start: warning, web starts without a default role" || { echo "$warn"; fail "missing role at service start"; }
