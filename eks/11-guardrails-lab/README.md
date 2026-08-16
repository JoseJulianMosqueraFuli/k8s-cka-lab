# Lab 11: Guardrails — políticas, seguridad y compliance

## Resumen

Instalas Kyverno como admission controller y creas políticas reales: rechazar
imágenes `:latest`, prohibir contenedores privilegiados, exigir resource limits,
generar NetworkPolicies automáticamente, y mutar pods para inyectar labels.

El punto clave: empezar en modo Audit (ver qué se rompería) antes de pasar a
Enforce (rechazar de verdad). El error clásico es enforce desde el día uno y
romper todos los deploys.

**Se monta sobre:** el cluster del lab 02 (EC2) o 03 (Auto Mode).
**Costo estimado adicional:** ~$0.00 (Kyverno son solo pods)
**Tiempo:** ~2h

**Herramientas necesarias:**

- AWS CLI v2
- kubectl
- helm

**Conexión CKA:** `domains/01-cluster-architecture` — security, admission controllers (25%)

---

## ¿Por qué Kyverno y no OPA/Gatekeeper?

| Aspecto                  | Kyverno                             | OPA/Gatekeeper                 |
| ------------------------ | ----------------------------------- | ------------------------------ |
| **Lenguaje**             | YAML nativo                         | Rego (lenguaje propio)         |
| **Curva de aprendizaje** | Baja (si sabes YAML, sabes Kyverno) | Alta (Rego es funcional)       |
| **Capacidades**          | Validate, Mutate, Generate, Verify  | Validate, Mutate               |
| **CNCF**                 | Graduated (marzo 2026)              | Graduated                      |
| **Debugging**            | PolicyReport (recurso K8s)          | Constraint status + audit logs |
| **Para este lab**        | Más accesible, más versátil         | Más maduro en enterprise       |

Kyverno no requiere aprender un lenguaje nuevo. Las políticas son YAML que
cualquier persona que escribe manifiestos Kubernetes puede leer y entender.

---

## Paso 1: Instalar Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --set admissionController.replicas=3 \
  --set backgroundController.replicas=2

# Esperar
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/instance=kyverno \
  -n kyverno --timeout=120s

# Verificar
kubectl get pods -n kyverno
```

### ¿Por qué 3 réplicas del admission controller?

El admission controller está en la ruta crítica de **todo** `kubectl apply`.
Si se cae y no hay réplicas, no puedes crear ni modificar recursos. Con 3
réplicas y un PDB, sobrevive a upgrades y fallos de nodo.

---

## Paso 2: Política — Rechazar imágenes con `:latest`

### Modo Audit primero

```yaml
# policies/disallow-latest-tag.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
  annotations:
    policies.kyverno.io/title: Disallow Latest Tag
    policies.kyverno.io/description: >-
      Las imágenes con tag :latest son mutables y no trazables.
      Usar tags inmutables (SHA del commit) para reproducibilidad.
spec:
  validationFailureAction: Audit # ← NO rechaza, solo reporta
  background: true
  rules:
    - name: validate-image-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: >-
          La imagen '{{request.object.spec.containers[].image}}' usa tag ':latest'
          o no tiene tag explícito. Usa un tag inmutable (ej: sha del commit).
        pattern:
          spec:
            containers:
              - image: "*:*"
            # Excluir imágenes que terminen en :latest
        deny:
          conditions:
            any:
              - key: "{{request.object.spec.containers[].image}}"
                operator: AnyIn
                value:
                  - "*:latest"
                  - "!*:*" # Sin tag (implícitamente latest)
```

**Versión más simple y directa:**

```yaml
# policies/disallow-latest-tag.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Audit
  rules:
    - name: require-image-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Imagen '{{request.object.spec.containers[0].image}}' no debe usar ':latest'. Usa un tag inmutable."
        pattern:
          spec:
            containers:
              - image: "!*:latest & *:*"
```

```bash
kubectl apply -f policies/disallow-latest-tag.yaml
```

### Probar en Audit

```bash
# Esto NO se rechaza (estamos en Audit), pero se reporta
kubectl run test-latest --image=nginx:latest

