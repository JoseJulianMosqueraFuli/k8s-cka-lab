# Lab 04: Exponer de verdad — Ingress, HTTPS y tu propia imagen en ECR

## Resumen

Construyes un backend propio en Go, lo empujas a ECR, lo despliegas en el cluster,
y lo expones con un ALB (Application Load Balancer) por Ingress con HTTPS y
certificado de ACM. Routing por path: `/identity` y `/healthz`.

Este lab cierra el hueco más grande del nivel 1: los labs 01-03 terminan con un
NLB en capa 4, HTTP plano, y una imagen pública de Docker Hub. Nada de eso pasa en
producción.

**Se monta sobre:** el cluster del lab 02 (EC2) o 03 (Auto Mode).
**Costo estimado adicional:** ~$0.03/hr (ALB $0.0225 + ECR negligible)
**Tiempo:** ~2h

**Herramientas necesarias:**

- Docker (para construir la imagen)
- AWS CLI v2
- kubectl
- El AWS Load Balancer Controller ya instalado (lab 01) o integrado (lab 03)

**Conexión CKA:** `domains/03-services-networking` — Ingress, Services, DNS (20% del examen)

---

## Qué vas a construir

```
Internet → ALB (HTTPS, cert ACM) → Ingress → Service → Pods (tu imagen desde ECR)
                                      │
                                      ├─ /identity  → responde quién es el pod y qué credenciales tiene
                                      └─ /healthz   → health check del target group
```

El endpoint `/identity` llama a `sts:GetCallerIdentity` y devuelve:

- Sin credenciales configuradas → error explicando que el pod no tiene acceso a AWS
- Con Pod Identity o IRSA (lab 05) → el ARN del rol acotado

Así la misma imagen te sirve para los labs 04 y 05 sin reconstruirla.

---

## Paso 1: Crear el repositorio en ECR

```bash
REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_NAME=k8s-lab/identity-api

aws ecr create-repository \
  --repository-name $REPO_NAME \
  --region $REGION \
  --image-tag-mutability IMMUTABLE \
  --image-scanning-configuration scanOnPush=true
```

### ¿Por qué IMMUTABLE?

Con tag mutability habilitada, puedes hacer `docker push miapp:v1` dos veces con
contenido distinto. Nadie sabe qué hay realmente detrás de `:v1`. Con IMMUTABLE,
el segundo push falla. Te obliga a usar tags únicos (SHA del commit, timestamp),
que es lo que GitOps necesita para detectar cambios (lab 09).

### ¿Por qué scanOnPush?

Cada imagen que empujes se escanea automáticamente con Amazon Inspector buscando
CVEs. En el lab 11 (Guardrails) puedes rechazar despliegues de imágenes con CVEs
críticos. Aquí solo lo activas.

### Lifecycle policy (para que no se acumule basura)

```bash
aws ecr put-lifecycle-policy \
  --repository-name $REPO_NAME \
  --region $REGION \
  --lifecycle-policy-text '{
    "rules": [{
      "rulePriority": 1,
      "description": "Mantener solo las 10 imágenes más recientes",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": { "type": "expire" }
    }]
  }'
```

---

## Paso 2: Escribir el backend

Archivo `app/main.go`:

```go
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sts"
)

type IdentityResponse struct {
	Pod       string `json:"pod"`
	Node      string `json:"node"`
	Namespace string `json:"namespace"`
	Account   string `json:"account,omitempty"`
	Arn       string `json:"arn,omitempty"`
	UserID    string `json:"userId,omitempty"`
	Error     string `json:"error,omitempty"`
}

func identityHandler(w http.ResponseWriter, r *http.Request) {
	resp := IdentityResponse{
		Pod:       os.Getenv("POD_NAME"),
		Node:      os.Getenv("NODE_NAME"),
		Namespace: os.Getenv("POD_NAMESPACE"),
	}

	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		resp.Error = fmt.Sprintf("no credentials available: %v", err)
		writeJSON(w, http.StatusOK, resp)
		return
	}

	client := sts.NewFromConfig(cfg)
	output, err := client.GetCallerIdentity(context.Background(), &sts.GetCallerIdentityInput{})
	if err != nil {
		resp.Error = fmt.Sprintf("sts:GetCallerIdentity failed: %v", err)
		writeJSON(w, http.StatusOK, resp)
		return
	}

	resp.Account = *output.Account
	resp.Arn = *output.Arn
	resp.UserID = *output.UserId
	writeJSON(w, http.StatusOK, resp)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func main() {
	http.HandleFunc("/identity", identityHandler)
	http.HandleFunc("/healthz", healthHandler)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
```

