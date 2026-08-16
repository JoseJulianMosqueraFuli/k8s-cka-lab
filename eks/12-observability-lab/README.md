# Lab 12: Observabilidad y SLOs

## Resumen

Implementas los tres pilares de observabilidad (métricas, logs, trazas) con
opciones reales de AWS. Pero el punto del lab no es instalar herramientas — es
definir SLOs, alertar sobre error budget, y entender que "CPU al 80%" no es una
alerta útil.

Al final, lo apagas todo. La observabilidad es el costo recurrente que más
sorprende.

**Se monta sobre:** el cluster del lab 02 (EC2) o 03 (Auto Mode).
**Costo estimado adicional:** ~$0.30-0.50/hr (CloudWatch, AMP, ADOT — varía según volumen)
**Tiempo:** ~2h 30m

**Herramientas necesarias:**

- AWS CLI v2
- kubectl
- helm

**Conexión CKA:** `domains/05-troubleshooting` — logging, monitoring (30%)

---

## Los tres pilares

```
┌──────────────────────────────────────────────────────────┐
│                    OBSERVABILIDAD                          │
├──────────────┬──────────────────┬────────────────────────┤
│   MÉTRICAS   │      LOGS        │        TRAZAS          │
│              │                  │                        │
│ "¿Cuánto?"  │ "¿Qué pasó?"    │ "¿Por dónde pasó?"     │
│              │                  │                        │
│ Container    │ Fluent Bit →     │ ADOT → X-Ray           │
│ Insights     │ CloudWatch Logs  │ (OpenTelemetry)        │
│ o AMP+Grafana│                  │                        │
└──────────────┴──────────────────┴────────────────────────┘
```

---

## Parte 1: Métricas

### Opción A: Container Insights (managed, rápido)

```bash
CLUSTER_NAME=eks-ec2-lab
REGION=us-east-1

# Instalar el add-on de CloudWatch Observability
aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name amazon-cloudwatch-observability \
  --region $REGION

# Esperar
aws eks wait addon-active \
  --cluster-name $CLUSTER_NAME \
  --addon-name amazon-cloudwatch-observability \
  --region $REGION
```

Después de ~5 minutos, en la consola de CloudWatch → Container Insights:

- CPU/memory por pod, nodo, namespace, cluster
- Network I/O
- Disk I/O (para StatefulSets con EBS)

### Opción B: Amazon Managed Prometheus (AMP) + Grafana

```bash
# Crear workspace de AMP
AMP_WORKSPACE_ID=$(aws amp create-workspace \
  --alias eks-lab-metrics \
  --region $REGION \
  --query "workspaceId" --output text)

AMP_ENDPOINT=$(aws amp describe-workspace \
  --workspace-id $AMP_WORKSPACE_ID --region $REGION \
  --query "workspace.prometheusEndpoint" --output text)

echo "AMP endpoint: $AMP_ENDPOINT"
```

```bash
# Instalar ADOT collector para scraping de métricas
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

helm install adot-collector open-telemetry/opentelemetry-collector \
  --namespace observability --create-namespace \
  --set mode=deployment \
  --set config.receivers.prometheus.config.scrape_configs[0].job_name=kubernetes-pods \
  --set config.exporters.prometheusremotewrite.endpoint="${AMP_ENDPOINT}api/v1/remote_write"
```

### Comparación: Container Insights vs AMP+Grafana

| Aspecto            | Container Insights               | AMP + Grafana                   |
| ------------------ | -------------------------------- | ------------------------------- |
| **Setup**          | Un add-on (2 min)                | Workspace + collector + Grafana |
| **Costo**          | ~$0.01/pod/hr                    | $0.03/10K metrics + Grafana     |
| **Dashboards**     | Pre-built en CloudWatch          | Custom en Grafana (ilimitados)  |
| **Retención**      | 15 meses max                     | Configurable (hasta años)       |
| **Alertas custom** | CloudWatch Alarms                | AlertManager + Grafana alerts   |
| **PromQL**         | No                               | Sí (nativo)                     |
| **Mejor para**     | Empezar rápido, equipos pequeños | Equipos que ya usan Prometheus  |

### ¿Por qué?

