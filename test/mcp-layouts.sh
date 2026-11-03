# shellcheck shell=bash disable=SC2154,SC2034  # shares variables with test/smoke.sh
# Brand emails from layouts: the MCP bundle with the Kopexa themes of this
# image (its tools only work with themes that ship a block library).
# Sourced by test/smoke.sh (uses call, result, api, pass, fail, base,
# access, run_id).

echo "MCP brand layouts (Kopexa themes)"
layouts="$(result "$(call "$access" list_email_layouts '{}')")"
jq -e '.layouts[0].theme == "kopexa" and (.layouts[0].panels | has("hero") and has("article") and has("cards"))' <<<"$layouts" >/dev/null \
  && pass "list_email_layouts: kopexa (hero, article, cards)" || { echo "$layouts" | head -c 800; fail "layouts"; }
panels='[{"type":"hero","items":[{"type":"label","text":"WEBINAR"},{"type":"title","text":"NIS2 ohne Umwege"},{"type":"button","text":"Platz sichern","url":"https://www.kopexa.com/de"}]},
         {"type":"article","items":[{"type":"text","html":"Hallo {contactfield=firstname|zusammen}, <b>wichtig</b><script>alert(1)</script>"}]},
         {"type":"cards","left":[{"type":"title","text":"Risiken"}],"right":[{"type":"title","text":"Nachweise"}]}]'
mail="$(result "$(call "$access" create_email_from_layout "{\"name\":\"Layout smoke\",\"subject\":\"NIS2\",\"panels\":$(jq -c . <<<"$panels")}")")"
lid="$(jq -r .id <<<"$mail")"
row="$(docker exec "$run_id-db" mariadb -umautic -pmautic mautic -N -e "SELECT e.template, e.is_published, LOCATE('NIS2 ohne Umwege', e.custom_html) > 0, LOCATE('<script', e.custom_html), LOCATE('<mjml>', g.custom_mjml) FROM emails e JOIN bundle_grapesjsbuilder g ON g.email_id = e.id WHERE e.id = $lid" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/ $//')"
[[ "$row" == "kopexa 0 1 0 1" ]] && pass "create_email_from_layout: unpublished kopexa email, HTML for sending + MJML for the builder, HTML sanitized" || { echo "$mail | $row"; fail "email from layout"; }
badl="$(result "$(call "$access" create_email_from_layout '{"name":"x","subject":"x","panels":[{"type":"hero","items":[{"type":"button","text":"x","url":"http://insecure.example"}]}]}')")"
grep -q 'must be an https' <<<"$badl" && pass "layout URLs must be https (or tokens)" || { echo "$badl"; fail "insecure URL accepted"; }
relay="$(result "$(call "$access" update_email_layout "{\"id\":$lid,\"subject\":\"NIS2 – neu\",\"panels\":[{\"type\":\"article\",\"items\":[{\"type\":\"title\",\"text\":\"Neu\"}]}]}")")"
[[ "$(api "$base/api/emails/$lid" | jq -r .email.subject)" == "NIS2 – neu" ]] && pass "update_email_layout replaces the content" || { echo "$relay"; fail "update_email_layout"; }
testmail="$(result "$(call "$access" send_test_email "{\"id\":$lid}")")"
[[ "$(jq -r .sent_to <<<"$testmail")" == "admin@example.com" ]] && pass "send_test_email goes to the signed-in user only" || { echo "$testmail"; fail "send_test_email"; }
