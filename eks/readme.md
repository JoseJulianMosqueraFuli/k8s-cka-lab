# Labs de EKS — de lo básico a lo específico

Ruta de práctica para entender EKS por capas, en tres niveles: **fundamentos**
(levantar un cluster), **operación** (mantenerlo vivo) y **producción** (operarlo
en equipo sin tocarlo a mano). Los labs 01-04 están hechos y verificados; del 05
al 13 están diseñados como guías completas en el [roadmap](#roadmap).

> Los labs son **guías, no manifiestos**: los archivos (manifests, políticas,
> Terraform, código Go) se escriben siguiendo los pasos del README. Los únicos
> archivos que se entregan son los `destroy.sh`/`destroy.ps1` de cada lab.

Cada lab de nivel 1 levanta un cluster desde la consola de AWS, despliega nginx
expuesto a internet, y lo destruye. La diferencia entre ellos es **quién gestiona
el cómputo y qué tienes que instalar tú**.

> Antes de tomar estos labs como referencia de cómo se opera EKS en producción, lee
> [Alcance y límites](#alcance-y-límites-esto-es-un-lab-no-producción). La mecánica
> es correcta; el proceso no es el de un ambiente productivo, y es a propósito.

## Nivel 1 · Fundamentos — orden propuesto

| #   | Lab                                        | Qué aprendes                                                            | Por qué va en esta posición                                                                                          |
| --- | ------------------------------------------ | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| 1   | [`eks-fargate-lab`](01-eks-fargate-lab/)   | Fargate profiles, IRSA + OIDC, AWS Load Balancer Controller con Helm    | Es el que más piezas te obliga a montar a mano. Aquí ves _por qué_ existe cada componente                            |
| 2   | [`eks-ec2-lab`](02-eks-ec2-lab/)           | Managed Node Groups, kube-proxy, cloud-controller-manager, AMIs, sizing | Después de pelear con Fargate, aprecias que un `Service` tipo LoadBalancer funcione sin instalar nada                |
| 3   | [`eks-automode-lab`](03-eks-automode-lab/) | Auto Mode, NodePools, Karpenter, controllers integrados                 | Cierra la ruta: AWS te quita de encima todo lo de los labs 1 y 2. Solo entiendes el valor si antes lo hiciste a mano |
| 4   | [`ingress-lab`](04-ingress-lab/)           | Ingress + ALB, HTTPS con ACM, imagen propia en ECR                      | Los tres primeros paran en NLB capa 4 con una imagen pública. Esto es cómo se expone una app de verdad               |

La lógica de los primeros tres es **fricción decreciente**: empiezas donde tienes
que ensamblar todo y terminas donde no ensamblas nada. Los READMEs se referencian
entre sí en ese orden (el de EC2 compara contra Fargate, el de Auto Mode contra
los dos). El 04 cierra el nivel con el patrón de exposición que sí se usa en
producción.

> Si tu objetivo es solo "tener un cluster corriendo hoy", el orden inverso es más
> rápido. Este orden está optimizado para aprender, no para llegar rápido.

## Tiempos y costo

"Manos" es tiempo tecleando. "Espera" es AWS provisionando, y no se puede comprimir.

| Lab           | Manos   | Espera  | Build   | Destroy   | Total       | Costo/hr    |
| ------------- | ------- | ------- | ------- | --------- | ----------- | ----------- |
| 1 · Fargate   | ~60 min | ~30 min | ~1h 30m | 35-45 min | **~2h 15m** | ~$0.15      |
| 2 · EC2       | ~35 min | ~20 min | ~55 min | 25-35 min | **~1h 30m** | ~$0.20      |
| 3 · Auto Mode | ~40 min | ~25 min | ~1h 5m  | 25-30 min | **~1h 35m** | ~$0.15-0.25 |

Los tres seguidos: **~5h 30m** de reloj, **$1-2** en total si los destruyes al
terminar cada uno. Si los dejas los tres prendidos en paralelo, ~$0.55/hr.

En Fargate el tiempo se va casi todo en el bloque de OIDC + IAM policy +
`eksctl create iamserviceaccount` (que crea un stack de CloudFormation) + Helm.
Son 20-30 minutos que los otros dos labs no tienen.

## Dónde ejecutar cada cosa

**Los labs no se pueden completar solo desde la consola.** Desde el paso 6 en
adelante todo es `kubectl`. La consola cubre IAM, VPC, cluster y node groups.

| Entorno               | Setup                                            | Cuándo usarlo                                                                                                                                                                                                                                                                                          |
| --------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Consola AWS**       | 0                                                | Crear IAM, VPC, cluster, node groups y Fargate profiles. Es donde ves los campos y entiendes qué configura cada uno                                                                                                                                                                                    |
| **CloudShell**        | 0 para `kubectl`, 5-8 min para `eksctl` + `helm` | Plan B y atajo. El botón **Connect** en la página del cluster abre una sesión con `kubectl` ya configurado, con el mismo principal IAM de la consola — te salta el paso del Access Entry. Ojo: expira por inactividad (~20-30 min) y solo persiste `$HOME` (1 GB), así que instala binarios en `~/bin` |
| **Tu terminal (WSL)** | 20-30 min una vez                                | Lo recomendado. Persistente, rápido, y es el mismo entorno que usas para los ejercicios de `domains/`                                                                                                                                                                                                  |

### Setup en WSL

```bash
# AWS CLI v2
curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install --update

# kubectl
curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# eksctl (solo lo necesita el lab 1)
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" \
  | tar xz -C /tmp && sudo mv /tmp/eksctl /usr/local/bin/

# helm (solo lo necesita el lab 1)
curl -sL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

aws configure          # región: us-east-1
aws sts get-caller-identity
```

Notas de credenciales:

- Si además usas la consola, revisa que `aws sts get-caller-identity` te devuelva
  el **mismo** principal con el que creaste el cluster. Si no, necesitas el Access
  Entry con `AmazonEKSClusterAdminPolicy` (paso 4 de cada lab).
- El `iam_policy.json` que descarga el lab 1 se guarda donde estés parado. Los
  READMEs traen el comando en PowerShell; en bash es
  `curl -sLo iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json`.

## Versión de Kubernetes: no la hardcodees

Los READMEs de los labs mencionan `1.36`. Ese número envejece solo. En vez de
copiarlo, consulta qué hay disponible el día que corras el lab:

```bash
# Todas las versiones ofrecidas, con su fecha de fin de soporte estándar
aws eks describe-cluster-versions --region us-east-1 \
  --query 'clusterVersions[].[clusterVersion,clusterVersionStatus,endOfStandardSupportDate]' \
  --output table

# Solo la más reciente
aws eks describe-cluster-versions --region us-east-1 \
  --query 'clusterVersions[].clusterVersion' --output text \
  | tr '\t' '\n' | sort -Vr | head -1
```

Reglas prácticas:

- **Labs 1, 2 y 3:** usa la más reciente en soporte estándar. Es lo que AWS
  recomienda para clusters nuevos.
- **El lab de upgrade (roadmap 10):** crea el cluster una versión **atrás** a
  propósito. Si arrancas en la más nueva no tienes a dónde subir.
- EKS solo permite subir de una minor en una minor. No se puede salvar 1.34 → 1.36
  en un paso.
- Cuidado con **extended support**: una versión fuera de soporte estándar cuesta
  $0.60/hr de control plane en vez de $0.10. Seis veces más, por descuido.

Referencia: [ciclo de vida de versiones en EKS](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html).

## Por qué cada lab tiene su propia VPC y su propio NAT

Es una decisión consciente: **los labs son independientes**. Cada uno se puede
hacer, romper y destruir sin tocar los otros, y el destroy no tiene que preguntarse
si algo más está usando la red.

El costo de esa independencia es el NAT Gateway: **$0.045/hr, ~$32/mes si se te
queda prendido**. Es el recurso más caro que dejarías olvidado, más que el propio
control plane. Dos consecuencias:

- No corras los tres labs en paralelo sin razón. Son 3 NAT = $0.135/hr solo en red.
- Corre `scripts/verify-clean.sh` al terminar. Siempre.

### VPC Gateway Endpoint para S3: gratis y baja el tráfico del NAT

Al crear la VPC con el wizard, agrega el **Gateway Endpoint de S3** (tipo
`com.amazonaws.region.s3`). No cobra por hora ni por GB — es una tabla de rutas,
no un servicio de pago — y hace que el tráfico a ECR/S3 (jalar imágenes, push)
salga por la ruta privada directa en vez de rebotar por el NAT. Es la forma más
barata de quitarle carga al recurso más caro de la VPC. Lo retoma el lab 13 como
fix de costo.

## Scripts

```
eks/
├── scripts/
│   ├── eks-teardown-lib.sh    # funciones compartidas de teardown
│   └── verify-clean.sh        # auditoría post-destroy: ¿quedó algo cobrando?
├── proposals/
│   └── 01-tagging-and-cleanup.md
├── references/
│   └── eks-vs-ecs.md
├── 01-eks-fargate-lab/   destroy.ps1 · destroy.sh
├── 02-eks-ec2-lab/       destroy.ps1 · destroy.sh
├── 03-eks-automode-lab/  destroy.ps1 · destroy.sh
└── 04-ingress-lab/ … 13-finops-lab/
    (cada lab del 04 al 13 trae su propio destroy.ps1 · destroy.sh)
```

Los `.ps1` son los originales (PowerShell). Los `.sh` son la versión para
bash/WSL/CloudShell, con tres diferencias que importan:

1. **Borran la VPC completa.** Los `.ps1` la dejan como paso manual en la consola,
   y ese clic falla igual porque EKS deja ENIs y security groups huérfanos que
   bloquean el borrado. El `.sh` los barre primero.
2. **Descubren recursos por relación, no por nombre.** El VPC ID sale de
   `describe-cluster`; los `AllocationId` de las Elastic IP salen del propio NAT
   Gateway antes de borrarlo. Sin filtros `tag:Name` con comodines.
3. **Sueltan las IAM policies que estén adjuntas**, en vez de una lista de ARNs
   hardcodeada que se desincroniza si agregaste permisos.

Primera vez:

```bash
chmod +x eks/scripts/*.sh eks/*/destroy.sh
```

Uso:

```bash
cd eks/eks-fargate-lab && ./destroy.sh      # pide confirmación
./destroy.sh --yes                          # sin preguntar
../scripts/verify-clean.sh                  # exit 0 = limpio, exit 1 = queda algo
```

`verify-clean.sh` no borra nada. Revisa clusters, instancias, NAT, EIPs sin
asociar, load balancers, target groups huérfanos, ENIs disponibles, volúmenes EBS
sin adjuntar, log groups, roles IAM, OIDC providers y stacks de eksctl. Estima el
costo por hora de lo que encuentre para que sepas si urge.

## Antes de empezar: red de seguridad de costos

1. **Budget con alerta.** Billing → Budgets → $10 mensual, alerta al 50% y al 80%.
   Son 3 minutos y es lo único que te avisa si algo se quedó prendido una semana.
2. **Fija la región.** `export AWS_REGION=us-east-1` en tu `~/.bashrc`. Recursos
   olvidados en otra región no aparecen en el `verify-clean.sh` de esta.
3. **Pon un timer.** Cuando la creación del cluster te diga "~10 min", ese es el
   momento de leer el siguiente paso del README, no de irte.
4. **Destruye el mismo día.** Un cluster olvidado un fin de semana son ~$8.

## Roadmap

Los labs se organizan en tres niveles. Cada uno responde una pregunta distinta, y
el salto entre niveles importa más que los labs individuales.

| Nivel                     | Labs  | Pregunta                                      | Estado                           |
| ------------------------- | ----- | --------------------------------------------- | -------------------------------- |
| **1 · Fundamentos**       | 01-04 | ¿cómo levanto un cluster y expongo una app?   | 01-04 ✅ · 05-13 📋 guías listas |
| **2 · Operación (día 2)** | 05-08 | ¿cómo lo mantengo vivo?                       | 📋 guías listas                  |
| **3 · Producción**        | 09-13 | ¿cómo lo operamos varios, sin tocarlo a mano? | 📋 guías listas                  |

El nivel 3 es el que separa "sé usar EKS" de "sé operar EKS en producción con un
equipo". No cambia la tecnología, cambia el proceso.

Cada nivel tiene un lab que cierra su hueco más grande: el **04** (exponer de
verdad), el **07** (red y aislamiento) y el **13** (costo). Lo que queda fuera a
propósito está en [vacíos conscientes](#vacíos-conscientes).

---

## Nivel 1 · Fundamentos — guías

### 04 · Exponer de verdad — Ingress, HTTPS y tu propia imagen

**Pregunta:** ¿cómo se publica una app real, no un nginx de demo?

Este era el hueco más grande del nivel 1. Los tres labs actuales terminan con un
`Service` tipo LoadBalancer en capa 4, sirviendo HTTP plano, con una imagen pública
de Docker Hub. Nada de eso pasa en producción.

- **Ingress + ALB** en vez de Service/NLB: `ingressClassName: alb`, routing por
  path (`/api`, `/web`) y por host, un solo ALB para varios servicios. Entender que
  un Ingress es capa 7 y por eso puede hacer lo que el NLB no.
- **HTTPS con ACM:** certificado validado por DNS, anotación
  `alb.ingress.kubernetes.io/certificate-arn`, redirect de HTTP a HTTPS. Sin TLS no
  hay producción.
- **Tu propia imagen en ECR:** construirla, etiquetarla con el SHA del commit o un
  digest (nunca `:latest`), empujarla, y que el cluster la baje del registry
  privado. Aquí por fin se usa el permiso de ECR del node role que en los labs 1-3
  estaba configurado pero nunca se ejercitaba.
- **Por qué importa el registry privado:** Docker Hub tiene rate limits. Un cluster
  que escala y jala `nginx:alpine` de Docker Hub falla con `ImagePullBackOff` justo
  cuando más nodos necesitas. Es un incidente clásico.
- **Health checks:** readiness y liveness probes conectadas al health check del
  target group, y ver la diferencia entre "el pod arrancó" y "el pod puede recibir
  tráfico".

Se monta sobre el cluster del lab 2 o 3. Conecta con `domains/03-services-networking`
(20% del CKA). **~2h.**

---

## Nivel 2 · Operación (día 2)

El nivel 1 cubre "levantar un cluster y exponer una app". Estos cuatro cubren lo
que viene después. Cada uno agrupa varios temas alrededor de una pregunta, para que
no sean recetas sueltas.

### 05 · Identidad y permisos — IRSA vs EKS Pod Identity

**Pregunta:** ¿cómo obtiene credenciales de AWS un pod, y cómo obtiene acceso al
cluster una persona?

- Un pod que lee un objeto de S3, hecho de las dos formas: **IRSA** (OIDC +
  trust policy con condición `sub`) y **EKS Pod Identity** (el add-on nuevo, sin
  OIDC, asociación directa ServiceAccount → rol).
- Comparar lado a lado: qué escribes, qué se rompe, qué es más fácil de auditar.
- Least privilege real: la policy limitada a un bucket y un prefijo, no `s3:*`.
- El lado humano: Access Entries y access policies de EKS, y por qué el
  `aws-auth` ConfigMap ya no es el camino.
- **Rompes cosas a propósito:** trust policy con el `sub` mal escrito, y un pod
  sin ServiceAccount asignado. Aprender a leer el error de `AccessDenied` de STS
  es la mitad del lab.

Se monta sobre el cluster del lab 2 (EC2). Reutiliza lo que ya sabes de OIDC del
lab 1. **~1h 30m.**

### 06 · Estado y escala — storage persistente, autoscaling y backup

**Pregunta:** ¿qué pasa cuando la app tiene estado y el tráfico sube?

- **EBS CSI** con un StatefulSet: descubrir que un PVC de EBS ata el pod a una AZ,
  y qué significa eso para la disponibilidad (`WaitForFirstConsumer`,
  `volumeBindingMode`, topología).
- **EFS CSI** con `ReadWriteMany`: el mismo volumen montado por pods en AZs
  distintas, y el costo/latencia de esa comodidad.
- **metrics-server + HPA** con un generador de carga real, no `kubectl scale`.
  Ver la cadena completa: carga → métricas → HPA crea pods → pods en Pending →
  el autoscaler de nodos reacciona.
- **Karpenter consolidando:** bajar la carga y ver cómo apaga nodos, con un PDB
  puesto para que no rompa nada al hacerlo.
- `reclaimPolicy` y por qué un `kubectl delete pvc` mal hecho te deja volúmenes EBS
  cobrando (esto ya está mitigado en `eks-automode-lab/destroy.sh`).
- **Backup con Velero, y un restore de verdad.** Un backup que nunca se restauró no
  es un backup, es una suposición. El lab borra el namespace completo a propósito y
  lo recupera: manifests y volúmenes. Aquí también se ve la diferencia entre un
  snapshot de EBS (bloque, ata la AZ) y un backup lógico (portable entre clusters),
  y por qué eso decide si puedes recuperarte en otra región.

Se monta sobre el cluster del lab 3 (Auto Mode), que ya trae EBS CSI y Karpenter.
Conecta directo con `domains/04-storage` y `domains/02-workloads`. **~2h 30m.**

### 07 · Red y aislamiento — quién habla con quién

**Pregunta:** dentro del cluster todo se ve entre sí. ¿cómo se pone un límite?

Por defecto, en Kubernetes **cualquier pod puede hablar con cualquier pod**, en
cualquier namespace. Es el hallazgo que más sorprende a quien viene de VMs con
security groups, y no se toca en ningún lab anterior.

- **NetworkPolicy default-deny** por namespace, y después abrir solo lo necesario.
  Comprobarlo con un pod de pruebas: antes llega, después no. En el lab 11 Kyverno
  las **genera** solas; aquí las escribes a mano para entender qué generan.
- **Cómo se implementan en EKS:** el VPC CNI las soporta de forma nativa desde
  1.25, sin instalar Calico ni Cilium. Vale saber qué límites tiene esa
  implementación frente a un CNI completo.
- **Service discovery y CoreDNS:** el FQDN
  `servicio.namespace.svc.cluster.local`, qué resuelve y qué no, y por qué un
  `nslookup` fallido es el síntoma más común de un problema de red.
- **VPC CNI e IPs:** cada pod consume una IP real del VPC. Contar cuántos pods caben
  por tipo de instancia, y usar **prefix delegation** para multiplicar esa densidad.
  Esta es la raíz del "pods en Pending sin razón" del lab 08.
- **Security groups para pods:** cuando un pod necesita hablar con un RDS que solo
  acepta un SG específico. Es el puente entre el mundo Kubernetes y el mundo VPC.
- **Aislamiento por equipo:** `ResourceQuota` y `LimitRange` para que un namespace
  no se coma el cluster, más RBAC por equipo. El namespace como frontera real, no
  como carpeta decorativa.

`domains/03-services-networking` es 20% del CKA y las NetworkPolicies salen en el
examen. **~2h 30m.**

### 08 · Troubleshooting — romper a propósito y diagnosticar

**Pregunta:** algo no funciona y el error no dice qué. ¿cómo llego a la causa?

Cada escenario se rompe a propósito y produce un síntoma **distinto**, para que
aprendas a mapear síntoma → capa donde buscar:

| Rompemos                                        | Síntoma que ves                                              | Capa                    |
| ----------------------------------------------- | ------------------------------------------------------------ | ----------------------- |
| Subnet pública sin tag `kubernetes.io/role/elb` | El Service queda en `<pending>` para siempre                 | AWS / tags              |
| Security group del nodo bloquea el health check | LB creado, targets `unhealthy`, 503                          | AWS / red               |
| Access Entry faltante                           | `the server has asked for the client to provide credentials` | IAM / autenticación     |
| CIDR de subnet agotado                          | Pods en `Pending`, sin mensaje claro de por qué              | VPC CNI / IPs           |
| Add-on con versión incompatible                 | CoreDNS en `CrashLoopBackOff` tras un upgrade                | Add-ons                 |
| PDB demasiado estricto                          | `kubectl drain` colgado indefinidamente                      | Kubernetes / scheduling |
| Request de recursos imposible                   | `0/2 nodes are available: insufficient cpu`                  | Scheduling              |

Método, no recetas: `kubectl describe` → eventos → logs del componente →
CloudWatch → API de AWS. El objetivo es reconocer el síntoma, no memorizar el fix.

Para este lab conviene un cluster desechable: un `cluster.yaml` de `eksctl` que lo
levante en un comando, porque lo vas a romper varias veces. `domains/05-troubleshooting`
es 30% del CKA. **~2h 30m.**

---

## Nivel 3 · Producción

Aquí no cambia la tecnología, cambia **quién hace las cosas y cómo**. Estos cinco
labs son los que te dan el vocabulario para operar con un equipo distribuido: si
tres personas en tres husos horarios tocan el mismo cluster, la única forma de que
no se pisen es que el estado deseado viva en Git y nadie tenga que preguntar.

### 09 · Infraestructura como código + GitOps + entrega

**Pregunta:** ¿cómo dejamos de tocar la consola sin perder el control?

Dos mitades que se suelen confundir y no son lo mismo:

- **La infra (el cluster) con IaC.** El mismo cluster de los labs 1-3, pero
  declarado. Comparar las dos opciones reales:

  | Herramienta                                 | Cuándo gana                                                                                           | Límite                                                             |
  | ------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
  | **eksctl** (`cluster.yaml`)                 | Rápido, específico de EKS, ideal para clusters desechables y para el lab 08                           | Solo gestiona EKS. Tu RDS, S3 y Route 53 quedan fuera              |
  | **Terraform** (`terraform-aws-modules/eks`) | Todo tu stack en un solo lenguaje y un solo state. Es lo que usan la mayoría de equipos en producción | Más ceremonia: state remoto, locking, y hay que entender el módulo |

  El lab hace las dos, en ese orden. `eksctl` primero para ver que "declarativo"
  no es magia; Terraform después con state en S3 + locking, `plan` antes de
  `apply`, y el `plan` revisado en un PR.

- **Las apps con GitOps.** Argo CD (o Flux) sincronizando desde un repo. El
  momento que enseña el lab: haces `kubectl scale` a mano y ves cómo Argo lo
  revierte solo. Ahí entiendes qué significa "Git es la fuente de verdad" y por
  qué el drift deja de ser un problema invisible.

- **La entrega de la app.** GitOps resuelve "qué está desplegado", no "cómo llegó
  ahí". El pipeline completo: build → test → escaneo de la imagen → push a ECR con
  el SHA del commit → actualizar el manifest → Argo sincroniza. Aquí se ve por qué
  el `:latest` del lab 04 era mala idea: sin tag inmutable, GitOps no puede
  detectar que hubo un cambio.
- **Progressive delivery:** Argo Rollouts o Flagger para un canary de verdad — 10%
  del tráfico a la versión nueva, métricas evaluadas automáticamente, rollback si
  el error rate sube. Es lo que hace que desplegar deje de dar miedo.

- **El cierre:** un cambio de principio a fin. PR → review → merge → pipeline
  aplica → Argo sincroniza → canary → promoción. Sin que nadie abriera la consola.

**~3h 30m.** Es el lab más largo y el que más rinde.

### 10 · Upgrade sin downtime — in-place vs blue/green

**Pregunta:** hay tráfico encima. ¿cómo subo de versión sin tumbar nada?

Cada minor de Kubernetes tiene ~14 meses de soporte estándar, así que son **dos
upgrades al año, agendados**. No es una emergencia, es una rutina — y como rutina
tiene que estar guionada.

- **Preparación, que es el 80% del trabajo:** revisar APIs deprecadas
  (`kubectl-convert`, `pluto`), matriz de compatibilidad de add-ons, PDBs puestos,
  y probarlo en dev primero. Nunca en prod primero, nunca sin haberlo hecho antes.
- **In-place:** control plane → node group → add-ons, en ese orden estricto. AWS
  documenta que [ambos planos deben terminar en la misma minor](https://docs.aws.amazon.com/eks/latest/best-practices/cluster-upgrades.html)
  y que el control plane necesita [hasta 5 IPs libres](https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html)
  en las subnets — detalle que rompe upgrades en VPCs apretadas.
- **Blue/green:** cluster nuevo en la versión nueva, tráfico migrado gradualmente,
  rollback = apuntar el DNS al viejo. [AWS lo documenta como estrategia](https://aws.amazon.com/blogs/containers/kubernetes-cluster-upgrade-the-blue-green-deployment-strategy/).
  Es lo que se usa cuando el riesgo no es negociable, y solo es viable si ya tienes
  el lab 09 (sin IaC no puedes clonar un cluster).
- **La decisión:** in-place es más barato y suficiente para la mayoría. Blue/green
  cuesta el doble mientras dura y es el único con rollback real. El lab hace los
  dos para que la decisión sea informada, no por defecto.
- **Rollback:** el control plane de EKS **no se puede bajar de versión**. Esa
  asimetría es la razón de existir de blue/green y hay que tenerla clara antes,
  no durante.

**~2h 30m.**

### 11 · Guardrails — políticas, seguridad y compliance

**Pregunta:** ¿cómo evitamos que un despliegue mal hecho llegue al cluster?

En un equipo grande no puedes revisar cada manifest a mano. Las reglas se
codifican y el cluster las rechaza solo.

- **Kyverno** como admission controller. Graduó en CNCF en
  [marzo 2026](https://www.cncf.io/announcements/2026/03/24/cloud-native-computing-foundation-announces-kyvernos-graduation/)
  y sus políticas son YAML de Kubernetes, no Rego — por eso lo prefiero sobre OPA
  Gatekeeper para empezar. Además de validar, puede **mutar** y **generar**
  recursos, que es lo que lo hace útil de verdad.
- Políticas que se sienten en el día a día:
  - rechazar imágenes con tag `:latest` o de registries no aprobados
  - exigir `requests`/`limits` en todo contenedor
  - prohibir `privileged`, `hostNetwork` y `runAsRoot`
  - **generar** automáticamente una NetworkPolicy default-deny en cada namespace nuevo
  - **mutar** para inyectar labels de ownership que no venían
- **Modo `Audit` antes de `Enforce`.** El error clásico es activar enforce de golpe
  y romper todos los despliegues del equipo. Se mide primero, se comunica, se
  aplica después.
- Alrededor: Pod Security Standards, cifrado de secrets con KMS, escaneo de
  imágenes en ECR, y audit logs del control plane a donde se puedan consultar.
- **La parte incómoda:** una política que rompe un deploy legítimo. Cómo se
  diagnostica (`PolicyReport`), cómo se excepciona con criterio, y por qué las
  excepciones también van en Git.

**~2h.**

### 12 · Observabilidad y SLOs

**Pregunta:** ¿cómo sabemos que algo está mal antes de que nos escriba un usuario?

- **Los tres pilares, con las opciones reales:**

  | Necesidad         | AWS nativo                                                               | Alternativa                                 |
  | ----------------- | ------------------------------------------------------------------------ | ------------------------------------------- |
  | Métricas de infra | CloudWatch Container Insights (add-on `amazon-cloudwatch-observability`) | Amazon Managed Prometheus + Managed Grafana |
  | Logs              | Fluent Bit → CloudWatch Logs                                             | Loki, o un SaaS                             |
  | Traces            | ADOT (AWS Distro for OpenTelemetry) → X-Ray                              | Cualquier backend OTLP                      |

  AWS es explícito en que Container Insights alcanza si CloudWatch es tu
  herramienta principal, y que [Managed Prometheus da más flexibilidad](https://docs.aws.amazon.com/prescriptive-guidance/latest/implementing-logging-monitoring-cloudwatch/prometheus-monitoring-eks.html)
  para consultar y retener métricas. El lab monta las dos rutas para que veas la
  diferencia en costo y en capacidad de consulta.

- **Control plane logs** encendidos (audit, authenticator) — y la conversación de
  cuánto cuestan, porque es real.
- **Instrumentar con OpenTelemetry**, no con el SDK de un vendor. Es la decisión
  que te deja cambiar de backend después sin reescribir la app.
- **La parte que casi nadie hace: SLOs.** Definir un SLI (por ejemplo,
  disponibilidad medida en el LB), un objetivo (99.9%), y alertar sobre
  **agotamiento de error budget**, no sobre "CPU al 80%". Alertar por síntomas del
  servicio y no por síntomas del nodo es la diferencia entre un on-call sostenible
  y uno que quema gente.
- **Cierre honesto:** apagarlo todo al terminar. La observabilidad es el costo
  recurrente que más sorprende en la primera factura.

**~2h 30m.**

### 13 · Costo y eficiencia — FinOps sobre Kubernetes

**Pregunta:** la factura llegó y nadie sabe qué la subió. ¿de quién es cada dólar?

En muchas organizaciones el costo es el motivo por el que llaman al equipo de
plataforma, no la disponibilidad. Y Kubernetes lo hace opaco a propósito: un
cluster es una factura de EC2 sin desglose por equipo.

- **Atribuir el gasto:** OpenCost o Kubecost para ver costo por namespace, por
  deployment y por equipo. Sin esto, "optimizar" es adivinar. El primer hallazgo
  típico es incómodo: un solo namespace se lleva la mitad de la factura.
- **Right-sizing con datos:** el patrón más caro de Kubernetes es pedir `requests`
  de 2 CPU para usar 0.1. Usar las recomendaciones del VPA en modo `Off` (solo
  recomienda, no aplica) para ajustar con evidencia en vez de con intuición.
- **Spot con Karpenter:** hasta 90% de descuento a cambio de interrupciones con 2
  minutos de aviso. Qué workloads lo toleran (stateless con réplicas), cuáles no, y
  cómo se mezcla con On-Demand en un mismo NodePool. Comprobar que la app sobrevive
  una interrupción, no asumirlo.
- **Consolidación y `ttlSecondsAfterEmpty`:** el ahorro que no requiere negociar con
  nadie, solo configurar bien Karpenter.
- **Compromisos:** Savings Plans y Reserved Instances para la base estable. Va
  después de right-sizing, nunca antes — comprometerte con capacidad
  sobredimensionada es pagar el error por tres años.
- **Tags obligatorios por política.** Sin tags no hay atribución, así que la regla
  de Kyverno del lab 11 que inyecta labels de ownership cierra el círculo aquí.
- **Lo que ya sabes de los labs 1-3 aplicado:** el NAT Gateway olvidado, el LB
  huérfano, el volumen EBS sin adjuntar. `scripts/verify-clean.sh` es la versión
  chiquita de esto mismo.

**~2h.**

---

## Vacíos conscientes

Después de los 13 labs quedan temas sin cubrir. No son olvidos, son decisiones —
o porque no caben en una cuenta personal, o porque el retorno no justifica el
tiempo. Vale tenerlos identificados para no confundir "no lo practiqué" con "no
existe".

| Tema                                                                  | Por qué queda fuera                                                                                                | Qué hacer                                                                                                        |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| **Multi-account / landing zone** (Organizations, SCPs, Control Tower) | Requiere varias cuentas AWS y presupuesto. No se puede simular con una                                             | Leerlo. Es la primera cosa que te va a tocar en una empresa y conviene reconocer el vocabulario                  |
| **Multi-región activo-activo**                                        | El costo se duplica y el problema real es el estado (Aurora Global, DynamoDB Global Tables), no el cómputo         | Conceptual. Entender que EKS es regional y "global" son varios clusters con DNS al frente                        |
| **Service mesh** (Istio, Linkerd)                                     | Complejidad alta y solo se justifica a cierta escala. Un mesh mal operado causa más incidentes de los que previene | Saber qué problema resuelve (mTLS, tráfico fino, telemetría) y que el lab 07 + 09 cubren el 80% con menos piezas |
| **Runtime security** (GuardDuty EKS Protection, Falco)                | Se solapa con el lab 11 y encender GuardDuty en una cuenta de lab cuesta                                           | Fold-in opcional del lab 11                                                                                      |
| **Windows nodes, GPU, ML**                                            | Nicho. GPU además es caro por hora                                                                                 | Solo si tu trabajo lo pide                                                                                       |
| **Chaos engineering / game days**                                     | Necesita un sistema con SLOs ya definidos para que signifique algo                                                 | Cierre opcional del lab 08, después del 12                                                                       |
| **Compliance formal** (CIS Benchmark, PCI, SOC2)                      | Es un ejercicio de auditoría, no de ingeniería                                                                     | Fold-in del lab 11                                                                                               |
| **Secrets externos** (External Secrets Operator, Secrets Manager CSI) | Cabe en el lab 05 como extensión natural de Pod Identity                                                           | Fold-in del lab 05                                                                                               |
| **Backstage / portal interno**                                        | Es producto, no infraestructura. Solo tiene sentido con varios equipos consumiendo                                 | Leerlo si te toca plataforma                                                                                     |
| **etcd, kubeadm, control plane**                                      | En EKS es managed, no tienes acceso                                                                                | Se practica en kind. Ver [puente con CKA](#puente-con-los-labs-de-cka)                                           |

Si más adelante uno de estos se vuelve relevante para tu trabajo, cabe como lab
nuevo en su nivel sin romper la estructura: el nivel 1 admite fundamentos, el 2
operación, el 3 proceso y gobierno.

---

## Alcance y límites: esto es un lab, no producción

Importa decirlo explícito. Los labs enseñan **la mecánica** de EKS, y esa parte es
correcta y transferible. Pero **la forma en que la ejecutan no es cómo se opera un
ambiente productivo**, y la diferencia principal no es técnica, es de proceso.

| En el lab hacemos...                      | En producción sería...                                                                                                                                                                            | Por qué el lab lo hace así                                                                      |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Clic en la consola para IAM, VPC, cluster | Terraform/CDK en Git, aplicado por pipeline. Nadie tiene escritura en la consola de prod                                                                                                          | Para que veas los campos y entiendas qué configura cada uno. Un módulo de Terraform los esconde |
| `kubectl create deployment`               | GitOps: Argo CD o Flux sincronizan desde un repo. Un cambio es un PR                                                                                                                              | Los comandos imperativos son lo que necesitas para el CKA                                       |
| Una sola cuenta AWS                       | Organizations con cuenta por ambiente, SCPs, Control Tower                                                                                                                                        | Simplicidad y costo                                                                             |
| Endpoint del API público                  | Privado, con acceso por VPN, bastión o SSM                                                                                                                                                        | Para poder usar `kubectl` desde tu casa sin montar red                                          |
| Un cluster                                | Mínimo uno por ambiente. Y la decisión "uno grande vs varios" es un [trade-off documentado](https://docs.aws.amazon.com/en_us/eks/latest/best-practices/scalability.html), no una respuesta única | Costo                                                                                           |
| Sin políticas de admisión                 | Kyverno/OPA, Pod Security Standards, NetworkPolicy default-deny                                                                                                                                   | Lab 11                                                                                          |
| Observabilidad apagada para ahorrar       | Encendida antes que la app, con SLOs y alertas                                                                                                                                                    | Lab 12                                                                                          |
| Sin backup                                | Velero, y probado con un restore real                                                                                                                                                             | Lab 06                                                                                          |
| Secrets en claro en etcd                  | Cifrado de sobre con KMS                                                                                                                                                                          | Un paso más de setup                                                                            |
| Todo se ve con todo dentro del cluster    | NetworkPolicy default-deny, ResourceQuota y RBAC por equipo                                                                                                                                       | Lab 07                                                                                          |
| Imagen pública de Docker Hub, HTTP plano  | Imagen propia en ECR con tag inmutable, HTTPS con ACM                                                                                                                                             | Lab 04                                                                                          |
| Nadie sabe cuánto cuesta cada equipo      | Atribución con OpenCost, tags obligatorios, right-sizing con datos                                                                                                                                | Lab 13                                                                                          |
| Destruir todo al terminar                 | El cluster vive años y se le hacen upgrades                                                                                                                                                       | Es un lab                                                                                       |

**No conviertas los labs 1-3 en labs de producción.** Si el lab 1 fuera Terraform +
GitOps no aprenderías qué es un Fargate profile, aprenderías a copiar un módulo.
El orden correcto es: entender la mecánica a mano (nivel 1), operarla (nivel 2),
y después automatizarla y gobernarla (nivel 3).

### Qué cambia cuando el equipo es internacional

Con una persona, el conocimiento puede vivir en su cabeza. Con un equipo repartido
en husos horarios, todo lo que no esté escrito se convierte en un bloqueo de 12 horas:

- **El estado deseado en Git, siempre.** No es purismo. Es que alguien en otro
  huso pueda ver qué está desplegado sin despertar a nadie.
- **Runbooks para lo repetitivo** — el upgrade, el rollback, el escalado de
  emergencia. Escritos antes de necesitarlos.
- **ADRs (Architecture Decision Records)** para el "¿por qué está así?". Sin esto,
  cada rotación de personal repite las mismas discusiones.
- **Ownership explícito por namespace o servicio**, en labels y en el repo.
- **On-call con handoff documentado** y alertas que apuntan a un servicio con
  dueño, no a un nodo.
- **Cero conocimiento tribal en el camino crítico.** Si el deploy necesita que
  alguien "corra el script que tiene en su máquina", el sistema no es operable.

Los labs 09 a 13 existen justamente para eso: no agregan features, agregan la
capacidad de que varias personas operen lo mismo sin pisarse.

### Lectura paralela

- [EKS Best Practices Guide](https://docs.aws.amazon.com/eks/latest/best-practices/) — seguridad, confiabilidad, escalabilidad, costo y upgrades. El estándar de facto.
- [`references/eks-vs-ecs.md`](references/eks-vs-ecs.md) — cuándo usar EKS y cuándo usar ECS. El argumento completo para sustentar la decisión.

## Puente con los labs de CKA

La mayoría de ejercicios de `domains/` corren igual sobre un cluster EKS. Las
excepciones son las que tocan el control plane, porque en EKS es managed y no
tienes acceso:

| Tema                                                 | En EKS                                                                            | Dónde practicarlo      |
| ---------------------------------------------------- | --------------------------------------------------------------------------------- | ---------------------- |
| `etcd` backup / restore                              | No aplica, no ves etcd                                                            | kind o kubeadm         |
| Upgrade con `kubeadm`                                | No aplica, es un click/API                                                        | kind o kubeadm         |
| Editar manifests estáticos en `/etc/kubernetes`      | Sin acceso al control plane                                                       | kind o kubeadm         |
| Troubleshooting de nodos                             | Solo en el lab 2 (EC2, con SSH). En Fargate y Auto Mode no hay nodo al que entrar | kind + lab 2           |
| RBAC, workloads, services, storage, network policies | Igual que en cualquier cluster                                                    | Cualquiera de los tres |

Regla: **cluster architecture** e **installation** se practican en kind. Todo lo
demás se puede hacer en EKS, con la ventaja de que además ves cómo se integra con
IAM, VPC y load balancers de verdad.