Container Insights es suficiente para el 80% de los casos. AMP+Grafana es para
equipos que ya tienen dashboards de Grafana, alertas en PromQL, y necesitan más
control. No empieces con AMP a menos que ya conozcas Prometheus.

---

## Parte 2: Logs

### Fluent Bit → CloudWatch Logs

```bash
# En clusters con el add-on de CloudWatch Observability, Fluent Bit ya viene incluido.
# Si no:
kubectl apply -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonSet/container-insights-monitoring/fluent-bit/fluent-bit.yaml
```

### Habilitar logs del control plane

```bash
# Los logs del control plane NO están habilitados por defecto (cuestan dinero)
aws eks update-cluster-config \
  --name $CLUSTER_NAME \
  --region $REGION \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
```

### ¿Qué log habilitar?

| Tipo                | Para qué sirve                                       | Volumen  | Costo |
| ------------------- | ---------------------------------------------------- | -------- | ----- |
| `api`               | Todas las requests al API server                     | **Alto** | $$$   |
| `audit`             | Quién hizo qué (compliance, security investigations) | Alto     | $$    |
| `authenticator`     | Problemas de autenticación (Access Entries, tokens)  | Bajo     | $     |
| `controllerManager` | Scheduling decisions, lifecycle                      | Medio    | $     |
| `scheduler`         | Por qué un pod se scheduleó donde se scheduleó       | Medio    | $     |

**Recomendación para labs:** habilitar `audit` + `authenticator`. Son los más
útiles para troubleshooting. `api` genera demasiado volumen para su valor en
la mayoría de los casos.

### La conversación de costos

```bash
# Ver cuánto generan los logs (después de 24h)
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/eks/$CLUSTER_NAME" \
  --region $REGION \
  --query "logGroups[].[logGroupName,storedBytes]" --output table
```

CloudWatch Logs cobra:

- $0.50/GB por ingestión
- $0.03/GB/mes por almacenamiento
- Un cluster activo con `api` logs puede generar 5-50 GB/día

En producción real, retención de 7-30 días + export a S3 Glacier para largo plazo.

---

## Parte 3: Trazas (OpenTelemetry)

### ¿Por qué OpenTelemetry?

OpenTelemetry es vendor-neutral. Hoy exportas a X-Ray. Mañana puedes cambiar a
Datadog, Jaeger, o Honeycomb cambiando solo la configuración del exporter, no
tu código.

### Instalar ADOT (AWS Distro for OpenTelemetry)

```bash
# ADOT como add-on de EKS
aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name adot \
  --region $REGION

aws eks wait addon-active \
  --cluster-name $CLUSTER_NAME \
  --addon-name adot \
  --region $REGION
```

### Instrumentar una aplicación (ejemplo en Go)

```go
// Agregar al identity-api del lab 04:
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace"
    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// En main():
// handler = otelhttp.NewHandler(handler, "identity-api")
```

### Collector config para X-Ray

```yaml
# manifests/otel-collector.yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: otel-collector
  namespace: observability
spec:
  mode: deployment
  config: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    exporters:
      awsxray:
        region: us-east-1
    service:
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [awsxray]
```

### ¿Cuándo valen la pena las trazas?

- Arquitectura de microservicios (>3 services por request)
- Debugging de latencia ("¿dónde se pierde el tiempo?")
- Entender dependencias entre servicios

Para un monolito o 2-3 services, logs + métricas suelen ser suficientes.

---

## Parte 4: SLOs — la parte que casi nadie hace

### El problema con alertas tradicionales

```
Alerta: "CPU del nodo al 80%"
Pregunta: ¿Afecta al usuario?
Respuesta: No sé.
Acción: Nada (o pánico innecesario)
```

Alertar sobre **síntomas del sistema** (CPU, memoria) en vez de **síntomas del
servicio** (errores, latencia) produce on-call insostenible: muchas alertas,
pocas relevantes.

### Definir SLI (Service Level Indicator)

```
SLI = "Proporción de requests HTTP que devuelven 2xx/3xx en menos de 500ms"

Medido en: ALB metrics (HTTPCode_Target_2XX_Count, TargetResponseTime)
```

