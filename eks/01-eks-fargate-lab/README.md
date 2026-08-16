# Lab Manual: EKS + Fargate en Virginia (us-east-1)

## Resumen

Cluster EKS con Fargate, desplegar nginx público con AWS Load Balancer Controller.
Todo desde la consola de AWS + CLI.

**Costo estimado:** ~$0.15/hr (EKS $0.10 + NAT $0.045 + Fargate pods ~$0.01)

**Herramientas necesarias en tu PC:**

- AWS CLI v2
- kubectl
- eksctl
- helm (`winget install Helm.Helm`)

---

## Paso 1: Crear IAM Roles

IAM → Roles → Create role

### Rol 1: Cluster EKS

El cluster necesita un rol para gestionar recursos en AWS (crear ENIs, hablar con EC2, etc.)

1. Trusted entity type: **Custom trust policy**
2. Pegar:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

3. Next → buscar y marcar **AmazonEKSClusterPolicy** → Next
4. Role name: `eks-lab-cluster-role` → Create role

### Rol 2: Fargate

Fargate necesita un rol para ejecutar pods (descargar imágenes, escribir logs, etc.)

1. Trusted entity type: **Custom trust policy**
2. Pegar:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks-fargate-pods.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

3. Next → buscar y marcar **AmazonEKSFargatePodExecutionRolePolicy** → Next
4. Role name: `eks-lab-fargate-role` → Create role

**Nota:** Si eliges "AWS Service → EKS" directamente, la consola crea un
Service-Linked Role con nombre fijo que no puedes editar. Por eso usamos
"Custom trust policy" — para controlar el nombre.

---

## Paso 2: Crear VPC

EKS necesita una VPC con subnets públicas (para Load Balancers) y privadas (para pods Fargate).
Fargate NO soporta subnets públicas — los pods solo corren en privadas.

1. VPC → Create VPC → **VPC and more**
2. Configurar:
   - Name tag: `lab`
   - IPv4 CIDR: `10.0.0.0/16`
   - Number of AZs: **2**
   - Public subnets: **2**
   - Private subnets: **2**
   - NAT gateways: **In 1 AZ** ($0.045/hr, más barato que "1 per AZ")
   - VPC endpoints: None
3. Create VPC (~1-2 min)

**¿Por qué NAT Gateway?** Los pods en subnets privadas necesitan salir a internet
(descargar imágenes Docker) pero no deben ser accesibles desde internet.
El NAT permite salir sin ser accesible.

**¿Por qué "In 1 AZ"?** Cada NAT cuesta $0.045/hr. Uno es suficiente para un lab.
En producción pondrías 1 por AZ para alta disponibilidad.

---

## Paso 3: Crear Cluster EKS

1. EKS → Add cluster → Create
2. Configuration: **Configuración personalizada**
3. **Desactivar "Utilizar el modo automático de EKS"**
   - Auto Mode usa EC2 por debajo con ~12% premium. Nosotros usamos Fargate.
4. Configurar:
   - Nombre: `lab-cluster`
   - Rol: `eks-lab-cluster-role`
   - Versión Kubernetes: la más reciente (1.36)
   - Política de actualización: Soporte estándar
   - Nivel de escalado: NO activar
   - Acceso administrador: Permitir
   - Modo de autenticación: API de EKS
   - Cifrado de sobre: NO
   - Cambio de zona ARC: Desactivado
   - Protección contra eliminaciones: NO
5. Next → Networking:
   - VPC: `lab-vpc`
   - Subnets: **las 4** (2 públicas + 2 privadas)
   - Security groups: dejar el default o vacío (EKS crea uno automáticamente)
   - Cluster endpoint access: **Público y privado**
   - Modo de salida: Administrado por AWS
6. Next → Observability: **todo desactivado** (genera costos extra)
7. Next → Add-ons: solo los 3 básicos:
   - **CoreDNS** (DNS interno del cluster)
   - **Amazon VPC CNI** (asigna IPs a los pods)
   - **kube-proxy** (ruteo interno de Services)
   - Quitar: supervisión de nodos, Pod Identity, DNS externo, servidor de métricas
8. Next → Review → Create

⏱️ **Tarda ~10 minutos en quedar Active.**