# Ver el PolicyReport
kubectl get policyreport -A
kubectl describe policyreport -n default

# Output incluye:
# Result: fail
# Message: Imagen 'nginx:latest' no debe usar ':latest'
```

### Cambiar a Enforce

```bash
kubectl patch clusterpolicy disallow-latest-tag \
  --type merge -p '{"spec":{"validationFailureAction":"Enforce"}}'

# Ahora SÍ se rechaza
kubectl run test-latest2 --image=nginx:latest
# Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
# Imagen 'nginx:latest' no debe usar ':latest'. Usa un tag inmutable.

# Con tag explícito SÍ funciona
kubectl run test-tagged --image=nginx:1.25-alpine
# pod/test-tagged created
```

---

## Paso 3: Política — Exigir requests y limits

```yaml
# policies/require-resources.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resources
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-requests-limits
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Todos los contenedores deben tener requests y limits de CPU/memoria definidos."
        pattern:
          spec:
            containers:
              - resources:
                  requests:
                    cpu: "?*"
                    memory: "?*"
                  limits:
                    cpu: "?*"
                    memory: "?*"
```

```bash
kubectl apply -f policies/require-resources.yaml

# Sin resources → rechazado
kubectl run no-resources --image=nginx:1.25-alpine
# denied: must have requests and limits

# Con resources → aceptado
kubectl run with-resources --image=nginx:1.25-alpine \
  --requests='cpu=50m,memory=32Mi' --limits='cpu=100m,memory=64Mi'
```

### ¿Por qué exigir resources?

- Sin requests: el scheduler no sabe cuánto necesita el pod → sobrecompromete nodos
- Sin limits: un pod puede consumir toda la CPU/memoria del nodo → mata a otros pods
- El HPA (lab 06) no funciona sin requests definidos (no puede calcular %)

---

## Paso 4: Política — Prohibir contenedores privilegiados

```yaml
# policies/disallow-privileged.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged
spec:
  validationFailureAction: Enforce
  rules:
    - name: no-privileged-containers
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
      validate:
        message: "Contenedores privilegiados están prohibidos. No usar securityContext.privileged: true, hostNetwork, hostPID, o hostIPC."
        pattern:
          spec:
            =(hostNetwork): false
            =(hostPID): false
            =(hostIPC): false
            containers:
              - =(securityContext):
                  =(privileged): false
                  =(runAsRoot): false
```

```bash
kubectl apply -f policies/disallow-privileged.yaml

# Probar (recordar lab 04, paso 8 — hostNetwork)
kubectl run priv-test --image=nginx:1.25-alpine \
  --overrides='{"spec":{"hostNetwork":true}}' \
  --requests='cpu=50m,memory=32Mi' --limits='cpu=100m,memory=64Mi'
# denied: hostNetwork prohibido
```

### ¿Por qué excluir kube-system?

Algunos add-ons (VPC CNI, kube-proxy) necesitan privilegios legítimos para gestionar
la red del nodo. Si los bloqueas, rompes el cluster. La exclusión es necesaria pero
debe ser explícita y documentada.

---

## Paso 5: Política — Generar default-deny NetworkPolicy

```yaml
# policies/generate-network-policy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-default-deny
spec:
  rules:
    - name: default-deny-on-new-namespace
      match:
        any:
          - resources:
              kinds:
                - Namespace
      exclude:
        any:
          - resources:
              names:
                - kube-system
                - kube-public
                - kyverno
                - default
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny-all
        namespace: "{{request.object.metadata.name}}"
        data:
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
              - Egress
```

```bash
kubectl apply -f policies/generate-network-policy.yaml

# Crear un namespace nuevo
kubectl create namespace team-alpha

