{{/*
Expand the name of the chart.
*/}}
{{- define "jp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "jp.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "jp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "jp.labels" -}}
helm.sh/chart: {{ include "jp.chart" . }}
{{ include "jp.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "jp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "jp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "jp.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "jp.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Resolve the application secret name.
*/}}
{{- define "jp.appSecretName" -}}
{{- default (include "jp.fullname" .) .Values.secret.existingSecretName -}}
{{- end }}

{{/*
Resolve database host by environment.
*/}}
{{- define "jp.databaseHost" -}}
{{- if .Values.localdb.enabled -}}
{{ include "jp.fullname" . }}-db.{{ .Release.Namespace }}.svc.cluster.local
{{- else -}}
{{- required "database.host is required when localdb.enabled=false" .Values.database.host -}}
{{- end -}}
{{- end }}

{{/*
Resolve active service name for Blue-Green rollout.
*/}}
{{- define "jp.activeServiceName" -}}
{{- default (include "jp.fullname" .) .Values.rollout.activeServiceName -}}
{{- end }}

{{/*
Resolve preview service name for Blue-Green rollout.
*/}}
{{- define "jp.previewServiceName" -}}
{{- default (printf "%s-preview" (include "jp.fullname" .)) .Values.rollout.previewServiceName -}}
{{- end }}