**Si te sale error de permisos del rol:** Es porque el Auto Mode está activado.
Desactívalo y el warning desaparece.

---

## Paso 4: Dar acceso al cluster (si usas otro usuario en CLI)

Si el usuario con el que creaste el cluster en la consola es diferente al de tu CLI:

1. EKS → lab-cluster → **Access**
2. Create access entry
3. IAM principal: el usuario/rol de tu CLI (el de `aws sts get-caller-identity`)
4. Policy: **`AmazonEKSClusterAdminPolicy`** (NO `AmazonEKSAdminPolicy` — esa no permite crear namespaces)
5. Scope: Cluster
6. Create

**Diferencia entre las dos policies:**
| Policy | Permisos |
|--------|----------|
| `AmazonEKSAdminPolicy` | Admin dentro de namespaces existentes, pero NO puede crear namespaces ni recursos cluster-scoped |
| `AmazonEKSClusterAdminPolicy` | Equivalente a `system:masters` — acceso total al cluster |

---

## Paso 5: Crear Fargate Profiles

Los Fargate Profiles dicen: "todo pod en namespace X, córrelo en Fargate".
Sin profile, los pods se quedan en Pending para siempre.

EKS → lab-cluster → Compute → Fargate Profiles → Add

### Profile 1: fp-system

- Nombre: `fp-system`
- Pod execution role: `eks-lab-fargate-role`
- Subnets: solo las 2 **privadas**
- Pod selectors → Namespace: `kube-system`

### Profile 2: fp-apps

- Nombre: `fp-apps`
- Pod execution role: `eks-lab-fargate-role`
- Subnets: solo las 2 **privadas**
- Pod selectors → Namespace: `apps`

**Importante:** El match es por el nombre del namespace en el selector,
NO por el nombre del profile. El profile "fp-apps" podría llamarse "banana"
y seguiría funcionando igual si su selector dice `namespace = apps`.

---

## Paso 6: Conectar kubectl

```bash
aws eks update-kubeconfig --name lab-cluster --region us-east-1
```

Verificar:

```bash
kubectl get pods -n kube-system
```

### Si CoreDNS está en Pending:

En versiones viejas de EKS, CoreDNS tiene una anotación que lo obliga a correr en EC2.
Hay que quitarla:

```bash
kubectl rollout restart deployment coredns -n kube-system
```

Esperar ~1-2 min hasta que los pods estén en Running.

---

## Paso 7: Desplegar nginx

```bash
# Crear el namespace (matchea con Fargate Profile fp-apps)
kubectl create namespace apps

# Crear un Deployment con 2 réplicas de nginx
kubectl create deployment nginx --image=nginx:alpine --replicas=2 -n apps
```

Esperar ~30-60 seg (cold start de Fargate):

```bash
kubectl get pods -n apps -w
```

**¿Qué es `-w`?** Es `--watch`. kubectl se queda escuchando cambios en tiempo real.
Cada vez que un pod cambia de estado (Pending → ContainerCreating → Running),
imprime una nueva línea. Para salir: `Ctrl+C`.

---

## Paso 8: Instalar AWS Load Balancer Controller

**¿Por qué se necesita?** En Fargate no hay instancias EC2. El controlador por defecto
de Kubernetes solo sabe crear LBs con target type "instance". Como no hay instancias,
no funciona. El AWS LB Controller sabe registrar IPs de pods directamente como targets.

### 8.1: Crear OIDC Provider

```bash
eksctl utils associate-iam-oidc-provider --cluster lab-cluster --region us-east-1 --approve
```

#### ¿Qué es OIDC y por qué lo necesitamos aquí?

**OIDC** (OpenID Connect) es un protocolo de identidad. En EKS, cada cluster tiene
un "OIDC issuer" — una URL única que identifica al cluster.

**El problema:** Necesitamos que un pod (el LB Controller) pueda llamar APIs de AWS
(crear Load Balancers, Target Groups, etc.). Pero un pod no tiene credenciales AWS
por defecto.

**La solución (IRSA - IAM Roles for Service Accounts):**

1. El pod tiene un ServiceAccount de Kubernetes
2. Kubernetes le genera un token JWT (como un "carnet de identidad")
3. El pod presenta ese token a AWS diciendo "soy el ServiceAccount X del cluster Y"
4. AWS valida el token contra el OIDC Provider (que configuramos en este paso)
5. Si es válido, AWS le da credenciales temporales del rol IAM asociado

