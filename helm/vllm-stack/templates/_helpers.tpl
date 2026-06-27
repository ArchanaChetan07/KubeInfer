{{/*
helm/vllm-stack/templates/_helpers.tpl
Shared template helpers used across all manifests.
*/}}

{{/* Chart name */}}
{{- define "vllm-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Full release name */}}
{{- define "vllm-stack.fullname" -}}
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

{{/* Chart label */}}
{{- define "vllm-stack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels — applied to every resource.
Follows the Kubernetes recommended label set.
*/}}
{{- define "vllm-stack.labels" -}}
helm.sh/chart: {{ include "vllm-stack.chart" . }}
app.kubernetes.io/name: {{ include "vllm-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: llm-inference-platform
{{ include "vllm-stack.commonLabels" . }}
{{- end }}

{{/* Selector labels (subset used in matchLabels) */}}
{{- define "vllm-stack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vllm-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Engine-specific selector labels */}}
{{- define "vllm-stack.engineSelectorLabels" -}}
{{ include "vllm-stack.selectorLabels" . }}
app.kubernetes.io/component: engine
{{- end }}

{{/* Router-specific selector labels */}}
{{- define "vllm-stack.routerSelectorLabels" -}}
{{ include "vllm-stack.selectorLabels" . }}
app.kubernetes.io/component: router
{{- end }}

{{/* Common labels from values */}}
{{- define "vllm-stack.commonLabels" -}}
{{- with .Values.commonLabels }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{/* ServiceAccount name */}}
{{- define "vllm-stack.serviceAccountName" -}}
{{- if .Values.rbac.create }}
{{- default (include "vllm-stack.fullname" .) .Values.rbac.serviceAccountName }}
{{- else }}
{{- default "default" .Values.rbac.serviceAccountName }}
{{- end }}
{{- end }}

{{/* Namespace */}}
{{- define "vllm-stack.namespace" -}}
{{- .Values.namespace.name }}
{{- end }}

{{/* vLLM engine args — built from values */}}
{{- define "vllm-stack.engineArgs" -}}
- "--host"
- "0.0.0.0"
- "--port"
- "8000"
- "--model"
- {{ .Values.model.name | quote }}
- "--tensor-parallel-size"
- {{ .Values.engine.tensorParallelSize | quote }}
- "--dtype"
- {{ .Values.model.dtype | quote }}
- "--gpu-memory-utilization"
- {{ .Values.model.gpuMemoryUtilization | quote }}
- "--max-model-len"
- {{ .Values.model.maxModelLen | quote }}
- "--download-dir"
- "/models"
- "--trust-remote-code"
{{- if .Values.model.disableLogRequests }}
- "--disable-log-requests"
{{- end }}
{{- if .Values.model.enablePrefixCaching }}
- "--enable-prefix-caching"
{{- end }}
{{- with .Values.engine.extraArgs }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end }}
