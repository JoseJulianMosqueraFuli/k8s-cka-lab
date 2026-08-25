# Lab 14: Chaos engineering — dos motores de caos comparados (FIS vs Chaos Mesh)

## Resumen

Terraform levanta un sistema completo de un `apply`, y una variable decide **sobre
qué substrato y con qué motor de caos**:

- **Variante A — Auto Mode + AWS FIS:** cluster EKS Auto Mode (Bottlerocket, nodos
  cerrados) + AWS Fault Injection Service. Caos gestionado, inyectado con
  **contenedores efímeros**, sin daemon privilegiado.
- **Variante B — EC2 + Chaos Mesh:** cluster EKS con nodos EC2 gestionados + Chaos
  Mesh. Caos in-cluster, declarativo (CRDs), con un **daemon privilegiado** capaz de
  tocar red y kernel.

La misma app (con cuatro tipos de dependencia) y la misma observabilidad en ambas.
El lab **no es montar, es romper con método y diagnosticar** — guiado, paso a paso,
bajo la teoría del chaos engineering. Y el entregable extra es la **comparación** de
los dos enfoques.

**Se apoya en:** lab 09 (Terraform/IaC), lab 12 (SLOs/observabilidad), lab 06
(storage y HPA), lab 07 (red y DNS), lab 08 (método de diagnóstico), y compara con el
02 (EC2) y el 03 (Auto Mode).

**Costo estimado:** ~$0.40-0.70/hr **por variante**. Se corren **de a una** (destruye
antes de levantar la otra) salvo que quieras pagar dos clusters. Es el lab más caro
del repo. Destrúyelo el mismo día.

**Tiempo:** ~1h de provisión/lectura + ~3h de experimentos por variante.

**Herramientas:** Terraform, AWS CLI v2, kubectl, helm.

**Conexión CKA:** ninguna directa. Esto es **oficio de producción**, no examen.

---

## Las dos variantes: por qué ambas

El motivo no es capricho, es técnico y didáctico.

**El límite técnico:** Chaos Mesh inyecta latencia, pérdida de paquetes y stress a
nivel de kernel con un DaemonSet privilegiado (`chaosDaemon`) que monta el socket del
runtime del nodo. **Auto Mode corre Bottlerocket con los nodos bloqueados**, así que
ese daemon no puede correr ahí. Por eso Auto Mode obliga a otro enfoque.