**Sin el OIDC Provider, AWS no puede validar los tokens de Kubernetes.**
Es como registrar la firma de un notario — si la firma no está registrada,
nadie la acepta.

```
┌─────────────────────────────────────────────────────────┐
│                    Flujo IRSA                            │
│                                                         │
│  Pod (LB Controller)                                    │
│    │                                                    │
│    ├─ 1. Tiene ServiceAccount con anotación de rol IAM  │
│    ├─ 2. Kubernetes le inyecta un token JWT             │
│    ├─ 3. Pod llama a AWS STS con el token               │
│    │                                                    │
│  AWS STS                                                │
│    ├─ 4. Valida el token con el OIDC Provider           │
│    ├─ 5. Si válido → entrega credenciales temporales    │
│    │                                                    │
│  Pod ya puede crear LBs, Target Groups, etc.            │
└─────────────────────────────────────────────────────────┘
```

**¿Para qué más sirve OIDC?** Para CUALQUIER pod que necesite permisos AWS:

- External DNS → modificar Route 53
- Cert Manager → validar certificados
- Apps que leen S3, escriben DynamoDB, publican en SNS/SQS
- Secrets Manager CSI Driver

**¿Por qué es mejor que hardcodear access keys?**
| Método | Problema |
|--------|---------|
| Hardcodear access keys en env vars | Inseguro, no rotan, si se filtran estás expuesto |
| Rol IAM en el nodo EC2 | TODOS los pods del nodo comparten los mismos permisos |
| **IRSA via OIDC** | Cada pod tiene SOLO sus permisos, credenciales temporales, rotación automática |

Esto crea un Identity Provider en IAM (visible en IAM → Identity Providers).

### 8.2: Descargar la policy de IAM

Contiene todos los permisos que el controller necesita (crear LBs, Target Groups, etc.)

**IMPORTANTE:** Usar la policy de la rama `main`, no de una versión vieja.
La de v2.11.0 NO tiene `ec2:DescribeRouteTables` que el controller v3.x necesita.

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json" -OutFile iam_policy.json
```

Verificar que se descargó bien:

```powershell
Select-String "DescribeRouteTables" iam_policy.json
# Debe mostrar una línea. Si no muestra nada, la descarga falló.
```

### 8.3: Crear la policy en IAM

```bash
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy.json
```

**Nota:** El `file://` es obligatorio. Sin él, AWS CLI interpreta el string como
texto literal y falla con "Syntax errors in policy".

### 8.4: Crear Service Account con rol IAM

```bash
eksctl create iamserviceaccount --cluster=lab-cluster --namespace=kube-system --name=aws-load-balancer-controller --attach-policy-arn=arn:aws:iam::<TU_ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy --override-existing-serviceaccounts --region us-east-1 --approve
```

**Reemplaza `<TU_ACCOUNT_ID>`** con tu account ID real (el de `aws sts get-caller-identity`).

#### ¿Qué hace este comando por debajo?

Crea un stack de CloudFormation que contiene:

1. Un **IAM Role** con la policy del LB Controller
2. Una **trust policy** que dice "solo el ServiceAccount `aws-load-balancer-controller` del cluster `lab-cluster` puede asumir este rol"
3. Un **ServiceAccount en Kubernetes** anotado con el ARN del rol

Puedes ver el stack en CloudFormation con nombre tipo:
`eksctl-lab-cluster-addon-iamserviceaccount-kube-system-aws-load-balancer-controller`

#### ¿Qué es un ServiceAccount?

Es una identidad para pods (no para humanos). Cuando un pod se crea, se le asigna
un ServiceAccount. Es como el "usuario" con el que corre el pod dentro del cluster.

Al anotar el ServiceAccount con un ARN de rol IAM, el pod puede asumir ese rol
automáticamente vía OIDC (el mecanismo que configuramos en 8.1).

### 8.5: Instalar el controller con Helm

#### ¿Qué es Helm?

Helm es un **package manager para Kubernetes** (como apt/yum para Linux o winget para Windows).
Un "chart" de Helm es un paquete que contiene todos los recursos Kubernetes necesarios
para desplegar una aplicación (Deployments, Services, ConfigMaps, RBAC, etc.)
empaquetados con valores configurables.

