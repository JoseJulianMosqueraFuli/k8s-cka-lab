# Speedrun — Kubectl Imperativo

Practica estos comandos hasta que los escribas sin pensar. En el CKA, cada segundo cuenta.

## Setup (pega esto al inicio del examen)

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"
export now="--force --grace-period 0"
```

---

## Pods (objetivo: <30 seg cada uno)

```bash
# Pod simple
k run nginx --image=nginx

# Pod con port
k run nginx --image=nginx --port=80

# Pod con labels
k run nginx --image=nginx -l app=web,tier=frontend

# Pod con command
k run busybox --image=busybox --command -- sh -c "sleep 3600"

# Pod con env vars
k run app --image=nginx --env="DB_HOST=postgres" --env="DB_PORT=5432"

# Pod con requests/limits
k run app --image=nginx $do > pod.yaml
# Editar YAML para agregar resources (no hay flag imperativo)

# Generar YAML sin crear
k run nginx --image=nginx $do > nginx.yaml

# Pod temporal para testing
k run test --rm -it --image=busybox:1.36 -- sh
k run test --rm -it --image=busybox -- wget -qO- http://svc-name:80
k run test --rm -it --image=busybox -- nslookup svc-name
```

---

## Deployments (objetivo: <30 seg)

```bash
# Crear
k create deployment webapp --image=nginx --replicas=3

# Escalar
k scale deployment webapp --replicas=5

# Update imagen
k set image deployment/webapp nginx=nginx:1.25

# Rollback
k rollout undo deployment/webapp
k rollout history deployment/webapp

# Exponer
k expose deployment webapp --port=80 --type=ClusterIP
k expose deployment webapp --port=80 --type=NodePort --name=webapp-np
```

---

## Services (objetivo: <20 seg)

```bash
# ClusterIP
k expose pod nginx --port=80 --name=nginx-svc

# NodePort
k expose deployment webapp --port=80 --type=NodePort

# Crear service sin selector (para external endpoint)
k create service clusterip my-svc --tcp=80:80 $do > svc.yaml
```

---

## ConfigMaps y Secrets (objetivo: <20 seg)

```bash
# ConfigMap desde literal
k create configmap app-config --from-literal=KEY1=value1 --from-literal=KEY2=value2

# ConfigMap desde archivo
k create configmap app-config --from-file=config.properties

# Secret
k create secret generic db-secret --from-literal=password=s3cr3t

# Secret TLS
k create secret tls tls-secret --cert=tls.crt --key=tls.key
```

---

## RBAC (objetivo: <30 seg)

```bash
# Role
k create role pod-reader --verb=get,list,watch --resource=pods -n dev

# RoleBinding
k create rolebinding dev-binding --role=pod-reader --user=developer -n dev

# ClusterRole
k create clusterrole node-reader --verb=get,list --resource=nodes

# ClusterRoleBinding
k create clusterrolebinding admin-binding --clusterrole=cluster-admin --user=admin

# ServiceAccount
k create sa monitoring-sa -n monitoring

# Binding a ServiceAccount
k create rolebinding sa-binding --role=pod-reader --serviceaccount=monitoring:monitoring-sa -n monitoring

# Verificar
k auth can-i create pods --as=developer -n dev
k auth can-i --list --as=developer
```

---

## Jobs y CronJobs (objetivo: <30 seg)

```bash
# Job
k create job backup --image=busybox -- sh -c "echo backup done"

# CronJob
k create cronjob hourly-backup --image=busybox --schedule="0 * * * *" -- sh -c "echo backup"
```

---

## Ingress (objetivo: <30 seg)

```bash
k create ingress myingress --rule="myapp.com/api*=api-svc:80" --rule="myapp.com/web*=web-svc:80"
```

---

## Namespace y Context

```bash
# Cambiar namespace por default (CRÍTICO en el examen, cada pregunta puede ser en distinto ns)
k config set-context --current --namespace=<ns>

# Cambiar de contexto (el examen usa múltiples clusters)
k config use-context <context-name>

# Ver contextos
k config get-contexts
```

---

## Tricks de velocidad

```bash
# Generar YAML base y editar
k run x --image=nginx $do > x.yaml && vim x.yaml && k apply -f x.yaml && rm x.yaml

# Buscar rápido en docs (dentro del examen)
# kubernetes.io/docs → buscar "NetworkPolicy" → copiar ejemplo

# Obtener YAML de recurso existente para copiar estructura
k get pod <name> -o yaml > template.yaml

# Ver todos los recursos de un namespace
k get all -n <ns>

# Borrar todo de un namespace
k delete all --all -n <ns>

# Explain (mejor que buscar en docs para campos)
k explain pod.spec.containers.resources
k explain deployment.spec.strategy
```
