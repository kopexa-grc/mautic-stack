# shellcheck shell=bash disable=SC2154,SC2034  # shares variables with test/smoke.sh
# CRM package through MCP: custom fields, companies, dynamic segments,
# contact activity, brand emails from layouts, test email to oneself.
# Sourced by test/smoke.sh after test/mcp-contacts.sh (uses call, result,
# api, pass, fail, base, access, contacts_token, read_token, ada_id, cid,
# run_id, IMG, net, hardening, env).

echo "MCP CRM package (fields, companies, dynamic segments, layouts)"
f="$(result "$(call "$contacts_token" create_contact_field '{"label":"Twenty ID","alias":"twenty_id"}')")"
again="$(result "$(call "$contacts_token" create_contact_field '{"label":"Twenty ID","alias":"twenty_id"}')")"
sel="$(result "$(call "$contacts_token" create_contact_field '{"label":"Deal stage","type":"select","options":["Lead","Qualified","Won"]}')")"
arr="$(result "$(call "$contacts_token" create_contact_field '{"label":"ARR","alias":"arr","type":"number","object":"company"}')")"
jq -e '.created == true' <<<"$f" >/dev/null && jq -e '.created == false' <<<"$again" >/dev/null \
  && jq -e '.alias == "deal_stage"' <<<"$sel" >/dev/null && jq -e '.object == "company"' <<<"$arr" >/dev/null \
  && pass "create_contact_field: text, select (contact), number (company); idempotent" || { echo "$f $again $sel $arr" | head -c 1200; fail "create_contact_field"; }

up="$(result "$(call "$contacts_token" upsert_contacts '{"contacts":[{"email":"ada@example.com","fields":{"twenty_id":"tw-1","deal_stage":"Qualified"},"points":42}]}')")"
ada="$(api "$base/api/contacts/$ada_id" | jq '.contact')"
jq -e '.counts.updated == 1' <<<"$up" >/dev/null && jq -e '.fields.all.twenty_id == "tw-1" and .fields.all.deal_stage == "Qualified" and .points == 42' <<<"$ada" >/dev/null \
  && pass "upsert_contacts writes custom fields and points" || { echo "$up" | head -c 600; jq -c '{points, f: .fields.all | {twenty_id, deal_stage}}' <<<"$ada"; fail "custom fields / points"; }

comp="$(result "$(call "$contacts_token" upsert_companies "{\"companies\":[{\"fields\":{\"companyname\":\"Kopexa Smoke AG\",\"companycity\":\"Kiel\",\"arr\":120000},\"contactIds\":[$ada_id]},{\"fields\":{\"companycity\":\"no name\"}}]}")")"
coid="$(jq -r '.results[0].id' <<<"$comp")"
got="$(result "$(call "$read_token" get_company "{\"id\":$coid}")")"
jq -e '.counts.created == 1 and .counts.failed == 1' <<<"$comp" >/dev/null \
  && jq -e --argjson a "$ada_id" '.fields.arr == 120000 and ([.contacts[].id] | index($a) != null)' <<<"$got" >/dev/null \
  && [[ "$(result "$(call "$contacts_token" upsert_companies '{"companies":[{"fields":{"companyname":"Kopexa Smoke AG","companycity":"Kiel"}}]}')" | jq -r '.counts.unchanged')" == 1 ]] \
  && pass "upsert_companies: create with custom field, link contact, match by name; get_company" || { echo "$comp $got" | head -c 1500; fail "companies"; }
[[ "$(result "$(call "$read_token" search_companies '{"search":"Kopexa Smoke"}')" | jq -r '.total')" == 1 ]] && pass "search_companies" || fail "search_companies"

fields="$(result "$(call "$contacts_token" list_segment_filter_fields '{}')")"
jq -e '([.fields[] | select(.object == "behaviors")] | length > 5) and ([.fields[] | select(.field == "tags")] | length == 1) and ([.fields[] | select(.field == "deal_stage") | .choices] == [["Lead", "Qualified", "Won"]])' <<<"$fields" >/dev/null \
  && pass "list_segment_filter_fields: fields, behaviour filters, tags, custom field choices" || { echo "$fields" | head -c 800; fail "filter fields"; }
dry="$(result "$(call "$contacts_token" create_segment '{"name":"Qualified (dynamic)","filters":[{"field":"deal_stage","operator":"=","value":"Qualified"},{"field":"tags","operator":"in","value":["twenty"]}],"dryRun":true}')")"
jq -e '.dry_run == true and .matching_contacts == 1' <<<"$dry" >/dev/null \
  && [[ "$(result "$(call "$read_token" list_segments '{"search":"Qualified (dynamic)"}')" | jq -r .total)" == 0 ]] \
  && pass "create_segment dryRun: filters valid, 1 contact matches, nothing saved" || { echo "$dry" | head -c 800; fail "dynamic segment dry run"; }
dyn="$(result "$(call "$contacts_token" create_segment '{"name":"Qualified (dynamic)","filters":[{"field":"deal_stage","operator":"=","value":"Qualified"}]}')")"
dsid="$(jq -r .id <<<"$dyn")"
docker run --rm --network "$net" "${hardening[@]}" "${env[@]}" "$IMG" console mautic:segments:update -i "$dsid" >/dev/null 2>&1
[[ "$(jq -r .dynamic <<<"$dyn")" == true ]] && [[ "$(api "$base/api/contacts?search=segment:$(jq -r .alias <<<"$dyn")" | jq -r .total)" == 1 ]] \
  && pass "dynamic segment created; Mautic's segment job fills it" || { echo "$dyn" | head -c 800; fail "dynamic segment"; }
bad="$(result "$(call "$contacts_token" create_segment '{"name":"x","filters":[{"field":"city","operator":"between","value":"x"}]}')")"
upd="$(result "$(call "$contacts_token" update_segment "{\"id\":$dsid,\"filters\":[{\"field\":\"deal_stage\",\"operator\":\"in\",\"value\":[\"Qualified\",\"Won\"]}],\"dryRun\":true}")")"
grep -q 'not allowed; use one of' <<<"$bad" && jq -e '.dry_run == true and .matching_contacts == 1 and (.live_effects | has("running_campaigns"))' <<<"$upd" >/dev/null \
  && pass "invalid operator rejected; update_segment dryRun with count and live_effects" || { echo "$bad $upd" | head -c 1200; fail "segment validation / update"; }

act="$(result "$(call "$read_token" get_contact_activity "{\"id\":$ada_id}")")"
jq -e '.total > 0 and ([.events[].type] | length > 0) and (.types | length > 5)' <<<"$act" >/dev/null \
  && pass "get_contact_activity: $(jq -r .total <<<"$act") events" || { echo "$act" | head -c 800; fail "activity"; }

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
