# shellcheck shell=bash disable=SC2154,SC2034  # shares variables with test/smoke.sh
# Amazon S3 plugin from the Helm values (mautic.cloudStorage.amazonS3 ->
# MAUTIC_S3_*, kopexa:cloud-storage:sync). Sourced by test/smoke.sh (uses
# pass, fail, run_id, net, hardening, env, IMG).

echo "Amazon S3 plugin from values (kopexa:cloud-storage:sync)"
s3sync() { docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" "$@" "$IMG" console kopexa:cloud-storage:sync 2>&1; }
s3q() { docker exec "$run_id-db" mariadb -umautic -pmautic mautic -N -e "$1" 2>/dev/null; }
s3_secret='sm0ke/Secret+Access=Key'
s3=(-e MAUTIC_S3_ACCESS_KEY_ID=SMOKEACCESSKEY -e "MAUTIC_S3_SECRET_ACCESS_KEY=$s3_secret"
    -e MAUTIC_S3_BUCKET=marketing-assets -e MAUTIC_S3_REGION=de -e MAUTIC_S3_ENDPOINT=https://s3.de.io.cloud.ovh.net)

grep -q 'nothing declared' <<<"$(s3sync)" \
  && [[ "$(s3q "SELECT is_published FROM plugin_integration_settings WHERE name = 'AmazonS3'")" != 1 ]] \
  && pass "without MAUTIC_S3_* the plugin is not touched" || fail "cloud storage sync without settings"

out="$(s3sync "${s3[@]}")"
row="$(s3q "SELECT CONCAT(is_published, ' ', api_keys) FROM plugin_integration_settings WHERE name = 'AmazonS3'")"
grep -q 'cloud storage "Amazon S3": configured (bucket marketing-assets, region de, endpoint https://s3.de.io.cloud.ovh.net)' <<<"$out" \
  && [[ "$row" == "1 "* ]] && grep -q 'client_secret' <<<"$row" && grep -q 'endpoint' <<<"$row" \
  && pass "plugin configured and published (keys, bucket, region, endpoint)" || { echo "$out"; fail "cloud storage sync"; }
! grep -qF "$s3_secret" <<<"$row" && ! grep -qF SMOKEACCESSKEY <<<"$row" && ! grep -qF marketing-assets <<<"$row" \
  && ! grep -qF "$s3_secret" <<<"$out" && ! grep -qF SMOKEACCESSKEY <<<"$out" \
  && pass "keys are stored encrypted (Mautic's secret_key) and not printed" || fail "S3 credentials in clear text"

# "unchanged" means Mautic's own integration object decrypted what was stored
# and got the declared values back.
grep -q 'cloud storage "Amazon S3": unchanged' <<<"$(s3sync "${s3[@]}")" && pass "second run: unchanged" || fail "second run changed the plugin"

out="$(s3sync "${s3[@]}" -e MAUTIC_S3_BUCKET=other-bucket -e MAUTIC_S3_SECRET_ACCESS_KEY=rotated)"
grep -q 'cloud storage "Amazon S3": updated — secret access key, bucket (bucket other-bucket' <<<"$out" \
  && pass "changed bucket and rotated key: updated, the changed settings are named" || { echo "$out"; fail "cloud storage update"; }

# Unpublished in the plugin dialog: the values win at the next start.
s3q "UPDATE plugin_integration_settings SET is_published = 0 WHERE name = 'AmazonS3'"
out="$(s3sync "${s3[@]}" -e MAUTIC_S3_BUCKET=other-bucket -e MAUTIC_S3_SECRET_ACCESS_KEY=rotated)"
grep -q 'updated — published' <<<"$out" && [[ "$(s3q "SELECT is_published FROM plugin_integration_settings WHERE name = 'AmazonS3'")" == 1 ]] \
  && pass "unpublished in the UI: published again" || { echo "$out"; fail "republish"; }

before="$(s3q "SELECT MD5(api_keys) FROM plugin_integration_settings WHERE name = 'AmazonS3'")"
rc=0; bad="$(s3sync -e MAUTIC_S3_BUCKET=Not_A_Bucket -e MAUTIC_S3_ENDPOINT=s3.example.com)" || rc=$?
[[ "$rc" != 0 ]] && grep -q 'MAUTIC_S3_ACCESS_KEY_ID is required' <<<"$bad" && grep -q 'MAUTIC_S3_SECRET_ACCESS_KEY is required' <<<"$bad" \
  && grep -q 'not a bucket name' <<<"$bad" && grep -q 'MAUTIC_S3_ENDPOINT must be a URL' <<<"$bad" \
  && [[ "$(s3q "SELECT MD5(api_keys) FROM plugin_integration_settings WHERE name = 'AmazonS3'")" == "$before" ]] \
  && pass "missing keys, invalid bucket and endpoint are errors (exit 1, nothing written)" || { echo "rc=$rc $bad"; fail "invalid S3 settings accepted"; }

# Init: syncs MAUTIC_S3_*; the secret may come from a file (mounted Secret).
s3_file="$(mktemp)"; printf '%s\n' "$s3_secret" >"$s3_file"; chmod 644 "$s3_file"
init_out="$(docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" -v "$s3_file:/run/secrets/s3-secret:ro" \
  -e MAUTIC_S3_ACCESS_KEY_ID=SMOKEACCESSKEY -e MAUTIC_S3_SECRET_ACCESS_KEY_FILE=/run/secrets/s3-secret \
  -e MAUTIC_S3_BUCKET=marketing-assets -e MAUTIC_S3_REGION=de -e MAUTIC_S3_ENDPOINT=https://s3.de.io.cloud.ovh.net "$IMG" init 2>&1)"
grep -q 'cloud storage "Amazon S3": updated' <<<"$init_out" && grep -q 'init complete' <<<"$init_out" \
  && grep -q 'cloud storage "Amazon S3": unchanged' <<<"$(s3sync "${s3[@]}")" \
  && pass "init syncs the plugin (secret from MAUTIC_S3_SECRET_ACCESS_KEY_FILE)" || { echo "$init_out" | tail -5; fail "init with S3 settings"; }
rc=0; init_bad="$(docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" -e MAUTIC_S3_BUCKET=marketing-assets "$IMG" init 2>&1)" || rc=$?
[[ "$rc" != 0 ]] && grep -q 'Amazon S3 plugin sync failed' <<<"$init_bad" \
  && pass "init fails on incomplete S3 settings" || { echo "$init_bad" | tail -3; fail "init accepted incomplete S3 settings"; }