Sin Helm tendrías que crear manualmente ~10 archivos YAML para el LB Controller.
Con Helm es un solo comando.

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm install aws-load-balancer-controller eks/aws-load-balancer-controller --set clusterName=lab-cluster --set serviceAccount.create=false --set region=us-east-1 --set vpcId=<TU_VPC_ID> --set serviceAccount.name=aws-load-balancer-controller -n kube-system
```

**Reemplaza `<TU_VPC_ID>`** con tu VPC ID real. Lo puedes obtener con:

```bash
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*lab*" --query "Vpcs[0].VpcId" --output text --region us-east-1
```

**Si te equivocaste en el VPC ID**, no necesitas desinstalar. Corrige con `helm upgrade`:

```bash
helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller --set clusterName=lab-cluster --set serviceAccount.create=false --set region=us-east-1 --set vpcId=vpc-CORRECTO --set serviceAccount.name=aws-load-balancer-controller -n kube-system
```

### 8.6: Verificar (~1-2 min)

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
# Debe decir 2/2 Ready
```

---

## Paso 9: Exponer nginx con un NLB

Crear un Service tipo LoadBalancer con las anotaciones para que el AWS LB Controller
cree un NLB con target type IP (apuntando directo a los pods Fargate):

Archivo `nginx-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: apps
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
spec:
  type: LoadBalancer
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
```

```bash
kubectl apply -f nginx-service.yaml
```

#### ¿Qué hace cada anotación?

| Anotación                           | Valor             | Significado                                                             |
| ----------------------------------- | ----------------- | ----------------------------------------------------------------------- |
| `aws-load-balancer-type`            | `nlb`             | Usa Network Load Balancer (capa 4, más rápido y barato que ALB)         |
| `aws-load-balancer-nlb-target-type` | `ip`              | Registra IPs de pods directamente como targets (obligatorio en Fargate) |
| `aws-load-balancer-scheme`          | `internet-facing` | El LB es público (accesible desde internet)                             |

Sin la anotación `target-type: ip`, intentaría usar `instance` y fallaría porque Fargate no tiene instancias EC2.

Esperar ~2-3 min:

```bash
kubectl get svc nginx -n apps
# EXTERNAL-IP muestra la URL del NLB
```

Abrir en el navegador → página de bienvenida de NGINX.

---

## Conceptos clave

### Deployment vs Service vs Pod

- **Pod:** contenedor(es) corriendo. La unidad mínima.
- **Deployment:** controlador que mantiene N pods corriendo. Si uno muere, crea otro.
- **Service:** dirección estable que apunta a los pods. Sin esto, nadie puede llegar a ellos.

### Namespace

Carpeta lógica dentro del cluster. Sirve para organizar y aislar recursos.
El Fargate Profile matchea por namespace — si no hay profile para un namespace,
los pods quedan en Pending.

### Analogía con ECS

| ECS             | Kubernetes             |
| --------------- | ---------------------- |
| Task Definition | Pod spec               |
| Service         | Deployment             |
| Target Group    | Service (ClusterIP)    |
| ALB/NLB         | Service (LoadBalancer) |

---

## Errores encontrados y soluciones

| Error                                                        | Causa                                                                 | Solución                                                         |
| ------------------------------------------------------------ | --------------------------------------------------------------------- | ---------------------------------------------------------------- |
| "the server has asked for the client to provide credentials" | El usuario de CLI no tiene acceso al cluster                          | Crear Access Entry en EKS → Access                               |
| "namespaces is forbidden"                                    | Tienes `AmazonEKSAdminPolicy` en vez de `AmazonEKSClusterAdminPolicy` | Cambiar la policy en Access Entry                                |
| CoreDNS en Pending                                           | Anotación `compute-type: ec2`                                         | `kubectl rollout restart deployment coredns -n kube-system`      |
| Service crea Classic LB que no funciona                      | Sin AWS LB Controller, Kubernetes crea CLB con target type instance   | Instalar AWS Load Balancer Controller                            |
| LB Controller error "DescribeRouteTables 403"                | Policy de IAM descargada de versión vieja (v2.11.0)                   | Usar policy de rama `main` que incluye `ec2:DescribeRouteTables` |
| "MalformedPolicyDocument: Syntax errors in policy"           | Falta `file://` en `--policy-document`                                | Usar `file://iam_policy.json`                                    |
| `curl` no descarga bien en PowerShell                        | Conflicto con alias de curl en PS                                     | Usar `Invoke-WebRequest -OutFile` en vez de `curl -o`            |
| `helm install` con VPC ID incorrecto                         | No reemplazaste `<TU_VPC_ID>`                                         | Corregir con `helm upgrade` (no necesitas desinstalar)           |

