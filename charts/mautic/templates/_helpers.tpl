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

{{- define "mautic.db.host" -}}
{{- if .Values.mariadb.enabled }}
{{- include "mautic.mariadb.fullname" . }}
{{- else }}
{{- required "externalDatabase.host is required when mariadb.enabled=false" .Values.externalDatabase.host }}
{{- end }}
{{- end }}

{{- define "mautic.db.port" -}}
{{- if .Values.mariadb.enabled }}3306{{ else }}{{ .Values.externalDatabase.port }}{{ end }}
{{- end }}

{{- define "mautic.db.name" -}}
{{- if .Values.mariadb.enabled }}{{ .Values.mariadb.auth.database }}{{ else }}{{ .Values.externalDatabase.database }}{{ end }}
{{- end }}

{{- define "mautic.db.user" -}}
{{- if .Values.mariadb.enabled }}{{ .Values.mariadb.auth.username }}{{ else }}{{ .Values.externalDatabase.username }}{{ end }}
{{- end }}

{{- define "mautic.db.secretName" -}}
{{- if .Values.mariadb.enabled }}
{{- default (include "mautic.mariadb.fullname" .) .Values.mariadb.auth.existingSecret }}
{{- else if .Values.externalDatabase.existingSecret }}
{{- .Values.externalDatabase.existingSecret }}
{{- else }}
{{- printf "%s-externaldb" (include "mautic.fullname" .) }}
{{- end }}
{{- end }}

{{- define "mautic.db.secretKey" -}}
{{- if .Values.mariadb.enabled }}mariadb-password{{ else if .Values.externalDatabase.existingSecret }}{{ .Values.externalDatabase.passwordKey }}{{ else }}password{{ end }}
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
  emptyDir: {}
- name: var
  emptyDir: {}
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
{{- end }}

{{/*
With a ReadWriteOnce volume, non-web pods must run on the node of the web pod.
  include "mautic.affinity" (dict "ctx" . "affinity" .Values.worker.affinity)
*/}}
{{- define "mautic.affinity" -}}
{{- if .affinity }}
affinity:
  {{- toYaml .affinity | nindent 2 }}
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
- name: MAUTIC_DB_HOST
  value: {{ include "mautic.db.host" . | quote }}
- name: MAUTIC_DB_PORT
  value: {{ include "mautic.db.port" . | quote }}
- name: MAUTIC_DB_NAME
  value: {{ include "mautic.db.name" . | quote }}
- name: MAUTIC_DB_USER
  value: {{ include "mautic.db.user" . | quote }}
- name: MAUTIC_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "mautic.db.secretName" . }}
      key: {{ include "mautic.db.secretKey" . }}
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
