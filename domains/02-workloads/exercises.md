# Dominio 2: Workloads & Scheduling (15%)

## Temas cubiertos

- [ ] Understand deployments and how to perform rolling updates and rollbacks
- [ ] Use ConfigMaps and Secrets to configure applications
- [ ] Know how to scale applications (manual, HPA)
- [ ] Understand resource limits and requests
- [ ] Awareness of manifest management and templating tools
- [ ] Configure pod scheduling: nodeSelector, affinity, taints/tolerations

---

## Ejercicio 2.1: Deployments — Rolling Update y Rollback

**Task:**
1. Crea un Deployment `webapp` con imagen `nginx:1.24`, 3 replicas
2. Verifica que los 3 pods están corriendo
3. Actualiza la imagen a `nginx:1.25` con un rolling update (maxSurge=1, maxUnavailable=0)
4. Verifica el rollout: `kubectl rollout status`
5. Ahora actualiza a una imagen mala: `nginx:nonexistent`
6. El rollout falla. Haz rollback a la revisión anterior
7. Verifica que la imagen es `nginx:1.25` de nuevo

**Tiempo objetivo:** 6 minutos

---

## Ejercicio 2.2: Jobs y CronJobs

**Task:**
1. Crea un Job `backup-job` que ejecute `echo "Backup completed at $(date)"` y termine
2. El Job debe completar 3 veces (completions: 3) con paralelismo de 2
3. Verifica que se completaron las 3 ejecuciones
4. Crea un CronJob `scheduled-backup` que corra cada 5 minutos con el mismo comando
5. El CronJob debe mantener máximo 3 jobs exitosos y 1 fallido en historial

**Tiempo objetivo:** 5 minutos

---

## Ejercicio 2.3: ConfigMaps y Secrets

**Task:**
1. Crea un ConfigMap `app-config` con:
   - `DB_HOST=postgres.default.svc.cluster.local`
   - `DB_PORT=5432`
   - `LOG_LEVEL=info`
2. Crea un Secret `app-secret` con:
   - `DB_PASSWORD=s3cr3tP4ss!`
   - `API_KEY=abc123xyz`
3. Crea un Pod `app-pod` con imagen `busybox` que:
   - Monte el ConfigMap como variables de entorno
   - Monte el Secret como archivos en `/etc/secrets/`
   - Ejecute `env | grep DB && cat /etc/secrets/DB_PASSWORD && sleep 3600`
4. Verifica que el pod puede leer ambos

**Tiempo objetivo:** 6 minutos

---

## Ejercicio 2.4: Resource Requests y Limits

**Task:**
1. Crea un namespace `limited` con un ResourceQuota:
   - Max CPU: 2 cores, Max Memory: 2Gi
   - Max pods: 10
2. Crea un LimitRange en el namespace con defaults:
   - Default request: 100m CPU, 128Mi memory
   - Default limit: 200m CPU, 256Mi memory
3. Crea un Deployment con 3 replicas sin especificar resources → verifica que toma los defaults
4. Intenta crear un pod pidiendo 4 cores → debe fallar por la quota
5. Verifica el estado de la quota: `kubectl describe resourcequota -n limited`

**Tiempo objetivo:** 7 minutos

---

## Ejercicio 2.5: Scheduling — nodeSelector y Affinity

**Task:**
1. Etiqueta el worker-1: `kubectl label node <worker-1> disk=ssd`
2. Crea un pod `ssd-pod` que use nodeSelector para correr SOLO en nodos con `disk=ssd`
3. Crea un Deployment `prefer-ssd` que use nodeAffinity preferida (preferred) para nodos con `disk=ssd`
4. Verifica que `ssd-pod` está en worker-1
5. Verifica que `prefer-ssd` prefiere worker-1 pero puede correr en otros

**Tiempo objetivo:** 5 minutos

---

## Ejercicio 2.6: Taints y Tolerations

**Task:**
1. Aplica un taint al worker-2: `kubectl taint nodes <worker-2> env=production:NoSchedule`
2. Crea un pod sin toleration → debe quedar en worker-1 o control-plane
3. Crea un pod con toleration para `env=production:NoSchedule` → puede correr en worker-2
4. Aplica un taint `NoExecute` al worker-1: `maintenance=true:NoExecute`
5. Observa cómo los pods existentes son desalojados
6. Limpia los taints

**Tiempo objetivo:** 5 minutos

---

## Ejercicio 2.7: DaemonSets

**Task:**
1. Crea un DaemonSet `log-collector` con imagen `fluentd:latest` en namespace `logging`
2. Verifica que hay un pod en cada worker node
3. El DaemonSet NO debe correr en el control-plane (usar toleration apropiada)
4. Agrega un nuevo nodo (si es posible) → verifica que el DaemonSet se despliega automáticamente

**Tiempo objetivo:** 5 minutos

---

## Ejercicio 2.8: Static Pods

**Task:**
1. Identifica la ruta de manifiestos estáticos en el nodo: revisa `--pod-manifest-path` en kubelet config
2. Crea un manifiesto de pod estático: `/etc/kubernetes/manifests/static-web.yaml` (nginx en port 80)
3. Verifica que el pod aparece en `kubectl get pods` (con sufijo del nodo)
4. Borra el archivo → el pod desaparece

**Tiempo objetivo:** 4 minutos

---

## Quick Reference

```bash
# Deployments imperativos
kubectl create deployment <name> --image=<img> --replicas=3
kubectl set image deployment/<name> <container>=<new-img>
kubectl rollout status deployment/<name>
kubectl rollout undo deployment/<name>
kubectl rollout history deployment/<name>
kubectl scale deployment/<name> --replicas=5

# ConfigMaps y Secrets
kubectl create configmap <name> --from-literal=KEY=VALUE
kubectl create secret generic <name> --from-literal=KEY=VALUE

# Labels y scheduling
kubectl label node <node> key=value
kubectl taint nodes <node> key=value:NoSchedule
kubectl taint nodes <node> key=value:NoSchedule-  # remove

# Jobs
kubectl create job <name> --image=busybox -- /bin/sh -c "echo done"
kubectl create cronjob <name> --image=busybox --schedule="*/5 * * * *" -- /bin/sh -c "echo done"
```