---

## 🔴 Destruir todo

### Ejecutar script de destrucción:

```powershell
.\destroy.ps1
```

El script detecta tu Account ID automáticamente y se ejecuta de corrido.
Usa `aws eks wait` para esperar a que los recursos se eliminen antes de continuar.

Elimina en orden: Service → LB Controller → IAM Service Account → IAM Policy →
Fargate Profiles → Cluster → NAT Gateway → Elastic IP → IAM Roles → OIDC Provider.

Solo queda borrar la VPC desde la consola al final (Actions → Delete VPC).

---

## Verificaciones post-deploy

Comandos útiles para explorar y validar que todo funciona correctamente.

### Infraestructura

```bash
# Nodos virtuales de Fargate (uno por pod)
kubectl get nodes

# Ver detalles de un nodo Fargate (CPU, memoria asignada)
kubectl describe node <nombre-de-un-nodo>

# Ver los Target Groups del NLB
aws elbv2 describe-target-groups --region us-east-1

# Ver los targets registrados (IPs de los pods)
aws elbv2 describe-target-health --target-group-arn <arn-del-target-group> --region us-east-1
```

### Resiliencia

```bash
# Borrar un pod y ver cómo Kubernetes lo recrea automáticamente
kubectl delete pod -n apps $(kubectl get pods -n apps -o jsonpath='{.items[0].metadata.name}')
kubectl get pods -n apps -w
# El Deployment detecta que falta un pod y crea uno nuevo (~35 seg en Fargate)
```

### Escalado

```bash
# Subir a 4 réplicas
kubectl scale deployment nginx -n apps --replicas=4
kubectl get pods -n apps -w
# Fargate provisiona nodos virtuales para cada nuevo pod
```

### Logs

```bash
# Logs de nginx (tráfico HTTP)
kubectl logs -n apps -l app=nginx

# Logs del LB Controller (creación de NLB, registro de targets)
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=20
```

### Qué se ve en los logs del LB Controller

El controller muestra en tiempo real cómo gestiona los targets:

- `registering targets` — cuando se crean pods nuevos, los registra en el Target Group
- `deRegistering targets` — cuando se borran pods, los quita del Target Group
- `Successful reconcile` — confirmación de que el estado real coincide con el deseado
- `setting service loadBalancerClass` — cuando detecta el Service con las anotaciones NLB

### En la consola de AWS

- **EC2 → Load Balancers** → tu NLB con el DNS público
- **EC2 → Target Groups** → targets con las IPs privadas de los pods
- **IAM → Identity Providers** → el OIDC Provider del cluster
- **IAM → Roles** → `eks-lab-lb-controller-role` con la trust policy OIDC

---

## Lecciones aprendidas

1. **Fargate es serverless pero no "sin fricción"** — necesitas profiles por namespace,
   AWS LB Controller para exponer servicios, y la anotación `compute-type` de CoreDNS.

2. **Con EC2 nodes sería más simple** — un Service tipo LoadBalancer funciona directo
   sin instalar nada. Fargate ahorra gestión de nodos pero agrega complejidad en networking.

3. **EKS Auto Mode** es la alternativa más nueva: ni gestionas nodos ni necesitas
   LB Controller (viene incluido). Es un punto medio entre EC2 y Fargate.

4. **Siempre usar la policy de la rama `main`** del LB Controller, no de una versión
   específica vieja. Las versiones nuevas del controller requieren permisos que
   las policies viejas no tienen.

5. **OIDC es el puente entre Kubernetes y AWS IAM.** Sin él, los pods no pueden
   obtener credenciales AWS de forma segura. Se configura una vez por cluster
   y lo aprovechan todos los servicios que necesiten hablar con AWS.
