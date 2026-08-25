# Lab 14: Chaos engineering — Terraform levanta todo, tú lo rompes y lo debuggeas

## Resumen

Terraform provisiona un sistema completo de un solo `apply`: la red, un cluster EKS
con nodos EC2, una app con cuatro tipos de dependencia (síncrona, asíncrona, estado
y caché), las herramientas de caos (Chaos Mesh + AWS FIS) y la observabilidad
(Prometheus + Grafana). A partir de ahí el lab **no es montar, es romper con método
y diagnosticar** — guiado, paso a paso, bajo la teoría del chaos engineering.

A diferencia del resto de labs, este **levanta su propio cluster** (no se monta sobre
el 02 ni el 03), porque el punto es tener un entorno reproducible y desechable que
puedas romper varias veces y recrear con un comando.

**Se apoya en:** lab 09 (Terraform/IaC), lab 12 (SLOs/observabilidad), lab 06
(storage y HPA), lab 07 (red y DNS), lab 08 (método de diagnóstico).

**Costo estimado:** ~$0.40-0.70/hr (EKS $0.10 + 2-3 nodos EC2 + NAT + EBS). Es el lab
más caro del repo. Destrúyelo el mismo día.

**Tiempo:** ~1h de provisión/lectura + ~3h de experimentos.

**Herramientas:** Terraform, AWS CLI v2, kubectl, helm.

**Conexión CKA:** ninguna directa. Esto es **oficio de producción**, no examen. El
CKA no toca caos ni sistemas multi-servicio. Practica aquí lo que el examen asume
que ya sabes operar.

---

## Por qué Terraform levanta todo

En los labs 01-04 montaste a mano para **entender** las piezas. Aquí ya las entiendes;
el aprendizaje está en otra parte (cómo falla el sistema), así que la provisión debe
ser un detalle resuelto, no el lab. Terraform te da:

- **Reproducibilidad:** rompes el cluster a propósito, lo destruyes, y `terraform
  apply` te devuelve exactamente el mismo entorno. Sin esto, un experimento
  destructivo te dejaría reconstruyendo a mano.
- **Estado declarado:** el sistema entero (infra + app + tooling) vive en Git. Es el
  cierre natural del lab 09.
- **Un blast radius conocido:** sabes exactamente qué existe, porque lo declaraste.
  Eso importa cuando vas a inyectar fallos.

---

## Qué vas a construir

```
Terraform apply
   │
   ├─ VPC (2 AZ, subnets pub/priv, 1 NAT)
   ├─ EKS + Managed Node Group (EC2, NO Auto Mode)   ← ver "Decisión de diseño"
   ├─ Add-ons vía Helm:
   │    ├─ Chaos Mesh          (inyección de fallos en el cluster)
   │    └─ kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
   ├─ App "url-shortener" (imágenes en ECR, desplegadas por Terraform):
   │    frontend → bff(Go) → link-service(Go) → Postgres
   │                       ↘ Redis (cache)
   │              redirect → SQS → worker(Go) → Postgres (contadores)
   └─ AWS FIS experiment templates (Spot interruption, caída de AZ)
```

El path del **redirect** (buscar un link y responder 301) es el SLI principal: tiene
que estar rápido y arriba pase lo que pase. Todo el lab se mide contra eso.

---

## Decisión de diseño: nodos EC2, no Auto Mode

Chaos Mesh inyecta fallos de red y de kernel (latencia, pérdida de paquetes, stress
de CPU/IO) con un DaemonSet privilegiado (`chaosDaemon`) que monta el socket del
runtime del nodo. **EKS Auto Mode corre Bottlerocket y restringe pods privilegiados y
`hostPath`**, así que ese tipo de experimentos no funciona ahí.

Por eso este lab usa un **Managed Node Group con EC2** (como el lab 02):

| Chaos                                  | ¿Funciona en Auto Mode? | ¿Funciona en EC2 managed? |
| -------------------------------------- | ----------------------- | ------------------------- |
| `PodChaos` (pod-kill) — vía API        | Sí                      | Sí                        |
| `NetworkChaos` (latencia, pérdida)     | No (daemon privilegiado) | Sí                        |
| `StressChaos` (CPU/mem/IO)             | No                      | Sí                        |
| `DNSChaos`                             | No                      | Sí                        |
| AWS FIS (Spot, AZ, API throttling)     | Sí                      | Sí                        |