Archivo `app/go.mod`:

```
module identity-api

go 1.22

require (
	github.com/aws/aws-sdk-go-v2 v1.32.0
	github.com/aws/aws-sdk-go-v2/config v1.28.0
	github.com/aws/aws-sdk-go-v2/service/sts v1.33.0
)
```

Después de crear `go.mod`, corre:

```bash
cd app && go mod tidy
```

### ¿Por qué `/identity` devuelve 200 siempre?

Si devolviera 500 cuando no hay credenciales, contaminarías las métricas del target
group (el ALB reportaría targets unhealthy). El health check apunta a `/healthz`,
que siempre es 200. Así separas "el pod está vivo" de "el pod tiene credenciales
AWS". Son dos preguntas distintas.

### ¿Por qué Go y no Python?

- Binario estático ~15 MB vs ~150 MB con Python+boto3
- Imagen distroless sin CVEs del sistema base (importa para el lab 11)
- Sin shell → obliga a usar `kubectl debug` (habilidad del lab 08)
- El startup es instantáneo (importa para el HPA del lab 06)

Si prefieres leer Python, funciona igual — solo que el artefacto enseña menos.

---

## Paso 3: Construir y empujar a ECR

```bash
# Dockerfile
cat > app/Dockerfile <<'EOF'
FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /identity-api .

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /identity-api /identity-api
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/identity-api"]
EOF

# Login a ECR
aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# Build con el SHA del commit como tag
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "local")
IMAGE=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME:$GIT_SHA

docker build -t $IMAGE app/
docker push $IMAGE

echo "Imagen: $IMAGE"
```

### ¿Por qué el SHA del commit como tag?

- `:latest` es mutable — Kubernetes no sabe si la imagen cambió
- Un tag por commit es inmutable, trazable, y permite rollback a cualquier versión
- GitOps (lab 09) detecta el cambio porque el tag en el manifiesto cambia
- Con `imagePullPolicy: IfNotPresent` (el default), un tag inmutable evita pulls
  innecesarios

### ¿Por qué distroless?

- Sin shell, sin package manager, sin herramientas → superficie de ataque mínima
- El escaneo de ECR sale limpio (o casi)
- Fuerza la disciplina de no depender de `kubectl exec` con bash

---

## Paso 4: Desplegar en el cluster

Archivo `manifests/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: identity-api
  namespace: apps
spec:
  replicas: 2
  selector:
    matchLabels:
      app: identity-api
  template:
    metadata:
      labels:
        app: identity-api
    spec:
      containers:
        - name: api
          image: <TU_IMAGE> # reemplaza con el output del paso 3
          ports:
            - containerPort: 8080
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
```

Archivo `manifests/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: identity-api
  namespace: apps
spec:
  type: ClusterIP
  selector:
    app: identity-api
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
```

```bash
kubectl create namespace apps 2>/dev/null || true
kubectl apply -f manifests/
```

### ¿Por qué ClusterIP y no LoadBalancer?

Porque el Ingress se encarga de la exposición. Un Service tipo ClusterIP es interno
al cluster; el ALB del Ingress le envía tráfico. Es el patrón correcto: un solo ALB
para múltiples servicios, en vez de un LB por servicio.

### ¿Qué hacen los probes?

| Probe              | Pregunta que responde           | Si falla...                                               |
| ------------------ | ------------------------------- | --------------------------------------------------------- |
| **readinessProbe** | ¿puede recibir tráfico?         | Se quita del Service (no recibe requests) pero sigue vivo |
| **livenessProbe**  | ¿está colgado sin recuperación? | Kubernetes lo reinicia                                    |

El ALB usa el readinessProbe como health check del target group automáticamente
(con la anotación correcta en el Ingress).

---

## Paso 5: Certificado en ACM

Necesitas un dominio para el certificado. Si no tienes uno, puedes usar el
DNS del ALB directamente (sin HTTPS propio) para el lab — pero aprender a
configurar ACM es el punto.

### Opción A: Tienes un dominio en Route 53

```bash
DOMAIN="lab.tudominio.com"

# Pedir certificado con validación DNS
CERT_ARN=$(aws acm request-certificate \
  --domain-name $DOMAIN \
  --validation-method DNS \
  --region $REGION \
  --query CertificateArn --output text)

echo "Certificado: $CERT_ARN"
echo "Ve a ACM en la consola → Certificate → Create records in Route 53"
```

Esperar ~2-5 min hasta que el status sea `Issued`.

### Opción B: Sin dominio propio

