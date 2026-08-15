# Labs de EKS — de lo básico a lo específico

Ruta de práctica para entender EKS por capas. Cada lab levanta un cluster desde
la consola de AWS, despliega nginx expuesto a internet, y lo destruye. La
diferencia entre labs es **quién gestiona el cómputo y qué tienes que instalar tú**.

## Orden propuesto

| #   | Lab                                     | Qué aprendes                                                            | Por qué va en esta posición                                                                                          |
| --- | --------------------------------------- | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| 1   | [`eks-fargate-lab`](eks-fargate-lab/)   | Fargate profiles, IRSA + OIDC, AWS Load Balancer Controller con Helm    | Es el que más piezas te obliga a montar a mano. Aquí ves _por qué_ existe cada componente                            |
| 2   | [`eks-ec2-lab`](eks-ec2-lab/)           | Managed Node Groups, kube-proxy, cloud-controller-manager, AMIs, sizing | Después de pelear con Fargate, aprecias que un `Service` tipo LoadBalancer funcione sin instalar nada                |
| 3   | [`eks-automode-lab`](eks-automode-lab/) | Auto Mode, NodePools, Karpenter, controllers integrados                 | Cierra la ruta: AWS te quita de encima todo lo de los labs 1 y 2. Solo entiendes el valor si antes lo hiciste a mano |

La lógica es **fricción decreciente**: empiezas donde tienes que ensamblar todo y
terminas donde no ensamblas nada. Los READMEs se referencian entre sí en ese orden
(el de EC2 compara contra Fargate, el de Auto Mode contra los dos).

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
- **El lab de upgrade (roadmap 06):** crea el cluster una versión **atrás** a
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

## Scripts

```
eks/
├── scripts/
│   ├── eks-teardown-lib.sh    # funciones compartidas de teardown
│   └── verify-clean.sh        # auditoría post-destroy: ¿quedó algo cobrando?
├── proposals/
│   └── 01-tagging-and-cleanup.md
├── eks-fargate-lab/   destroy.ps1 · destroy.sh
├── eks-ec2-lab/       destroy.ps1 · destroy.sh
└── eks-automode-lab/  destroy.ps1 · destroy.sh
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

## Roadmap: 3 labs avanzados

Los tres labs actuales cubren "levantar un cluster y exponer una app". Estos tres
cubren lo que viene después. Cada uno agrupa varios temas alrededor de una
pregunta, para que no sean recetas sueltas.

### 04 · Identidad y permisos — IRSA vs EKS Pod Identity

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

### 05 · Estado y escala — storage persistente + autoscaling bajo carga

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
- Cierre: `reclaimPolicy` y por qué un `kubectl delete pvc` mal hecho te deja
  volúmenes EBS cobrando (esto ya está mitigado en `eks-automode-lab/destroy.sh`).

Se monta sobre el cluster del lab 3 (Auto Mode), que ya trae EBS CSI y Karpenter.
Conecta directo con `domains/04-storage` y `domains/02-workloads`. **~2h.**

### 06 · Día 2 — upgrade, observabilidad y troubleshooting

**Pregunta:** el cluster ya está en producción. ¿cómo lo operas sin tumbarlo?

- **Observabilidad primero,** para tener con qué mirar lo demás: CloudWatch
  Container Insights + Fluent Bit, control plane logs encendidos a propósito
  (y apagados al terminar, que es la parte que los labs actuales se saltan).
- **Upgrade en orden:** control plane → node group → add-ons. Con un PDB y un
  deployment con réplicas para ver el drain respetando la disponibilidad, y qué
  pasa si el PDB es demasiado estricto y el drain se queda colgado.
- **Escenarios rotos a propósito**, cada uno con un síntoma distinto:
  - subnet pública sin el tag `kubernetes.io/role/elb` → el LB no se crea
  - security group del nodo bloqueando el health check → targets unhealthy
  - Access Entry faltante → `the server has asked for the client to provide credentials`
  - CIDR de subnet agotado → pods en Pending sin razón aparente
  - add-on de una versión incompatible con el control plane
- Método, no recetas: `kubectl describe` → eventos → logs del componente →
  CloudWatch. El objetivo es que reconozcas el síntoma, no que memorices el fix.

Para esta parte conviene un cluster desechable rápido: un `cluster.yaml` de
`eksctl` que lo levante en un comando. Cierra el círculo — ya sabes qué hay
debajo porque lo hiciste a mano tres veces. `domains/05-troubleshooting` es 30%
del CKA. **~2h 30m.**

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