> Si prefieres Auto Mode por otra razón, el lab sigue teniendo valor: te limitas a
> `PodChaos` vía API + todo lo de FIS, y saltas los experimentos de red/kernel.

---

## Estructura Terraform

```
14-chaos-lab/
├── README.md            (esta guía)
├── terraform/
│   ├── backend.tf       # state en S3 + lock en DynamoDB (patrón del lab 09)
│   ├── versions.tf      # required_providers: aws, kubernetes, helm
│   ├── main.tf          # VPC + EKS (terraform-aws-modules)
│   ├── nodes.tf         # managed node group EC2
│   ├── addons.tf        # helm_release: chaos-mesh, kube-prometheus-stack
│   ├── app.tf           # ECR + despliegue de la app (helm/manifests)
│   ├── fis.tf           # aws_fis_experiment_template (Spot, AZ)
│   ├── variables.tf
│   └── outputs.tf       # kubeconfig, URL del ALB, URL de Grafana
├── chaos/               # experimentos declarativos, en escalera
│   ├── 01-pod-kill.yaml
│   ├── 02-network-delay.yaml
│   ├── 03-redis-down.yaml
│   ├── 04-kill-worker.yaml
│   ├── 05-dns-chaos.yaml
│   └── fis-spot.json · fis-az.json
└── app/                 # código Go de los servicios (+ Dockerfiles)
```

> **Estado:** la guía y el diseño están listos; el código Terraform y de la app se
> generan cuando decidas ejecutar el lab (igual que hicimos con el lab 04). Pídemelo
> y lo scaffoldeo.

---

## Paso 0: La teoría en 5 principios