# Verificar que se generó automáticamente
kubectl get networkpolicy -n team-alpha
# NAME               POD-SELECTOR   AGE
# default-deny-all   <none>         5s
```

### ¿Por qué Generate es tan poderoso?

- Cada namespace nuevo automáticamente tiene aislamiento de red
- Nadie puede "olvidarse" de crear la NetworkPolicy
- Conecta con el lab 07: default-deny como base, luego allow rules específicas
- Es declarativo: si borras la NetworkPolicy, Kyverno la regenera

---

## Paso 6: Política — Mutar para inyectar labels

```yaml
# policies/mutate-ownership-labels.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-ownership-labels
spec:
  rules:
    - name: add-team-label
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
                - DaemonSet
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              +(cost-center): "unknown"
              +(team): "{{request.object.metadata.namespace}}"
```

```bash
kubectl apply -f policies/mutate-ownership-labels.yaml

# Crear un deployment sin labels de ownership
kubectl create deployment test-mutate --image=nginx:1.25-alpine -n team-alpha

# Verificar que Kyverno inyectó los labels
kubectl get deploy test-mutate -n team-alpha --show-labels
# NAME          READY   ...   LABELS
# test-mutate   1/1     ...   app=test-mutate,cost-center=unknown,team=team-alpha
```

Esto conecta directamente con el lab 13 (FinOps): necesitas labels de ownership
para atribuir costos por equipo.

---

## Paso 7: Pod Security Standards (PSS)

### Niveles de Pod Security

| Nivel        | Permite                                             |
| ------------ | --------------------------------------------------- |
| `privileged` | Todo (sin restricciones)                            |
| `baseline`   | Bloquea escalaciones conocidas (hostNetwork, etc.)  |
| `restricted` | Lo más seguro: no root, read-only fs, drop all caps |

```bash
# Aplicar PSS a nivel namespace con labels
kubectl label namespace team-alpha \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
```

### ¿PSS o Kyverno?

| Aspecto       | Pod Security Standards (built-in) | Kyverno                         |
| ------------- | --------------------------------- | ------------------------------- |
| Instalación   | Nada (viene con K8s)              | Helm install                    |
| Granularidad  | 3 niveles fijos                   | Reglas custom ilimitadas        |
| Customización | No                                | Total                           |
| Mutación      | No                                | Sí                              |
| Generación    | No                                | Sí                              |
| Cuándo usar   | Baseline rápido                   | Policies de negocio específicas |

En producción: PSS como baseline + Kyverno para reglas específicas de tu org.

---

## Paso 8: KMS Encryption para Secrets

```bash
# Crear la KMS key
KMS_KEY_ID=$(aws kms create-key --description "EKS secrets encryption" \
  --region $REGION --query "KeyMetadata.KeyId" --output text)

aws kms create-alias \
  --alias-name alias/eks-secrets \
  --target-key-id $KMS_KEY_ID \
  --region $REGION

# Habilitar encryption en el cluster
aws eks associate-encryption-config \
  --cluster-name $CLUSTER_NAME \
  --encryption-config '[{
    "resources": ["secrets"],
    "provider": {"keyArn": "arn:aws:kms:'$REGION':'$ACCOUNT_ID':key/'$KMS_KEY_ID'"}
  }]' \
  --region $REGION
```

### ¿Por qué encriptar Secrets si ya están en etcd?

Sin KMS, los Secrets están encoded en base64 (no encriptados) en el storage de
etcd. Cualquiera con acceso al backup de etcd o al storage subyacente puede
leerlos. Con KMS, están encriptados at-rest con una key que tú controlas.

---

## Paso 9: ECR Image Scanning

```bash
# Verificar que el scanning está habilitado (lab 04 ya lo activó)
aws ecr describe-repositories --repository-names k8s-lab/identity-api \
  --query "repositories[0].imageScanningConfiguration"

# Ver resultados del último scan
aws ecr describe-image-scan-findings \
  --repository-name k8s-lab/identity-api \
  --image-id imageTag=<TAG> --region $REGION \
  --query "imageScanFindings.findingSeverityCounts"
```

### Política Kyverno para rechazar imágenes con CVEs críticos

```yaml
# policies/verify-image-scan.yaml (conceptual — requiere integración custom)
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: check-image-vulnerabilities
  annotations:
    policies.kyverno.io/description: >-
      Verifica que las imágenes solo provengan del ECR de la cuenta.
      El scanning se valida externamente.
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-ecr-images
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
      validate:
        message: "Las imágenes deben provenir del ECR de la cuenta ({{request.object.spec.containers[0].image}})."
        pattern:
          spec:
            containers:
              - image: "<ACCOUNT_ID>.dkr.ecr.*.amazonaws.com/*"