```bash
# Obtener métricas del ALB (últimos 5 min)
ALB_ARN=$(aws elbv2 describe-load-balancers --query "LoadBalancers[0].LoadBalancerArn" --output text)
ALB_ID=$(echo $ALB_ARN | awk -F'/' '{print $NF}')

# Requests exitosos
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name HTTPCode_Target_2XX_Count \
  --dimensions Name=LoadBalancer,Value="app/$ALB_ID" \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 --statistics Sum --region $REGION

# Latencia p99
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime \
  --dimensions Name=LoadBalancer,Value="app/$ALB_ID" \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 --statistics p99 --region $REGION
```

### Definir SLO (Service Level Objective)

```
SLO = 99.9% de disponibilidad por mes

Error budget = 0.1% del tiempo = 43.2 minutos/mes de errores permitidos
```

| SLO    | Error budget/mes | Significado práctico                           |
| ------ | ---------------- | ---------------------------------------------- |
| 99%    | 7h 18min         | Generable con un equipo pequeño                |
| 99.9%  | 43.2 min         | Requiere automatización, canary, PDBs          |
| 99.95% | 21.6 min         | Requiere multi-AZ, blue/green upgrades         |
| 99.99% | 4.3 min          | Requiere multi-región (probablemente overkill) |

### Alertar sobre error budget burn rate

```yaml
# En Grafana/Prometheus (si usas AMP):
# Alert: el error budget se está consumiendo 14x más rápido de lo normal
# (se agotaría en 2 horas en vez de 30 días)

# En CloudWatch:
# Composite Alarm:
#   - HTTPCode_Target_5XX_Count > X durante 5 minutos
#   - TargetResponseTime p99 > 500ms durante 5 minutos
```

### ¿Por qué burn rate y no threshold?

| Alerta                             | Problema                                               |
| ---------------------------------- | ------------------------------------------------------ |
| "Error rate > 1%"                  | Un spike de 2 segundos te despierta                    |
| "CPU > 80% por 5 min"              | No correlaciona con impacto al usuario                 |
| "Error budget burning at 14x rate" | Significa: a este ritmo, nos quedamos sin margen en 2h |

La segunda no te despierta por un blip. Te despierta cuando hay un problema real
que, de no resolverse, consumirá todo tu error budget.

---

## Parte 5: Alertas por síntomas de servicio

### Lo que importa al usuario

| Síntoma del servicio     | Métrica                        | Alerta sugerida          |
| ------------------------ | ------------------------------ | ------------------------ |
| "No carga"               | 5xx rate                       | > 1% por 2 min           |
| "Está lento"             | Latencia p99                   | > 1s por 5 min           |
| "No puedo hacer login"   | Errores en endpoint específico | > 5 errores/min en /auth |
| "Se perdieron mis datos" | Tasa de escrituras fallidas    | > 0 por 1 min            |

### Lo que NO importa directamente al usuario

| Síntoma del sistema | Por qué alertar es débil               |
| ------------------- | -------------------------------------- |
| CPU al 80%          | El pod puede funcionar perfecto al 90% |
| Memoria al 70%      | Go/Java usan memoria activamente       |
| Disco al 85%        | Depende de si crece o es estable       |
| Pod restart         | Si se recupera en 5s, el user no nota  |

**Principio:** alerta sobre lo que el usuario siente, no sobre lo que la máquina
reporta. Los dashboards de sistema son para diagnóstico DESPUÉS de que la alerta
de servicio te avisa.

---

## Parte 6: Apagar todo — la realidad de costos

```bash
# Ver cuánto llevas gastando en observabilidad (estimado)
echo "=== Costo estimado de observabilidad ==="
echo "Container Insights: ~$0.01/pod/hr × pods × horas"
echo "CloudWatch Logs: $0.50/GB ingestión"
echo "Control plane logs: según volumen (puede ser $5-50/día)"
echo "AMP: $0.03 por 10K metrics series"
echo "X-Ray traces: $5.00 per million traces"
echo ""
echo "Para un cluster de lab con 10 pods, 24h:"
echo "  Container Insights: ~$2.40"
echo "  Control plane logs: ~$1-5"
echo "  Total: $3-8 por DÍA solo de observabilidad"
```

### Desactivar para ahorrar