El chaos engineering **no es apagar cosas al azar**. Es un experimento controlado
([Principles of Chaos Engineering](https://principlesofchaos.org/)):

1. **Define el estado estable** con una métrica de negocio (aquí: % de redirects
   exitosos < 300ms). Si no lo mides, no sabes si rompiste algo.
2. **Formula una hipótesis:** "si mato una réplica de `link-service`, el estado
   estable NO cambia".
3. **Vary real-world events:** simula fallos que pasan de verdad (un pod muere, la red
   se pone lenta, una AZ cae), no fantasías.
4. **Minimiza el blast radius:** empieza por el experimento más pequeño y en el
   entorno más contenido. Sube de a poco.
5. **Ten una condición de aborto automática:** si el SLI se desploma, el experimento
   se detiene solo (Chaos Mesh tiene `duration`; FIS tiene stop conditions con
   alarmas de CloudWatch).

La diferencia con el lab 08: allá rompías infra para **practicar diagnóstico**; aquí
rompes con **hipótesis** para **validar la resiliencia** de un sistema real.

---

## Paso 1: Provisionar con Terraform

```bash
cd 14-chaos-lab/terraform

# State remoto (una vez): crea el bucket S3 y la tabla DynamoDB del lab 09,
# o reutilízalos. Configúralos en backend.tf.
terraform init

# Revisa SIEMPRE el plan antes de aplicar
terraform plan -out tfplan

# Levanta todo (~15-20 min: EKS tarda)
terraform apply tfplan

# Conecta kubectl con el output
aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region us-east-1
kubectl get nodes
```

Verifica que todo esté arriba:

```bash
kubectl get pods -A            # app, chaos-mesh, monitoring
kubectl get ingress -n apps    # URL del ALB de la app
```

---

## Paso 2: Medir el estado estable (antes de romper nada)

Abre Grafana (output `grafana_url`) y confirma el dashboard del SLI:

```bash
# Genera tráfico base contra el redirect (deja esto corriendo en otra pestaña)
ALB=$(kubectl get ingress url-shortener -n apps -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
while true; do curl -s -o /dev/null -w "%{http_code} %{time_total}\n" http://$ALB/r/demo; sleep 0.2; done
```

**Anota tu línea base:** % de 3xx exitosos y latencia p95. Ese número es contra lo que
vas a comparar cada experimento. Sin línea base, el caos no dice nada.

---

## Paso 3: Los patrones de resiliencia (ya vienen en la app)

Terraform despliega la app con las defensas puestas, porque romper una app sin
defensas solo demuestra que se rompe. Vienen:

- **Timeouts** en toda llamada de red (nunca infinito).
- **Retries con backoff + jitter** entre servicios.
- **Circuit breaker** en el BFF hacia `link-service`.
- **Graceful shutdown:** manejo de SIGTERM + `preStop` + `terminationGracePeriodSeconds`.
- **PodDisruptionBudget** y **topologySpreadConstraints** entre AZs.
- **Readiness** que refleja dependencias; **liveness** que solo reinicia si está colgado.
- **Fallback de cache:** Redis abajo ⇒ leer de Postgres, no devolver 500.

En cada experimento, el objetivo es ver **cuál de estas defensas se activa** — o
descubrir que falta una.

---

## Paso 4: La escalera de experimentos

Cada experimento tiene el mismo formato: **hipótesis → inyección → qué observar →
cómo debuggear → el patrón que lo cierra**. Yo te guío en vivo por cada uno.

### Experimento 1 — Matar un pod (`PodChaos`)

**Hipótesis:** matar una réplica de `link-service` no mueve el SLI.

```yaml
# chaos/01-pod-kill.yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata: { name: kill-link, namespace: apps }
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces: [apps]
    labelSelectors: { app: link-service }
```

**Observar:** el SLI en Grafana; `kubectl get pods -n apps -w`.
**Debuggear si cae:** ¿había PDB? ¿`replicas >= 2`? ¿el Service quitó al pod muerto
rápido (readiness)? `kubectl describe pod`, eventos, `kubectl get endpoints`.
**Patrón:** réplicas + readiness + PDB.

### Experimento 2 — Latencia entre servicios (`NetworkChaos`) · el que más enseña

**Hipótesis:** 500ms de latencia BFF→link-service no cae en cascada porque hay
timeout + circuit breaker.

```yaml
# chaos/02-network-delay.yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata: { name: delay-bff-link, namespace: apps }
spec:
  action: delay
  mode: all
  selector: { namespaces: [apps], labelSelectors: { app: bff } }
  direction: to
  target:
    mode: all
    selector: { namespaces: [apps], labelSelectors: { app: link-service } }
  delay: { latency: "500ms", jitter: "100ms" }
  duration: "3m"
```

**Observar:** latencia p95 del redirect, tasa de error, estado del circuit breaker.
**Debuggear:** si el BFF se cuelga esperando, el timeout está mal o no existe. Si todo
se degrada, faltó el circuit breaker (el BFF sigue martillando a un backend lento).
**Patrón:** timeout agresivo + circuit breaker + fallback.

### Experimento 3 — Redis abajo

**Hipótesis:** con Redis caído, el redirect degrada a Postgres (más lento) pero NO
falla.

**Inyección:** `PodChaos` pod-kill sobre Redis, o escalar su Deployment a 0.
**Debuggear si devuelve 500:** el código no tenía fallback; trata el cache como
dependencia dura. `kubectl logs` del BFF mostrará el error de conexión no capturado.
**Patrón:** el cache es un optimizador, no una dependencia crítica.

### Experimento 4 — Matar al worker de analítica

**Hipótesis:** el redirect ni se entera (la analítica es asíncrona vía SQS).

**Observar:** el SLI del redirect intacto; la cola de SQS acumulando mensajes.
**La lección:** cuando el worker vuelve, procesa el backlog. Eso es desacople real.
**Debuggear si el redirect SÍ cae:** entonces el redirect estaba escribiendo la
analítica de forma síncrona — acoplamiento que hay que romper.

### Experimento 5 — DNS chaos (`DNSChaos`)

**Hipótesis:** conecta con el lab 07. Romper la resolución DNS produce un síntoma que
no parece de red.

**Observar:** errores tipo "no such host" en los logs; nada obvio en CPU/memoria.
**Debuggear:** el método del lab 08 — `kubectl exec` + `nslookup`, revisar CoreDNS.

### Experimento 6 — Spot interruption (AWS FIS)

**Hipótesis:** graceful shutdown + PDB salvan los requests en vuelo cuando AWS
reclama un nodo Spot (2 min de aviso).
**Inyección:** experiment template de FIS `aws:ec2:send-spot-instance-interruptions`.
**Debuggear:** ¿hubo 5xx durante el drenado? Revisa `preStop` y
`terminationGracePeriodSeconds`.

### Experimento 7 — Caída de una AZ (AWS FIS) · la prueba de fuego

**Hipótesis:** el sistema sobrevive perder una AZ completa.
**Aquí aterriza el lab 06:** un volumen EBS vive en UNA sola AZ. Si tu Postgres está
en la AZ que cae y no hay réplica en otra, lo pierdes. Este experimento revela si tu
`topologySpreadConstraints` y tu estrategia de datos son reales o decorativas.

---

## Paso 5: Game day

Corre la escalera con alguien más mirando los dashboards. El entregable **no** es
"rompimos cosas"; es una tabla de:

| Experimento | Hipótesis | ¿Se cumplió? | Debilidad encontrada | Patrón/fix aplicado |
| ----------- | --------- | ------------ | -------------------- | ------------------- |

Un game day sin hallazgos suele significar que los experimentos fueron demasiado
tímidos, no que el sistema sea perfecto.

---

## Método de debugging bajo caos (lo que practicamos juntos)

Para cada fallo, el mismo embudo del lab 08:

1. **Síntoma** en el SLI/dashboard (¿qué se degradó?).
2. **`kubectl get/describe` + eventos** (¿qué cambió de estado?).
3. **Logs del servicio afectado y del de aguas arriba** (¿quién falló primero?).
4. **Métricas/traces** (¿dónde se fue el tiempo, dónde subió el error?).
5. **API de AWS** si es infra (target groups, nodos, AZ).
6. **Hipótesis de causa → confirmar → aplicar patrón → re-correr el experimento.**

La meta es reconocer el síntoma y mapearlo a la capa, no memorizar fixes.

---

## (Opcional) Service mesh

Un mesh (Istio/Linkerd) daría inyección de fallos, reintentos y circuit breaking a
nivel de infraestructura, más mTLS y telemetría. Es pesado y, como dice
[vacíos conscientes](../readme.md#vacíos-conscientes), el 07+09 cubren el 80% con
menos piezas. Entra aquí solo para contrastar "resiliencia en el código" vs
"resiliencia en el mesh".

---

## 🔴 Destruir

Todo lo levantó Terraform, así que se va con un comando:

```bash
cd 14-chaos-lab/terraform
terraform destroy
```

> Como en Auto Mode con eksctl, verifica después que no quedaron ALBs huérfanos
> creados por el Ingress (Terraform no siempre los captura si los creó un controller
> dentro del cluster). Corre `../scripts/verify-clean.sh`.

---

## Conceptos clave

### Chaos engineering vs testing

El testing verifica lo que **anticipaste** (asserts sobre casos conocidos). El chaos
descubre lo que **no** anticipaste, en un sistema real, bajo condiciones reales. Son
complementarios: los tests protegen la lógica; el caos protege la operación.

### Estado estable y error budget

El estado estable es tu SLI en condiciones normales. El error budget es cuánto puedes
degradarlo antes de romper el SLO. Un experimento de caos "pasa" si consume poco o
nada del budget. Alertar sobre agotamiento de budget (lab 12) es lo que hace esto
medible.

### Blast radius

El radio de impacto de un experimento. Empiezas mínimo (un pod, un servicio, con
`duration` corta y aborto automático) y subes solo cuando el peldaño anterior no
reveló nada. Nunca empiezas por "tirar una AZ".

---

## Lecciones aprendidas

1. **Un sistema resiliente no es uno que no falla, es uno que se degrada con gracia.**
   El caos mide la gracia, no la ausencia de fallas.
2. **Sin estado estable medible, el caos es vandalismo.** El lab 12 es prerrequisito
   de verdad, no una sugerencia.
3. **El cache y la analítica deben poder morir sin tumbar el path crítico.** Si no
   pueden, están acoplados y el experimento lo revela en segundos.
4. **Un EBS vive en una AZ.** La caída de AZ es donde la mayoría de arquitecturas
   "multi-AZ" descubren que su dato no lo era.
5. **Reproducibilidad = coraje.** Poder recrear todo con `terraform apply` es lo que
   te permite romper sin miedo. Ese es el punto de levantarlo con IaC.
