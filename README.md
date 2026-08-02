# k8s-cka-lab — Certified Kubernetes Administrator Practice Lab

Lab de práctica para el examen CKA (Certified Kubernetes Administrator) con escenarios progresivos tipo examen.

## Formato del examen CKA

- **Duración:** 2 horas
- **Formato:** 15-20 tasks performance-based (en terminal)
- **Passing score:** 66%
- **Entorno:** Cluster(s) reales, acceso via `kubectl`
- **Versión:** Kubernetes 1.30+
- **Recursos permitidos:** kubernetes.io/docs, kubernetes.io/blog, github.com/kubernetes (solo durante examen)

## Setup del lab

### Opción 1: kind (recomendado para local)

```bash
# Instalar kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

# Crear cluster multi-nodo (simula entorno CKA)
kind create cluster --config cluster-setup/kind-config.yaml --name cka-lab

# Verificar
kubectl get nodes
```

### Opción 2: minikube (multi-nodo)

```bash
minikube start --nodes 3 -p cka-lab --kubernetes-version=v1.30.0
```

### Opción 3: kubeadm (más realista, en VMs)

Ver `cluster-setup/kubeadm/` para Vagrantfile con 1 control-plane + 2 workers.

## Estructura del repo

```
k8s-cka-lab/
├── README.md
├── cluster-setup/                   # Configuración de clusters de práctica
│   ├── kind-config.yaml
│   ├── kubeadm/
│   └── scripts/
├── domains/                         # Ejercicios por dominio del examen
│   ├── 01-cluster-architecture/     # 25% del examen
│   ├── 02-workloads/                # 15% del examen
│   ├── 03-services-networking/      # 20% del examen
│   ├── 04-storage/                  # 10% del examen
│   ├── 05-troubleshooting/          # 30% del examen
│   └── README.md
├── mock-exams/                      # Exámenes simulados (timed)
│   ├── exam-01/
│   ├── exam-02/
│   └── exam-03/
├── speedrun/                        # Drills de velocidad (imperative commands)
│   ├── pods.md
│   ├── deployments.md
│   ├── services.md
│   ├── rbac.md
│   └── troubleshooting.md
├── cheatsheet/                      # Referencia rápida
│   ├── kubectl-commands.md
│   ├── yaml-templates.md
│   ├── vim-tips.md
│   └── exam-tips.md
└── solutions/                       # Soluciones (NO mirar antes de intentar)
    ├── domains/
    └── mock-exams/
```

## Dominios del examen CKA (peso)

| Dominio | Peso | Temas clave |
|---|---|---|
| **Cluster Architecture, Installation & Configuration** | 25% | kubeadm, RBAC, etcd backup/restore, cluster upgrade |
| **Workloads & Scheduling** | 15% | Deployments, DaemonSets, Jobs, scheduling, resource limits, scaling |
| **Services & Networking** | 20% | Services, Ingress, NetworkPolicies, DNS, CNI |
| **Storage** | 10% | PV, PVC, StorageClass, volume types |
| **Troubleshooting** | 30% | Node/pod issues, logs, networking, cluster components |

## Cómo usar este lab

1. **Primero:** Configura el cluster con kind (`cluster-setup/`)
2. **Por dominio:** Trabaja cada carpeta en `domains/` de mayor a menor peso
3. **Speedrun:** Practica comandos imperativos hasta que sean automáticos
4. **Mock exams:** Hazlos con timer de 2 horas, sin ver soluciones
5. **killer.sh:** Complementa con killer.sh (2 sesiones incluidas con el voucher CKA)

## Tips para el examen

- Usa alias: `alias k=kubectl` + `export do="--dry-run=client -o yaml"`
- Comandos imperativos > escribir YAML desde cero
- Practica con `vim` (el editor del entorno)
- Usa `kubectl explain` en vez de buscar en docs
- Lee TODA la pregunta antes de empezar
- Si un task te toma >10 min, márcalo y sigue

## Recursos complementarios

- **killer.sh** — Simulador oficial (viene con el voucher)
- **Kubernetes docs** — kubernetes.io/docs (lo único permitido en el examen)
- **Mumshad CKA course** (Udemy) — Labs interactivos en KodeKloud
- **Libro:** *Certified Kubernetes Administrator (CKA) Study Guide* — Benjamin Muschko (O'Reilly, 2022)
- **Libro:** *Kubernetes in Action* 2nd ed — Marko Lukša (Manning, 2024)
