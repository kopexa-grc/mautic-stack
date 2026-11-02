{{/* ---------- names & labels ---------- */}}
{{- define "mautic.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mautic.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "mautic.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mautic.labels" -}}
helm.sh/chart: {{ include "mautic.chart" . }}
{{ include "mautic.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mautic
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "mautic.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mautic.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Labels for a component: include "mautic.componentLabels" (dict "ctx" . "component" "web") */}}
{{- define "mautic.componentLabels" -}}
{{ include "mautic.labels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "mautic.componentSelector" -}}
{{ include "mautic.selectorLabels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "mautic.annotations" -}}
{{- with .Values.commonAnnotations }}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "mautic.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mautic.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* ---------- images ---------- */}}
{{/* include "mautic.imageRef" (dict "image" .Values.image "default" .Chart.AppVersion) */}}
{{- define "mautic.imageRef" -}}
{{- $tag := default .default .image.tag -}}
{{- if .image.digest -}}
{{- printf "%s@%s" .image.repository .image.digest -}}
{{- else -}}
{{- printf "%s:%s" .image.repository (toString $tag) -}}
{{- end -}}
{{- end }}

{{- define "mautic.image" -}}
{{ include "mautic.imageRef" (dict "image" .Values.image "default" .Chart.AppVersion) }}
{{- end }}

{{/* ---------- database ---------- */}}
{{- define "mautic.mariadb.fullname" -}}
{{- printf "%s-mariadb" (include "mautic.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mautic.mariadb.secretName" -}}
{{- default (include "mautic.mariadb.fullname" .) .Values.mariadb.auth.existingSecret }}
{{- end }}

{{/*
Database connection as env vars. Every field of externalDatabase can come
from a plain value or from a key in externalDatabase.existingSecret
(externalDatabase.secretKeys.<field>), e.g. an operator's connection secret.
  include "mautic.db.env" (dict "ctx" . "prefix" "MAUTIC_DB_")
emits <prefix>HOST, PORT, NAME, USER, PASSWORD.
*/}}
{{- define "mautic.db.env" -}}
{{- $v := .ctx.Values -}}
{{- $names := dict "host" "HOST" "port" "PORT" "database" "NAME" "username" "USER" "password" "PASSWORD" -}}
{{- if $v.mariadb.enabled }}
- name: {{ .prefix }}HOST
  value: {{ include "mautic.mariadb.fullname" .ctx | quote }}
- name: {{ .prefix }}PORT
  value: "3306"
- name: {{ .prefix }}NAME
  value: {{ $v.mariadb.auth.database | quote }}
- name: {{ .prefix }}USER
  value: {{ $v.mariadb.auth.username | quote }}
- name: {{ .prefix }}PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "mautic.mariadb.secretName" .ctx }}
      key: mariadb-password
{{- else }}
{{- $db := $v.externalDatabase -}}
{{- $keys := deepCopy ($db.secretKeys | default dict) -}}
{{- $pwKey := default $db.passwordKey $keys.password -}}
{{- $_ := set $keys "password" $pwKey -}}
{{- if not (or $db.host (and $db.existingSecret $keys.host)) }}
{{- fail "externalDatabase.host (or existingSecret + secretKeys.host) is required when mariadb.enabled=false" }}
{{- end }}
{{- range $field := list "host" "port" "database" "username" "password" }}
- name: {{ $.prefix }}{{ index $names $field }}
{{- $key := index $keys $field }}
{{- if and $db.existingSecret $key }}
  valueFrom:
    secretKeyRef:
      name: {{ $db.existingSecret }}
      key: {{ $key }}
{{- else if eq $field "password" }}
  valueFrom:
    secretKeyRef:
      name: {{ include "mautic.fullname" $.ctx }}-externaldb
      key: password
{{- else }}
  value: {{ index $db $field | toString | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/* True if the chart must create a Secret for the external DB password. */}}
{{- define "mautic.db.needsPasswordSecret" -}}
{{- $db := .Values.externalDatabase -}}
{{- $keys := $db.secretKeys | default dict -}}
{{- if and (not .Values.mariadb.enabled) (not (and $db.existingSecret (or $keys.password $db.passwordKey))) }}true{{ end }}
{{- end }}

{{/* ---------- secrets ---------- */}}
{{- define "mautic.secretName" -}}
{{- include "mautic.fullname" . }}
{{- end }}

{{/*
Return an existing value of a key in a Secret (so generated passwords survive
upgrades), or a new random one.
  include "mautic.secretValue" (dict "ctx" . "name" "<secret>" "key" "<key>" "length" 32)
*/}}
{{/* Existing RSA key from the release Secret, or a new one (PEM, base64). */}}
{{- define "mautic.secretRsaKey" -}}
{{- $existing := lookup "v1" "Secret" .ctx.Release.Namespace .name -}}
{{- if and $existing (hasKey $existing.data .key) -}}
{{- index $existing.data .key -}}
{{- else -}}
{{- genPrivateKey "rsa" | b64enc -}}
{{- end -}}
{{- end }}

{{- define "mautic.secretValue" -}}
{{- $existing := lookup "v1" "Secret" .ctx.Release.Namespace .name -}}
{{- if and $existing (hasKey $existing.data .key) -}}
{{- index $existing.data .key -}}
{{- else -}}
{{- randAlphaNum (int .length) | b64enc -}}
{{- end -}}
{{- end }}

{{/* ---------- volumes ---------- */}}
{{- define "mautic.rwo" -}}
{{- if and .Values.persistence.enabled (not (has "ReadWriteMany" .Values.persistence.accessModes)) }}true{{ end }}
{{- end }}

{{- define "mautic.claimName" -}}
{{- default (printf "%s-data" (include "mautic.fullname" .)) .Values.persistence.existingClaim }}
{{- end }}

{{/* Volumes shared by every Mautic pod. */}}
{{- define "mautic.volumes" -}}
- name: data
{{- if .Values.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ include "mautic.claimName" . }}
{{- else }}
  emptyDir: {}
{{- end }}
- name: tmp
  emptyDir:
    sizeLimit: {{ .Values.ephemeral.tmpSizeLimit }}
- name: var
  emptyDir:
    sizeLimit: {{ .Values.ephemeral.varSizeLimit }}
{{- end }}

{{/*
Scheduling for a pod: component values win, global values are the default.
  include "mautic.scheduling" (dict "ctx" . "c" .Values.worker)
*/}}
{{- define "mautic.scheduling" -}}
{{- $g := .ctx.Values.global -}}
{{- with (.c.priorityClassName | default $g.priorityClassName) }}
priorityClassName: {{ . }}
{{- end }}
{{- with (.c.nodeSelector | default $g.nodeSelector) }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with (.c.tolerations | default $g.tolerations) }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with (.c.topologySpreadConstraints | default $g.topologySpreadConstraints) }}
topologySpreadConstraints:
  {{- tpl (toYaml .) $.ctx | nindent 2 }}
{{- end }}
{{- end }}

{{/* Extra pod labels: global + component. */}}
{{- define "mautic.podLabels" -}}
{{- with (merge (dict) (.c.podLabels | default dict) .ctx.Values.global.podLabels) }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Extra pod annotations: global + component. */}}
{{- define "mautic.podAnnotations" -}}
{{- with (merge (dict) (.c.podAnnotations | default dict) .ctx.Values.global.podAnnotations) }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "mautic.volumeMounts" -}}
- name: data
  mountPath: /app/config
  subPath: config
- name: data
  mountPath: /app/docroot/media/files
  subPath: media/files
- name: data
  mountPath: /app/docroot/media/images
  subPath: media/images
- name: tmp
  mountPath: /tmp
- name: var
  mountPath: /app/var
# GeoIP database (Mautic keeps it next to the cache): persistent and shared,
# so the monthly download reaches every pod and survives restarts.
- name: data
  mountPath: /app/var/cache/ip_data
  subPath: ip_data
{{- end }}

{{/*
With a ReadWriteOnce volume, non-web pods must run on the node of the web pod.
  include "mautic.affinity" (dict "ctx" . "affinity" .Values.worker.affinity)
*/}}
{{- define "mautic.affinity" -}}
{{- $affinity := .affinity | default .ctx.Values.global.affinity }}
{{- if $affinity }}
affinity:
  {{- toYaml $affinity | nindent 2 }}
{{- else if include "mautic.rwo" .ctx }}
affinity:
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            {{- include "mautic.componentSelector" (dict "ctx" .ctx "component" "web") | nindent 12 }}
        topologyKey: kubernetes.io/hostname
{{- end }}
{{- end }}

{{/* ---------- environment ---------- */}}
{{- define "mautic.env" -}}
{{ include "mautic.db.env" (dict "ctx" . "prefix" "MAUTIC_DB_") }}
{{- if and (not .Values.mariadb.enabled) .Values.externalDatabase.tablePrefix }}
- name: MAUTIC_DB_TABLE_PREFIX
  value: {{ .Values.externalDatabase.tablePrefix | quote }}
{{- end }}
- name: MAUTIC_SITE_URL
  value: {{ required "mautic.siteUrl is required (e.g. https://mautic.example.com)" .Values.mautic.siteUrl | quote }}
- name: MAUTIC_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ default (include "mautic.secretName" .) .Values.mautic.existingSecret }}
      key: secret-key
{{- with .Values.mautic.trustedProxies }}
- name: MAUTIC_TRUSTED_PROXIES
  value: {{ join "," . | quote }}
- name: APACHE_TRUSTED_PROXIES
  value: {{ join " " . | quote }}
{{- end }}
{{- with .Values.mautic.trustedHosts }}
- name: MAUTIC_TRUSTED_HOSTS
  value: {{ join "," . | quote }}
{{- end }}
{{- if or .Values.mautic.mailer.dsn .Values.mautic.mailer.existingSecret }}
- name: MAUTIC_MAILER_DSN
  valueFrom:
    secretKeyRef:
      name: {{ default (include "mautic.secretName" .) .Values.mautic.mailer.existingSecret }}
      key: {{ if .Values.mautic.mailer.existingSecret }}{{ .Values.mautic.mailer.dsnKey }}{{ else }}mailer-dsn{{ end }}
{{- end }}
{{- with .Values.mautic.mailer.fromEmail }}
- name: MAUTIC_MAILER_FROM_EMAIL
  value: {{ . | quote }}
{{- end }}
{{- with .Values.mautic.mailer.fromName }}
- name: MAUTIC_MAILER_FROM_NAME
  value: {{ . | quote }}
{{- end }}
{{- with .Values.mautic.messenger.email }}
- name: MAUTIC_MESSENGER_DSN_EMAIL
  value: {{ . | quote }}
{{- end }}
{{- with .Values.mautic.messenger.hit }}
- name: MAUTIC_MESSENGER_DSN_HIT
  value: {{ . | quote }}
{{- end }}
{{- with .Values.mautic.messenger.failed }}
- name: MAUTIC_MESSENGER_DSN_FAILED
  value: {{ . | quote }}
{{- end }}
{{- with .Values.mautic.saml }}
{{- if .enabled }}
{{- if not (or .idpMetadata .idpMetadataFrom) }}
{{- fail "mautic.saml.enabled requires idpMetadata or idpMetadataFrom" }}
{{- end }}
- name: MAUTIC_SAML_IDP_METADATA
  {{- if .idpMetadataFrom }}
  valueFrom:
    {{- toYaml .idpMetadataFrom | nindent 4 }}
  {{- else }}
  value: {{ .idpMetadata | quote }}
  {{- end }}
{{- with .entityId }}
- name: MAUTIC_SAML_IDP_ENTITY_ID
  value: {{ . | quote }}
{{- end }}
{{- with .spCertificateSecret }}
- name: MAUTIC_SAML_IDP_OWN_CERTIFICATE
  valueFrom:
    secretKeyRef: {name: {{ . }}, key: tls.crt}
- name: MAUTIC_SAML_IDP_OWN_PRIVATE_KEY
  valueFrom:
    secretKeyRef: {name: {{ . }}, key: tls.key}
{{- end }}
{{- range $attr, $name := .attributes }}
{{- if $name }}
- name: MAUTIC_SAML_IDP_{{ upper $attr }}_ATTRIBUTE
  value: {{ $name | quote }}
{{- end }}
{{- end }}
{{- with .defaultRoleId }}
- name: MAUTIC_SAML_IDP_DEFAULT_ROLE
  value: {{ . | toString | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- with .Values.mautic.postal.jwksUrl }}
- name: MAUTIC_POSTAL_JWKS_URL
  value: {{ . | quote }}
{{- end }}
{{- with .Values.mautic.postal.publicKeyFrom }}
- name: MAUTIC_POSTAL_WEBHOOK_PUBLIC_KEY
  valueFrom:
    {{- toYaml . | nindent 4 }}
{{- end }}
{{- if .Values.mautic.oauth.enabled }}
{{- $oauthSecret := default (include "mautic.secretName" .) .Values.mautic.oauth.existingSecret }}
- name: MAUTIC_OAUTH_PRIVATE_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $oauthSecret }}
      key: oauth-private-key
