{{/*
Expand the name of the chart.
*/}}
{{- define "rybbit.name" -}}
{{- with .Chart }}
  {{- with .Name }}
    {{- . | trunc 63 | trimSuffix "-" }}
  {{- else }}
    rybbit
  {{- end }}
{{- else }}
  rybbit
{{- end }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "rybbit.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "rybbit" .Chart.Name | default .Values.nameOverride }}
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
{{- define "rybbit.chart" -}}
{{- printf "%s-%s" (default "rybbit" .Chart.Name) (default "0.1.0" .Chart.Version) | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "rybbit.labels" -}}
helm.sh/chart: {{ include "rybbit.chart" $ }}
{{ include "rybbit.selectorLabels" $ }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ include "rybbit.name" $ }}
release: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "rybbit.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rybbit.name" $ }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Generate random password
*/}}
{{- define "rybbit.randomPassword" -}}
{{- $password := randAlphaNum 32 -}}
{{- $password -}}
{{- end -}}

{{/*
Generate random string
*/}}
{{- define "rybbit.randomString" -}}
{{- $string := randAlphaNum 16 -}}
{{- $string -}}
{{- end -}}

{{/*
Service account name
*/}}
{{- define "rybbit.serviceAccountName" -}}
{{- if .Values.serviceAccount.name }}
{{- .Values.serviceAccount.name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name }}-cleanup
{{- end }}
{{- end }} 