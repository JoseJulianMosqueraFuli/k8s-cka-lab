# Dominio 5: Troubleshooting (30%) — EL MÁS IMPORTANTE

## Temas cubiertos

- [ ] Evaluate cluster and node logging
- [ ] Understand how to monitor applications
- [ ] Manage container stdout & stderr logs
- [ ] Troubleshoot application failure
- [ ] Troubleshoot cluster component failure
- [ ] Troubleshoot networking

---

## Ejercicio 5.1: Pod en CrashLoopBackOff

**Task:**
1. Aplica este pod roto:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: broken-pod
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "exit 1"]
   ```
2. Diagnostica: `kubectl describe pod broken-pod` + `kubectl logs broken-pod`
3. Identifica la causa: el container termina con exit code 1
4. Arregla: cambia el command a algo que no termine (ej: `sleep 3600`)

**Tiempo objetivo:** 3 minutos

---

## Ejercicio 5.2: Pod en ImagePullBackOff

**Task:**
1. Crea un pod con imagen inexistente: `kubectl run bad-img --image=nginx:99.99.99`
2. Diagnostica: `kubectl describe pod bad-img` → Events
3. Identifica: imagen no existe en el registry
4. Arregla: `kubectl set image pod/bad-img bad-img=nginx:1.25`

**Tiempo objetivo:** 2 minutos

---

## Ejercicio 5.3: Pod Pending — Insufficient Resources

**Task:**
1. Crea un pod que pida 100 CPU cores:
   ```yaml
   resources:
     requests:
       cpu: "100"
       memory: "128Mi"
   ```
2. El pod queda en Pending
3. Diagnostica: `kubectl describe pod` → Events → "Insufficient cpu"
4. Arregla: reduce el request a algo razonable (100m)

**Tiempo objetivo:** 3 minutos

---

## Ejercicio 5.4: Pod Pending — No matching node (taint/affinity)

**Task:**
1. Crea un pod con nodeSelector `gpu=true` (ningún nodo tiene ese label)
2. El pod queda en Pending
3. Diagnostica: `kubectl describe pod` → "didn't match node selector"
4. Arregla (opción A): agrega el label a un nodo
5. Arregla (opción B): quita el nodeSelector

**Tiempo objetivo:** 3 minutos

---

## Ejercicio 5.5: Service no alcanza Pods

**Task:**
1. Setup: Deployment `app` con label `app=myapp` + Service con selector `app=myap` (typo)
2. Problema: `curl <service-ip>` no responde
3. Diagnostica:
   - `kubectl get endpoints <svc>` → vacío (no matchea pods)
   - Compara labels del pod vs selector del service
4. Arregla: corrige el selector del Service

**Tiempo objetivo:** 4 minutos

---

## Ejercicio 5.6: Node NotReady

**Task:**
1. Simula un nodo NotReady: `systemctl stop kubelet` en un worker (o cordon + drain)
2. Diagnostica:
   - `kubectl get nodes` → NotReady
   - `kubectl describe node <node>` → Conditions
   - En el nodo: `journalctl -u kubelet` → ver errores
3. Arregla: `systemctl start kubelet`
4. Verifica: nodo vuelve a Ready

**Tiempo objetivo:** 5 minutos

---

## Ejercicio 5.7: Application Logs y Debugging

**Task:**
1. Un Deployment `api-server` está corriendo pero devuelve errores 500
2. Diagnostica:
   - `kubectl logs deploy/api-server` → ver errores
   - `kubectl logs deploy/api-server --previous` (si ha crasheado)
   - `kubectl exec -it <pod> -- sh` para investigar dentro del container
3. El error es: no puede conectar a la DB (env var mal configurada)
4. Arregla: edita el ConfigMap con el host correcto → restart pods

**Tiempo objetivo:** 5 minutos

---

## Ejercicio 5.8: Networking — Pod no puede resolver DNS

**Task:**
1. Un pod no puede hacer `nslookup kubernetes.default`
2. Diagnostica:
   - `kubectl exec <pod> -- cat /etc/resolv.conf` → ¿nameserver correcto?
   - `kubectl -n kube-system get pods -l k8s-app=kube-dns` → ¿CoreDNS corriendo?
   - `kubectl -n kube-system logs <coredns-pod>`
3. Posibles causas:
   - CoreDNS crasheando (ConfigMap corrupto)
   - Service kube-dns borrado
   - NetworkPolicy bloqueando egress al port 53

**Tiempo objetivo:** 6 minutos

---

## Ejercicio 5.9: Networking — Pod-to-Pod communication broken

**Task:**
1. Pod A no puede alcanzar Pod B por IP directa
2. Diagnostica:
   - `kubectl exec pod-a -- ping <pod-b-ip>` → timeout
   - ¿Están en el mismo nodo o diferente?
   - ¿Hay NetworkPolicies? `kubectl get netpol -A`
   - ¿CNI está funcionando? `kubectl -n kube-system get pods | grep calico/flannel/weave`
3. Posibles causas:
   - NetworkPolicy bloqueando
   - CNI pods crasheando
   - iptables rules corruptas

**Tiempo objetivo:** 6 minutos

---

## Ejercicio 5.10: Control Plane — kube-apiserver caído

**Task:**
1. `kubectl` no responde (connection refused)
2. Diagnostica en el control-plane node:
   - `crictl ps | grep kube-apiserver` → ¿está corriendo?
   - `crictl logs <container-id>` → ver errores
   - `cat /etc/kubernetes/manifests/kube-apiserver.yaml` → ¿configuración válida?
3. Causas comunes:
   - Certificado expirado
   - Port conflict
   - etcd no alcanzable
   - Typo en el manifiesto estático
4. Arregla el manifiesto → kubelet lo levanta automáticamente

**Tiempo objetivo:** 7 minutos

---

## Ejercicio 5.11: Control Plane — scheduler no asigna pods

**Task:**
1. Pods quedan en Pending pero no hay mensajes de "Insufficient resources"
2. Diagnostica:
   - `kubectl -n kube-system get pods | grep scheduler` → ¿corriendo?
   - Si no: revisa `/etc/kubernetes/manifests/kube-scheduler.yaml`
   - Si sí: `kubectl -n kube-system logs kube-scheduler-*`
3. Arregla y verifica que pods se schedulean

**Tiempo objetivo:** 5 minutos

---

## Metodología de troubleshooting (framework mental)

```
1. ¿Cuál es el SÍNTOMA? (pod pending, crashloop, service unreachable, node notready)
2. ¿DÓNDE está el problema? (pod, node, control-plane, networking)
3. RECOPILA INFO:
   - kubectl describe <resource>
   - kubectl logs <pod> [--previous]
   - kubectl get events --sort-by='.lastTimestamp'
   - En el nodo: journalctl -u kubelet, crictl ps/logs
4. IDENTIFICA la causa raíz
5. ARREGLA
6. VERIFICA que funciona
```

## Quick Reference

```bash
# Logs
kubectl logs <pod> [-c container] [--previous] [-f]
kubectl logs -l app=myapp --all-containers

# Describe (eventos al final)
kubectl describe pod/node/svc <name>

# Events
kubectl get events --sort-by='.lastTimestamp' -A
kubectl get events -n <ns> --field-selector reason=Failed

# Exec into pod
kubectl exec -it <pod> -- sh

# Node debugging
kubectl debug node/<node> -it --image=busybox
ssh <node-ip>
journalctl -u kubelet -f
crictl ps
crictl logs <container-id>

# Restart pods de un deployment
kubectl rollout restart deployment/<name>

# Force delete stuck pod
kubectl delete pod <name> --force --grace-period=0
```
