# Dominio 3: Services & Networking (20%)

## Temas cubiertos

- [ ] Understand Services: ClusterIP, NodePort, LoadBalancer
- [ ] Understand Ingress controllers and Ingress resources
- [ ] Know how to configure and use CoreDNS
- [ ] Understand NetworkPolicies
- [ ] Choose an appropriate container network interface plugin (CNI)

---

## Ejercicio 3.1: Services — ClusterIP, NodePort, LoadBalancer

**Task:**
1. Crea un Deployment `web-app` con imagen `nginx`, 2 replicas, container port 80
2. Expón con un Service ClusterIP `web-svc` en port 80
3. Verifica acceso interno: `kubectl run test --rm -it --image=busybox -- wget -qO- web-svc`
4. Cambia el Service a NodePort (nodePort: 30080)
5. Verifica acceso externo: `curl <node-ip>:30080`
6. Crea un segundo Service de tipo LoadBalancer (en kind no tendrá external IP, pero la config es válida)

**Tiempo objetivo:** 6 minutos

---

## Ejercicio 3.2: Services — Multi-port y Headless

**Task:**
1. Crea un Deployment `multi-app` con un container que sirve en port 80 (http) y 443 (https)
2. Crea un Service con múltiples ports: http=80, https=443
3. Crea un Headless Service (`clusterIP: None`) para un StatefulSet `db` con 3 replicas
4. Verifica DNS: cada pod tiene su propio registro DNS `db-0.db-headless.default.svc.cluster.local`

**Tiempo objetivo:** 7 minutos

---

## Ejercicio 3.3: Ingress

**Task:**
1. Instala un Ingress controller (NGINX):
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
   ```
2. Crea dos Deployments: `app-v1` (nginx con custom index "v1") y `app-v2` (nginx con "v2")
3. Crea Services para cada uno
4. Crea un Ingress que enrute:
   - `myapp.local/v1` → app-v1-svc
   - `myapp.local/v2` → app-v2-svc
5. Prueba: `curl -H "Host: myapp.local" <ingress-ip>/v1`

**Tiempo objetivo:** 8 minutos

---

## Ejercicio 3.4: NetworkPolicies — Deny All + Allow specific

**Task:**
1. Crea un namespace `secure` con dos pods: `frontend` y `backend`
2. Crea una NetworkPolicy "deny-all" en `secure` que bloquee todo ingress
3. Verifica: `frontend` NO puede alcanzar `backend`
4. Crea una NetworkPolicy que permita ingress a `backend` SOLO desde pods con label `role=frontend`
5. Etiqueta `frontend` con `role=frontend`
6. Verifica: ahora `frontend` SÍ puede alcanzar `backend`
7. Crea un pod `attacker` SIN el label → NO puede alcanzar `backend`

**Tiempo objetivo:** 8 minutos

---

## Ejercicio 3.5: NetworkPolicies — Egress

**Task:**
1. Crea una NetworkPolicy que bloquee todo egress del namespace `restricted`
2. Los pods en `restricted` NO pueden resolver DNS ni alcanzar internet
3. Agrega una regla que permita egress SOLO al puerto 53 (DNS) y al namespace `database`
4. Verifica: pods pueden resolver DNS y alcanzar pods en `database`, pero no internet

**Tiempo objetivo:** 7 minutos

---

## Ejercicio 3.6: CoreDNS — Troubleshooting

**Task:**
1. Un pod no puede resolver nombres. Diagnostica:
   - ¿CoreDNS está corriendo? `kubectl -n kube-system get pods -l k8s-app=kube-dns`
   - ¿El Service `kube-dns` existe? `kubectl -n kube-system get svc kube-dns`
   - ¿El pod tiene el DNS correcto? `kubectl exec <pod> -- cat /etc/resolv.conf`
2. Verifica resolución: `kubectl exec <pod> -- nslookup kubernetes.default`
3. Revisa el ConfigMap de CoreDNS: `kubectl -n kube-system get cm coredns -o yaml`
4. Agrega un custom DNS entry en CoreDNS (hosts plugin) para `myservice.custom → 10.0.0.50`

**Tiempo objetivo:** 6 minutos

---

## Ejercicio 3.7: Service Endpoints Debugging

**Task:**
1. Crea un Service `broken-svc` que apunte a un selector que NO matchea ningún pod
2. Verifica: `kubectl get endpoints broken-svc` → vacío
3. Arregla el selector para que matchee pods existentes
4. Verifica: los endpoints ahora muestran IPs de los pods

**Tiempo objetivo:** 4 minutos

---

## Quick Reference

```bash
# Services imperativo
kubectl expose deployment <name> --port=80 --target-port=80 --type=ClusterIP
kubectl expose deployment <name> --port=80 --type=NodePort
kubectl expose pod <name> --port=80 --name=<svc-name>

# DNS interno
<service>.<namespace>.svc.cluster.local
<pod-ip-dashes>.<namespace>.pod.cluster.local

# NetworkPolicies
# Recuerda: si no hay NP → todo permitido
# Si hay al menos 1 NP de ingress → deny-all-ingress implícito para ese pod
# Si hay al menos 1 NP de egress → deny-all-egress implícito

# Ingress
kubectl create ingress <name> --rule="host/path=service:port"

# Debug networking
kubectl run test --rm -it --image=busybox:1.36 -- sh
wget -qO- --timeout=2 <service>:<port>
nslookup <service>
```