- name: MAUTIC_OAUTH_ENCRYPTION_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $oauthSecret }}
      key: oauth-encryption-key
- name: MAUTIC_OAUTH_REDIRECT_HOSTS
  value: {{ join "," .Values.mautic.oauth.redirectHosts | quote }}
{{- with .Values.mautic.oauth.resource }}
- name: MAUTIC_OAUTH_RESOURCE
  value: {{ . | quote }}
{{- end }}
- name: MAUTIC_MCP_LIVE_CAMPAIGN_EDITS
  value: {{ .Values.mautic.mcp.liveCampaignEdits | toString | quote }}
{{- end }}
{{- with .Values.mautic.cors.validDomains }}
- name: MAUTIC_CORS_VALID_DOMAINS
  value: {{ join "," . | quote }}
- name: MAUTIC_CORS_RESTRICT_DOMAINS
  value: {{ $.Values.mautic.cors.restrictDomains | toString | quote }}
{{- end }}
{{- with .Values.mautic.ipLookup.service }}
- name: MAUTIC_IP_LOOKUP_SERVICE
  value: {{ . | quote }}
{{- end }}
{{- with .Values.mautic.ipLookup.authFrom }}
- name: MAUTIC_IP_LOOKUP_AUTH
  valueFrom:
    {{- toYaml . | nindent 4 }}
{{- end }}
{{- with .Values.mautic.configParameters }}
- name: MAUTIC_CONFIG_PARAMETERS
  value: {{ toJson . | quote }}
{{- end }}
- name: PHP_MEMORY_LIMIT
  value: {{ .Values.mautic.php.memoryLimit | quote }}