Salta este paso. El Ingress funcionará sin HTTPS (solo HTTP). En la anotación del
paso 6, omite `certificate-arn` y `ssl-redirect`.

---

## Paso 6: Crear el Ingress (ALB)

Archivo `manifests/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: identity-api
  namespace: apps
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
    # Descomenta si tienes certificado:
    # alb.ingress.kubernetes.io/certificate-arn: <TU_CERT_ARN>
    # alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443},{"HTTP":80}]'
    # alb.ingress.kubernetes.io/ssl-redirect: "443"
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /identity
            pathType: Prefix
            backend:
              service:
                name: identity-api
                port:
                  number: 80
          - path: /healthz
            pathType: Exact
            backend:
              service:
                name: identity-api
                port:
                  number: 80
```

```bash
kubectl apply -f manifests/ingress.yaml
```

Esperar ~2-3 min:

```bash
kubectl get ingress identity-api -n apps
# ADDRESS muestra el DNS del ALB
```

### ¿Qué hace cada anotación?

| Anotación                    | Efecto                                                                          |
| ---------------------------- | ------------------------------------------------------------------------------- |
| `scheme: internet-facing`    | ALB público (accesible desde internet)                                          |
| `target-type: ip`            | Registra IPs de pods como targets (obligatorio en Fargate, recomendado siempre) |
| `healthcheck-path: /healthz` | El ALB usa este endpoint para verificar que el pod está vivo                    |
| `certificate-arn`            | Asocia el certificado ACM para HTTPS                                            |
| `listen-ports`               | El ALB escucha en 443 y 80                                                      |
| `ssl-redirect: "443"`        | HTTP redirige automáticamente a HTTPS                                           |

### Diferencia Ingress vs Service tipo LoadBalancer

|                      | Service LoadBalancer    | Ingress                                |
| -------------------- | ----------------------- | -------------------------------------- |
| **Capa**             | 4 (TCP/UDP)             | 7 (HTTP/HTTPS)                         |
| **Un LB por...**     | Cada Service            | Todos los Services del Ingress (1 ALB) |
| **Routing por path** | No                      | Sí                                     |
| **HTTPS nativo**     | Solo con anotaciones    | Sí, con certificado ACM                |
| **Costo**            | Un NLB/CLB por servicio | Un ALB compartido                      |

---

## Paso 7: Verificar

```bash
ALB_DNS=$(kubectl get ingress identity-api -n apps -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Health check
curl -s http://$ALB_DNS/healthz | jq .
# {"status":"ok"}

# Identidad (sin credenciales configuradas)
curl -s http://$ALB_DNS/identity | jq .
# {
#   "pod": "identity-api-7f8b9c6d4-x2k9m",
#   "node": "ip-10-0-1-50.ec2.internal",
#   "namespace": "apps",
#   "error": "no credentials available: ..."
# }
```

Recarga varias veces `/identity` → el campo `pod` cambia. Estás viendo el
balanceo del ALB en acción. Con nginx no podías ver esto.

El campo `error` con "no credentials available" es el **comportamiento correcto**.
El pod no tiene credenciales AWS, porque:

- En EKS 1.30+ con AL2023, el hop limit de IMDS es 1 → los pods no alcanzan el
  metadata service del nodo
- No hay IRSA ni Pod Identity configurado (eso es el lab 05)

### Si no carga:

| Síntoma                 | Causa probable                     | Fix                                                                                                                      |
| ----------------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `<pending>` en ADDRESS  | El LB Controller no vio el Ingress | `kubectl logs -n kube-system deploy/aws-load-balancer-controller`                                                        |
| 502 Bad Gateway         | Los pods no pasan el health check  | `kubectl describe targetgroupbinding -n apps`                                                                            |
| 503 Service Unavailable | Los targets están unhealthy        | Verificar que readinessProbe funciona: `kubectl exec ... -- wget -qO- localhost:8080/healthz` (solo si no es distroless) |
| DNS no resuelve         | El ALB aún no propagó              | Esperar 2-3 min más                                                                                                      |

---

## Paso 8: (Opcional) Probar la escalada con hostNetwork

**SOLO PARA APRENDER, NUNCA EN PRODUCCIÓN.**

Esto demuestra por qué `hostNetwork: true` es peligroso y por qué el lab 11
(Kyverno) lo prohíbe:

```bash
kubectl run identity-host --image=$IMAGE --restart=Never -n apps \
  --overrides='{
    "spec": {
      "hostNetwork": true,
      "containers": [{
        "name": "identity-host",
        "image": "'$IMAGE'",
        "env": [
          {"name": "POD_NAME", "value": "identity-host"},
          {"name": "NODE_NAME", "value": "test"},
          {"name": "POD_NAMESPACE", "value": "apps"}
        ]
      }]
    }
  }'

# Esperar a que esté Running
kubectl wait --for=condition=Ready pod/identity-host -n apps --timeout=60s

# Ahora tiene credenciales del NODO:
kubectl port-forward pod/identity-host 8081:8080 -n apps &
curl -s http://localhost:8081/identity | jq .
# "arn": "arn:aws:sts::123456789012:assumed-role/eks-ec2-lab-node-role/..."

# Limpiar
kill %1
kubectl delete pod identity-host -n apps
```

El pod obtuvo el ARN del **node role** completo. Con eso puede:

- Descargar cualquier imagen de ECR de la cuenta
- Registrarse como nodo en el cluster
- Gestionar interfaces de red

Una línea de manifiesto (`hostNetwork: true`) le dio acceso a todo. Sin IRSA, sin
Pod Identity, sin haber pedido nada. Este es el motivo por el que:

- Se restringe `hostNetwork` con Kyverno (lab 11)
- Se usa IRSA/Pod Identity con roles acotados (lab 05)
- AWS puso el hop limit en 1 por defecto desde EKS 1.30

---

## Conceptos clave

### ECR y el permiso del node role

En los labs 02 y 03, el node role tiene `AmazonEC2ContainerRegistryPullOnly`. Eso
le permite al nodo descargar imágenes de **cualquier repo de ECR en tu cuenta**.
Hasta ahora no servía para nada porque usábamos `nginx:alpine` de Docker Hub.

En Fargate es distinto: quien jala la imagen es el **pod execution role**, no un
nodo. Son dos identidades distintas haciendo el mismo trabajo.

### Docker Hub rate limits

Docker Hub limita a 100 pulls por 6 horas para usuarios anónimos. Un cluster que
escala y jala imágenes públicas puede chocar con ese límite justo cuando más nodos
necesitas. Con ECR:

- Pull dentro de la misma región es gratis
- Sin rate limit
- El nodo ya tiene las credenciales (via instance profile)

Es un incidente clásico que se evita con registry privado.

### ALB vs NLB — cuándo usar cada uno

|                   | ALB                                    | NLB                              |
| ----------------- | -------------------------------------- | -------------------------------- |
| Capa              | 7 (HTTP/HTTPS)                         | 4 (TCP/UDP)                      |
| Routing           | Por path, host, headers, query strings | Solo por puerto                  |
| HTTPS termination | Sí, con certificado ACM                | Sí, pero sin routing inteligente |
| WebSockets        | Sí                                     | Sí                               |
| gRPC              | Sí                                     | Sí (passthrough)                 |
| IP estática       | No (solo DNS)                          | Sí                               |
| Costo             | $0.0225/hr + LCUs                      | $0.0225/hr + NLCUs               |
| Cuándo usar       | APIs HTTP, web apps, microservicios    | TCP puro, UDP, necesitas IP fija |

Para APIs HTTP (como este lab), ALB es lo correcto.

---

## 🔴 Destruir recursos del lab

```bash
kubectl delete -f manifests/
kubectl delete namespace apps

# ECR (opcional — mantener si vas a usar la imagen en labs 05-08)
aws ecr delete-repository --repository-name $REPO_NAME --region $REGION --force

# Certificado (si lo creaste)
aws acm delete-certificate --certificate-arn $CERT_ARN --region $REGION 2>/dev/null

# El cluster y VPC se borran con el destroy.sh del lab base (02 o 03)
```

---

## Lecciones aprendidas

1. **Un Ingress es un solo ALB para múltiples servicios.** No es un LB por servicio
   como con `type: LoadBalancer`. A escala, la diferencia de costo es grande.

2. **El health check conecta todo.** Si el readinessProbe falla, el pod sale del
   target group del ALB. Es una cadena: probe → Service → Ingress → ALB → usuario.

3. **ECR con tags inmutables fuerza la disciplina correcta.** Sin esto, GitOps no
   funciona, los rollbacks son ambiguos, y un `docker push :latest` accidental
   puede cambiar producción sin audit trail.

4. **Sin credenciales ≠ sin acceso.** `hostNetwork: true` le da al pod las
   credenciales del nodo. Es una línea de YAML. La defensa es IMDS hop limit + no
   permitir `hostNetwork` por política.

5. **La imagen que construiste aquí te sirve para los labs 05, 06, 08 y 09.**
   No la borres. Un solo endpoint (`/identity`) te enseña credenciales, balanceo,
   autoscaling y troubleshooting con la misma imagen.