```bash
# Control plane logs (el más fácil de olvidar)
aws eks update-cluster-config \
  --name $CLUSTER_NAME --region $REGION \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":false}]}'

# Container Insights add-on
aws eks delete-addon --cluster-name $CLUSTER_NAME \
  --addon-name amazon-cloudwatch-observability --region $REGION

# ADOT
aws eks delete-addon --cluster-name $CLUSTER_NAME \
  --addon-name adot --region $REGION

# AMP workspace
aws amp delete-workspace --workspace-id $AMP_WORKSPACE_ID --region $REGION

# Log groups huérfanos
aws logs describe-log-groups --log-group-name-prefix "/aws/eks/$CLUSTER_NAME" \
  --region $REGION --query "logGroups[].logGroupName" --output text | \
  xargs -I{} aws logs delete-log-group --log-group-name {} --region $REGION
```

---

## Troubleshooting

| Síntoma                                 | Causa probable                           | Fix                                       |
| --------------------------------------- | ---------------------------------------- | ----------------------------------------- |
| No aparecen métricas en CloudWatch      | Add-on no instalado o pod sin permisos   | Verificar IAM del node role o IRSA        |
| Logs vacíos en CloudWatch               | Fluent Bit no está corriendo             | `kubectl get ds -n amazon-cloudwatch`     |
| Trazas no aparecen en X-Ray             | Collector no configurado o app sin SDK   | Verificar que ADOT collector recibe datos |
| Costos inesperados de CloudWatch        | Control plane logs habilitados con `api` | Desactivar tipos innecesarios             |
| Container Insights muestra datos viejos | Latencia normal (~2-3 min)               | Esperar — no es real-time                 |

---

## 🔴 Destruir recursos del lab

```bash
# Add-ons
aws eks delete-addon --cluster-name $CLUSTER_NAME \
  --addon-name amazon-cloudwatch-observability --region $REGION 2>/dev/null
aws eks delete-addon --cluster-name $CLUSTER_NAME \
  --addon-name adot --region $REGION 2>/dev/null

# Control plane logs
aws eks update-cluster-config --name $CLUSTER_NAME --region $REGION \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":false}]}'

# AMP workspace
aws amp delete-workspace --workspace-id $AMP_WORKSPACE_ID --region $REGION 2>/dev/null

# Namespace
kubectl delete namespace observability 2>/dev/null

# Log groups
for LG in $(aws logs describe-log-groups --log-group-name-prefix "/aws/eks/$CLUSTER_NAME" \
  --region $REGION --query "logGroups[].logGroupName" --output text); do
  aws logs delete-log-group --log-group-name "$LG" --region $REGION
done

# CloudWatch dashboards custom (si creaste alguno)
# aws cloudwatch delete-dashboards --dashboard-names "eks-lab" --region $REGION
```

---

## Lecciones aprendidas

1. **Observabilidad es un costo recurrente, no un setup de una vez.** Los logs
   del control plane, Container Insights, trazas — todo cobra por volumen,
   continuamente. Es el gasto que más sorprende a equipos nuevos en Kubernetes.

2. **SLOs > alertas de threshold.** "CPU al 80%" no te dice si el usuario está
   afectado. "Error budget quemándose a 14x" sí. Un buen SLO reduce alertas
   falsas y mantiene on-call sostenible.

3. **OpenTelemetry es la decisión correcta a largo plazo.** Vendor-neutral
   significa que puedes cambiar de X-Ray a Datadog (o al revés) sin tocar código.
   El costo de instrumentar con un SDK propietario es lock-in permanente.

4. **No habilites `api` logs a menos que sepas que los necesitas.** Es el tipo
   de log con más volumen. Para la mayoría de los equipos, `audit` +
   `authenticator` cubren el 95% de las investigaciones.

5. **Los tres pilares se complementan, no se reemplazan.** Métricas te dicen que
   algo anda mal. Logs te dicen qué pasó. Trazas te dicen por dónde pasó la
   request. Sin uno de los tres, tu diagnóstico tiene huecos.

6. **Apagar la observabilidad es un paso legítimo en un lab.** En producción la
   necesitas. En un lab, esos $3-8/día se acumulan. Siempre revisa qué dejaste
   habilitado cuando terminas de practicar.
