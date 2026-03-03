{{/*
Expand the name of the chart.
*/}}
{{- define "pedido-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "pedido-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Create chart label.
*/}}
{{- define "pedido-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "pedido-app.labels" -}}
helm.sh/chart: {{ include "pedido-app.chart" . }}
app.kubernetes.io/name: {{ include "pedido-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
environment: {{ .Values.global.environment }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "pedido-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pedido-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
