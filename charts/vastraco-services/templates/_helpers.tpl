{{/*
Expand the name of the chart.
*/}}
{{- define "vastraco.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources.
*/}}
{{- define "vastraco.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{/*
Selector labels for a given service name.
Usage: include "vastraco.selectorLabels" (dict "name" $name)
*/}}
{{- define "vastraco.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/component: microservice
{{- end }}