**La solución gestionada:** AWS FIS resuelve el mismo problema desde afuera. Sus
acciones `aws:eks:pod-*` (latencia de red, pérdida, CPU/mem/IO stress) se inyectan con
**ephemeral containers** dentro del pod objetivo —no con un daemon privilegiado en el
host— así que **sí funcionan en Auto Mode** ([doc oficial FIS EKS pod actions](https://docs.aws.amazon.com/fis/latest/userguide/eks-pod-actions.html)).
La única excepción es `aws:eks:pod-delete`, que no usa contenedor efímero.

### Comparación (el entregable del lab)

|                            | Variante A · Auto Mode + FIS              | Variante B · EC2 + Chaos Mesh                |
| -------------------------- | ----------------------------------------- | -------------------------------------------- |
| Substrato                  | Auto Mode (Bottlerocket, managed)         | Managed Node Group EC2                       |
| Motor de caos              | AWS FIS (servicio gestionado)             | Chaos Mesh (open source, in-cluster)         |
| Cómo inyecta               | Contenedores efímeros + acciones de infra | DaemonSet privilegiado (tc/iptables/nsenter) |
| Privilegios en el nodo     | No requiere                               | Sí (privileged + hostPath al runtime)        |
| Definición del experimento | Template de FIS (consola/API/Terraform)   | CRD de Kubernetes (YAML, GitOps-friendly)    |
| Matar pod                  | `aws:eks:pod-delete`                      | `PodChaos` pod-kill                          |
| Latencia de red            | `aws:eks:pod-network-latency`             | `NetworkChaos` delay                         |
| Stress CPU/mem/IO          | `aws:eks:pod-cpu/memory/io-stress`        | `StressChaos`                                |
| DNS / time chaos           | No (usa lo de abajo o Chaos Mesh)         | `DNSChaos`, `TimeChaos`                      |
| Spot / caída de AZ / EBS   | Sí (acciones de infra nativas)            | No (necesitas FIS igual)                     |
| Aborto automático          | Stop condition con alarma CloudWatch      | `duration` en el CRD                         |
| Dónde vive la definición   | AWS (fuera del cluster)                   | En Git, como manifiestos                     |

La lección: FIS es menos invasivo y llega a la infra (Spot, AZ), pero vive fuera del
cluster; Chaos Mesh es más rico a nivel de kernel/red y declarativo en Git, pero
necesita nodos que le den privilegios. En producción real muchos equipos usan **los
dos**: FIS para infra, Chaos Mesh (o Litmus) para el detalle en el cluster.

> **Nota:** FIS también funciona en la variante EC2. El eje real es: Auto Mode te
> **obliga** a FIS; EC2 te deja usar Chaos Mesh **y** FIS. Por eso la comparación se
> monta como Auto Mode+FIS vs EC2+Chaos Mesh.

---

## Qué vas a construir (igual en ambas variantes)

```
terraform apply -var="substrate=automode"   (o =ec2)
   │
   ├─ VPC (2 AZ, subnets pub/priv, 1 NAT)
   ├─ EKS  ─┬─ substrate=automode → Auto Mode (Karpenter, Bottlerocket)
   │        └─ substrate=ec2      → Managed Node Group EC2
   ├─ Motor de caos ─┬─ automode → FIS experiment templates + IAM role + access entry
   │                 └─ ec2      → Chaos Mesh (helm) + FIS opcional
   ├─ Observabilidad: kube-prometheus-stack (Prometheus + Grafana)  [ambas]
   └─ App "url-shortener" (imágenes en ECR)  [ambas]:
        frontend → bff(Go) → link-service(Go) → Postgres
                            ↘ Redis (cache)
                   redirect → SQS → worker(Go) → Postgres (contadores)
```

El path del **redirect** (buscar un link y responder 301) es el SLI principal: rápido
y arriba pase lo que pase. Todo el lab se mide contra eso.

---

## Estructura Terraform

```
14-chaos-lab/
├── README.md                 (esta guía)
├── terraform/
│   ├── backend.tf            # state en S3 + lock en DynamoDB (patrón del lab 09)
│   ├── versions.tf           # providers: aws, kubernetes, helm
│   ├── variables.tf          # substrate = "automode" | "ec2"  (default: automode)
│   ├── main.tf               # VPC + EKS (terraform-aws-modules) — compartido
│   ├── automode.tf           # count = var.substrate=="automode" ? 1 : 0
│   ├── ec2-nodes.tf          # count = var.substrate=="ec2"      ? 1 : 0
│   ├── chaos-fis.tf          # FIS role + templates (automode; opcional en ec2)
│   ├── chaos-mesh.tf         # helm_release chaos-mesh (solo ec2)
│   ├── monitoring.tf         # kube-prometheus-stack (ambas)
│   ├── app.tf                # ECR + despliegue de la app (ambas)
│   └── outputs.tf            # cluster_name, alb_url, grafana_url, fis_template_ids
├── chaos/
│   ├── fis/                  # JSON de experiment templates (variante A)
│   └── chaos-mesh/           # CRDs de experimentos (variante B)
└── app/                      # código Go de los servicios (+ Dockerfiles)
```

> **Estado:** la guía y el diseño están listos; el código Terraform y de la app se
> generan cuando decidas ejecutar (como hicimos con el lab 04). Pídemelo y lo
> scaffoldeo, empezando por la variante que prefieras.

---

## Paso 0: La teoría en 5 principios

El chaos engineering **no es apagar cosas al azar**. Es un experimento controlado
([Principles of Chaos Engineering](https://principlesofchaos.org/)):

1. **Define el estado estable** con una métrica de negocio (aquí: % de redirects
   exitosos < 300ms).
2. **Formula una hipótesis:** "si mato una réplica de `link-service`, el estado
   estable NO cambia".
3. **Simula eventos reales** (un pod muere, la red se pone lenta, una AZ cae), no
   fantasías.
4. **Minimiza el blast radius:** empieza por el experimento más pequeño y sube de a poco.
5. **Ten aborto automático:** FIS lo hace con stop conditions (alarma CloudWatch);
   Chaos Mesh con `duration`.

La diferencia con el lab 08: allá rompías infra para **practicar diagnóstico**; aquí
rompes con **hipótesis** para **validar la resiliencia** de un sistema real.

---

## Paso 1: Provisionar con Terraform

Elige variante (recuerda: de a una para no pagar dos clusters).

```bash
cd 14-chaos-lab/terraform
terraform init

# Variante A — Auto Mode + FIS
terraform plan -out tfplan -var="substrate=automode"
terraform apply tfplan

# (o) Variante B — EC2 + Chaos Mesh
# terraform plan -out tfplan -var="substrate=ec2"
# terraform apply tfplan

aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region us-east-1
kubectl get nodes
kubectl get pods -A     # app, monitoring, y (en ec2) chaos-mesh
```

> **FIS necesita permisos en el cluster.** Las acciones `aws:eks:pod-*` requieren un
> IAM role para FIS y un **EKS access entry** (o RBAC) que le permita crear
> contenedores efímeros. Terraform lo crea en `chaos-fis.tf`. Sin eso, el experimento
> falla con un error de acceso, no con un fallo de la app — buen detalle para
> reconocer al debuggear.

---

## Paso 2: Medir el estado estable (antes de romper nada)

```bash
ALB=$(kubectl get ingress url-shortener -n apps -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
while true; do curl -s -o /dev/null -w "%{http_code} %{time_total}\n" http://$ALB/r/demo; sleep 0.2; done
```

Abre Grafana (`grafana_url`) y **anota tu línea base:** % de 3xx y latencia p95. Sin
línea base, el caos no dice nada.

---

## Paso 3: Los patrones de resiliencia (ya vienen en la app)

Terraform despliega la app con las defensas puestas (romper una app sin defensas solo
demuestra que se rompe): timeouts en toda llamada, retries con backoff + jitter,
circuit breaker BFF→link-service, graceful shutdown (SIGTERM + `preStop` +
`terminationGracePeriodSeconds`), PDB, `topologySpreadConstraints` entre AZs,
readiness que refleja dependencias, y fallback de cache (Redis abajo ⇒ leer de DB).

En cada experimento el objetivo es ver **cuál defensa se activa** — o descubrir que falta.

---

## Paso 4: La escalera de experimentos (en los dos motores)

Cada experimento: **hipótesis → inyección → qué observar → cómo debuggear → patrón que
lo cierra**. Donde aplica, muestro la forma FIS y la forma Chaos Mesh para comparar.

### Experimento 1 — Matar un pod

**Hipótesis:** matar una réplica de `link-service` no mueve el SLI.

FIS (variante A): acción `aws:eks:pod-delete` con selector por label.
Chaos Mesh (variante B):

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata: { name: kill-link, namespace: apps }
spec:
  action: pod-kill
  mode: one
  selector: { namespaces: [apps], labelSelectors: { app: link-service } }
```

**Debuggear si cae:** ¿PDB? ¿`replicas >= 2`? ¿readiness quitó al pod muerto rápido?
`kubectl get endpoints`, eventos, `describe`.
**Patrón:** réplicas + readiness + PDB.

### Experimento 2 — Latencia entre servicios · el que más enseña

**Hipótesis:** 500ms BFF→link-service no cae en cascada (timeout + circuit breaker).

FIS: `aws:eks:pod-network-latency` (delay 500ms sobre pods `app=bff`), con stop
condition en la alarma del SLI.
Chaos Mesh:

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata: { name: delay-bff-link, namespace: apps }
spec:
  action: delay
  mode: all
  selector: { namespaces: [apps], labelSelectors: { app: bff } }
  direction: to
  target:
    {
      mode: all,
      selector: { namespaces: [apps], labelSelectors: { app: link-service } },
    }
  delay: { latency: "500ms", jitter: "100ms" }
  duration: "3m"
```

**Debuggear:** si el BFF se cuelga, falta/está mal el timeout. Si todo se degrada,
faltó el circuit breaker. **Patrón:** timeout agresivo + circuit breaker + fallback.
**Comparación:** fíjate que FIS lo inyecta metiéndote un contenedor efímero en el pod;
Chaos Mesh lo hace desde su daemon en el nodo. Mismo síntoma, mecanismo distinto.

### Experimento 3 — Redis abajo

**Hipótesis:** con Redis caído el redirect degrada a Postgres pero NO falla.
**Debuggear si devuelve 500:** el código trata el cache como dependencia dura; falta
fallback. **Patrón:** el cache es optimizador, no dependencia crítica.

### Experimento 4 — Matar al worker de analítica

**Hipótesis:** el redirect ni se entera (analítica asíncrona vía SQS).
**Observar:** SLI del redirect intacto; la cola SQS acumulando y drenando al volver el
worker. **Si el redirect cae:** estabas escribiendo la analítica de forma síncrona.

### Experimento 5 — DNS chaos (solo variante B, exclusivo de Chaos Mesh)

**Hipótesis:** romper la resolución DNS produce un síntoma que no parece de red
(conecta con el lab 07). **Debuggear:** `kubectl exec` + `nslookup`, revisar CoreDNS.
En la variante A esto no tiene equivalente directo en FIS: es justo lo que ganas con
Chaos Mesh en EC2.

### Experimento 6 — Spot interruption (FIS, en cualquier variante)

**Hipótesis:** graceful shutdown + PDB salvan los requests en vuelo cuando AWS reclama
un nodo Spot. **Debuggear:** ¿hubo 5xx durante el drenado? Revisa `preStop` y
`terminationGracePeriodSeconds`.

### Experimento 7 — Caída de una AZ (FIS) · la prueba de fuego

**Hipótesis:** el sistema sobrevive perder una AZ. **Aquí aterriza el lab 06:** un EBS
vive en UNA sola AZ; si tu Postgres está ahí y no hay réplica en otra, lo pierdes.
Revela si tu `topologySpreadConstraints` y tu estrategia de datos son reales.

---

## Paso 5: Game day

Corre la escalera con alguien mirando dashboards. El entregable **no** es "rompimos
cosas", es una tabla:

| Experimento | Motor | Hipótesis | ¿Se cumplió? | Debilidad | Patrón/fix |
| ----------- | ----- | --------- | ------------ | --------- | ---------- |

Si además la corres en las dos variantes, agrega una columna de "cómo se sintió el
motor" (facilidad de definir, visibilidad, aborto). Ese contraste es medio lab.

---

## Método de debugging bajo caos

El embudo del lab 08 para cada fallo: (1) síntoma en el SLI, (2) `kubectl get/describe`

- eventos, (3) logs del servicio afectado y del de aguas arriba, (4) métricas/traces,
  (5) API de AWS si es infra, (6) hipótesis → confirmar → aplicar patrón → re-correr.
  La meta es mapear síntoma → capa, no memorizar fixes.

---

## 🔴 Destruir

```bash
cd 14-chaos-lab/terraform
terraform destroy -var="substrate=automode"   # la variante que hayas levantado
../scripts/verify-clean.sh                     # confirma que no quedaron ALBs/ENIs huérfanos
```

> Levanta una variante a la vez. Antes de cambiar de A a B, **destruye** la anterior:
> son dos clusters distintos y dejar los dos prendidos es pagar doble.

---

## Conceptos clave

### FIS vs Chaos Mesh (por qué existen los dos)

FIS es un servicio gestionado de AWS: menos invasivo (contenedores efímeros, sin
privilegios en el nodo), con guardrails y stop conditions, y llega a la infra (Spot,
AZ, EBS). Chaos Mesh es open source e in-cluster: más rico a nivel kernel/red
(DNS, time, IO), declarativo en Git, pero necesita nodos que le den privilegios. No
compiten: cubren capas distintas.

### El precio del lockdown de Auto Mode

Auto Mode te da nodos gestionados y seguros, pero a cambio no puedes correr un daemon
privilegiado. Eso te empuja a caos gestionado (FIS). Es el mismo trade-off de todo
Auto Mode: menos control a cambio de menos operación. La variante EC2 te devuelve el
control (Chaos Mesh completo) a cambio de gestionar nodos.

### Estado estable, error budget y blast radius

El estado estable es tu SLI normal; el error budget es cuánto puedes degradarlo antes
de romper el SLO; el blast radius es el radio del experimento, que empieza mínimo y
sube. Un experimento "pasa" si consume poco budget.

---

## Lecciones aprendidas

1. **Un sistema resiliente no es uno que no falla, es uno que se degrada con gracia.**
2. **Sin estado estable medible, el caos es vandalismo.** El lab 12 es prerrequisito.
3. **El motor de caos depende del substrato:** Auto Mode → FIS; EC2 → FIS + Chaos Mesh.
   La restricción no es un obstáculo, es la lección.
4. **El cache y la analítica deben poder morir sin tumbar el path crítico.**
5. **Un EBS vive en una AZ.** La caída de AZ es donde muchas arquitecturas "multi-AZ"
   descubren que su dato no lo era.
6. **Reproducibilidad = coraje.** Poder recrear todo con `terraform apply` es lo que te
   deja romper sin miedo.