```

---

## Paso 10: PolicyReport y Exceptions

### Ver qué políticas están fallando

```bash
# PolicyReports muestran violations sin bloquear (modo Audit)
kubectl get policyreport -A
kubectl get clusterpolicyreport

# Detalle de un report
kubectl describe policyreport -n team-alpha
```

### Crear una excepción

```yaml
# policies/exception-monitoring.yaml
apiVersion: kyverno.io/v2beta1
kind: PolicyException
metadata:
  name: allow-monitoring-privileged
  namespace: kyverno
spec:
  exceptions:
    - policyName: disallow-privileged
      ruleNames:
        - no-privileged-containers
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - monitoring
          names:
            - "node-exporter-*"
```

### ¿Por qué las excepciones van en Git?

- Auditoría: quién aprobó la excepción, cuándo, por qué (commit message)
- Review: el PR de una excepción se revisa como cualquier cambio
- Reversibilidad: borrar la excepción es revert del commit
- Compliance: demuestras que las excepciones son deliberadas, no accidentes

---

## Troubleshooting

| Síntoma                                      | Causa probable                              | Fix                                               |
| -------------------------------------------- | ------------------------------------------- | ------------------------------------------------- |
| Todos los deploys fallan después de instalar | Política en Enforce sin excluir kube-system | Agregar exclusión o cambiar a Audit               |
| Kyverno webhook timeout                      | Kyverno pods no están ready                 | `kubectl get pods -n kyverno`, verificar recursos |
| PolicyReport no aparece                      | `background: false` en la política          | Cambiar a `background: true`                      |
| Generate no crea el recurso                  | Namespace excluido o permiso insuficiente   | Verificar RBAC del ServiceAccount de Kyverno      |
| Mutate no inyecta labels                     | El recurso ya tiene el label (+ prefix)     | `+(label)` solo aplica si no existe               |
| Pod rechazado pero no sé por qué política    | Mensaje genérico del webhook                | Revisar el `message` en la política               |

---

## 🔴 Destruir recursos del lab

```bash
# Políticas
kubectl delete clusterpolicy --all
kubectl delete policyexception -n kyverno --all

# Kyverno
helm uninstall kyverno -n kyverno
kubectl delete namespace kyverno

# Namespaces de prueba
kubectl delete namespace team-alpha
kubectl delete pod test-tagged test-latest with-resources 2>/dev/null

# KMS key (schedule deletion — no se borra inmediatamente)
aws kms schedule-key-deletion --key-id $KMS_KEY_ID \
  --pending-window-in-days 7 --region $REGION
```

---

## Lecciones aprendidas

1. **Audit antes de Enforce. Siempre.** Instalar una política en Enforce sin
   probar primero rompe todos los deploys existentes. PolicyReports te muestran
   qué se rompería sin romperlo.

2. **Las políticas son código y van en Git.** Igual que los manifiestos de
   aplicación. Con revisión, historial, y rollback. Una excepción que no está
   en Git no existe para compliance.

3. **Kyverno Generate cierra gaps de seguridad automáticamente.** No depende de
   que alguien "se acuerde" de crear la NetworkPolicy. Cada namespace nuevo la
   obtiene por diseño.

4. **Pod Security Standards no reemplaza a un policy engine.** PSS da 3 niveles
   fijos. Las reglas de tu organización (solo ECR, labels obligatorios, registries
   aprobados) necesitan algo más expresivo.

5. **La mutación es el poder silencioso.** Inyectar labels de ownership en todos
   los Deployments sin que los desarrolladores tengan que recordarlo es la
   diferencia entre "tenemos datos de costos" y "ojalá tuviéramos datos de costos".

6. **Las exclusiones deben ser el camino difícil.** Si excluir es tan fácil como
   agregar un label, la política pierde su sentido. Las excepciones deben
   requerir un PR aprobado por seguridad.
