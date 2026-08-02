# Dominio 1: Cluster Architecture, Installation & Configuration (25%)

## Temas cubiertos

- [ ] Manage RBAC (Role, ClusterRole, RoleBinding, ClusterRoleBinding)
- [ ] Use kubeadm to install a cluster
- [ ] Manage a highly-available Kubernetes cluster
- [ ] Provision underlying infrastructure for a cluster
- [ ] Perform a version upgrade on a cluster using kubeadm
- [ ] Implement etcd backup and restore

---

## Ejercicio 1.1: RBAC — Crear usuario con permisos limitados

**Contexto:** El equipo de desarrollo necesita acceso al namespace `dev` pero solo para ver y crear pods y deployments.

**Task:**
1. Crea un namespace `dev`
2. Crea un Role `dev-role` en el namespace `dev` que permita: get, list, watch, create, delete en pods y deployments
3. Crea un RoleBinding `dev-binding` que asigne `dev-role` al usuario `developer`
4. Verifica con `kubectl auth can-i` que el usuario puede crear pods en `dev` pero NO en `default`

**Tiempo objetivo:** 5 minutos

---

## Ejercicio 1.2: RBAC — ClusterRole para lectura global

**Task:**
1. Crea un ClusterRole `global-reader` que permita get, list, watch en todos los recursos
2. Crea un ClusterRoleBinding que asigne `global-reader` al grupo `auditors`
3. Verifica que un miembro del grupo puede listar pods en cualquier namespace

**Tiempo objetivo:** 4 minutos

---

## Ejercicio 1.3: RBAC — ServiceAccount con permisos específicos

**Task:**
1. Crea un namespace `monitoring`
2. Crea un ServiceAccount `prometheus-sa` en `monitoring`
3. Crea un ClusterRole que permita get, list, watch en pods, nodes, services, endpoints
4. Vincula el ClusterRole al ServiceAccount
5. Crea un pod que use ese ServiceAccount y verifica que puede listar pods

**Tiempo objetivo:** 6 minutos

---

## Ejercicio 1.4: Cluster Upgrade con kubeadm

**Contexto:** Tu cluster está en v1.29.0 y necesitas actualizarlo a v1.30.0.

**Task:**
1. Verifica la versión actual: `kubectl get nodes`
2. Actualiza el control-plane:
   - `apt update && apt-cache madison kubeadm`
   - Actualiza kubeadm → `kubeadm upgrade plan` → `kubeadm upgrade apply v1.30.0`
   - Actualiza kubelet y kubectl
   - Restart kubelet
3. Drain un worker node
4. Actualiza kubeadm + kubelet en el worker
5. Uncordon el worker
6. Verifica que todos los nodos están en v1.30.0

**Tiempo objetivo:** 12 minutos

**Nota:** Este ejercicio requiere kubeadm cluster (no kind). Usa el Vagrantfile en `cluster-setup/kubeadm/` o practícalo mentalmente con los comandos.

---

## Ejercicio 1.5: etcd Backup and Restore

**Task:**
1. Identifica el endpoint de etcd y los certificados:
   ```bash
   kubectl -n kube-system describe pod etcd-<control-plane>
   ```
2. Realiza un backup de etcd:
   ```bash
   ETCDCTL_API=3 etcdctl snapshot save /tmp/etcd-backup.db \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key
   ```
3. Verifica el backup: `etcdctl snapshot status /tmp/etcd-backup.db`
4. Simula desastre: borra un deployment importante
5. Restaura desde el backup:
   ```bash
   ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup.db \
     --data-dir=/var/lib/etcd-restored
   ```
6. Actualiza el manifiesto estático de etcd para usar el nuevo data-dir
7. Verifica que el deployment eliminado vuelve a existir

**Tiempo objetivo:** 10 minutos

---

## Ejercicio 1.6: Certificates and kubeconfig

**Task:**
1. Genera una key + CSR para el usuario `new-admin`:
   ```bash
   openssl genrsa -out new-admin.key 2048
   openssl req -new -key new-admin.key -out new-admin.csr -subj "/CN=new-admin/O=system:masters"
   ```
2. Crea un CertificateSigningRequest en Kubernetes y apruébalo
3. Extrae el certificado aprobado
4. Crea un kubeconfig file con ese usuario
5. Prueba: `kubectl --kubeconfig=new-admin.kubeconfig get pods`

**Tiempo objetivo:** 8 minutos

---

## Ejercicio 1.7: Cluster Components Troubleshooting

**Task:**
1. El API server no responde. Investiga:
   - ¿Está corriendo el pod estático? `crictl ps`
   - Revisa logs: `/var/log/pods/` o `crictl logs`
   - Revisa manifiestos: `/etc/kubernetes/manifests/kube-apiserver.yaml`
2. El scheduler no está asignando pods. Diagnostica:
   - ¿Está corriendo? `kubectl -n kube-system get pods`
   - Revisa logs del scheduler
   - Verifica configuración

**Tiempo objetivo:** 8 minutos

---

## Quick Reference

```bash
# RBAC imperativo
kubectl create role <name> --verb=get,list --resource=pods -n <ns>
kubectl create rolebinding <name> --role=<role> --user=<user> -n <ns>
kubectl create clusterrole <name> --verb=get,list --resource=pods
kubectl create clusterrolebinding <name> --clusterrole=<role> --user=<user>

# Verificar permisos
kubectl auth can-i create pods --as=<user> -n <ns>
kubectl auth can-i --list --as=<user>

# etcd
ETCDCTL_API=3 etcdctl snapshot save <path> --endpoints --cacert --cert --key
ETCDCTL_API=3 etcdctl snapshot restore <path> --data-dir=<new-path>

# Upgrade
kubeadm upgrade plan
kubeadm upgrade apply v1.X.Y
systemctl daemon-reload && systemctl restart kubelet
```