- name: PHP_MAX_EXECUTION_TIME
  value: {{ .Values.mautic.php.maxExecutionTime | quote }}
- name: PHP_UPLOAD_MAX_FILESIZE
  value: {{ .Values.mautic.php.uploadMaxFilesize | quote }}
- name: PHP_POST_MAX_SIZE
  value: {{ .Values.mautic.php.postMaxSize | quote }}
- name: PHP_DATE_TIMEZONE
  value: {{ .Values.mautic.php.timezone | quote }}
{{- with .Values.mautic.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "mautic.envFrom" -}}
{{- with .Values.mautic.extraEnvFrom }}
envFrom:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/* Host header for probes, so Mautic's trusted_hosts check passes. */}}
{{- define "mautic.siteHost" -}}
{{- (urlParse .Values.mautic.siteUrl).host -}}
{{- end }}

{{/*
Environment for the restic container: repository, password and backend
credentials can each come from a plain value, a whole Secret (envFrom) or
individual Secret/ConfigMap keys.
*/}}
{{- define "mautic.backup.env" -}}
{{- $b := .Values.backup -}}
{{- $secretEnv := $b.secretEnv | default dict -}}
{{- $cmEnv := $b.configMapEnv | default dict -}}
{{- if not (or $b.repository $b.existingSecret (hasKey $secretEnv "RESTIC_REPOSITORY") (hasKey $cmEnv "RESTIC_REPOSITORY")) }}
{{- fail "backup: set backup.repository, or provide RESTIC_REPOSITORY via backup.existingSecret / secretEnv / configMapEnv" }}
{{- end }}
{{- if not (or $b.existingSecret (hasKey $secretEnv "RESTIC_PASSWORD")) }}
{{- fail "backup: RESTIC_PASSWORD must come from backup.existingSecret or backup.secretEnv.RESTIC_PASSWORD" }}
{{- end }}
{{- if $b.repository }}
- name: RESTIC_REPOSITORY
  value: {{ $b.repository | quote }}
{{- end }}
{{- range $name, $ref := $secretEnv }}
- name: {{ $name }}
  valueFrom:
    secretKeyRef:
      name: {{ required (printf "backup.secretEnv.%s.name is required" $name) $ref.name }}
      key: {{ required (printf "backup.secretEnv.%s.key is required" $name) $ref.key }}
{{- end }}
{{- range $name, $ref := $cmEnv }}
- name: {{ $name }}
  valueFrom:
    configMapKeyRef:
      name: {{ required (printf "backup.configMapEnv.%s.name is required" $name) $ref.name }}
      key: {{ required (printf "backup.configMapEnv.%s.key is required" $name) $ref.key }}
{{- end }}
{{- end }}
