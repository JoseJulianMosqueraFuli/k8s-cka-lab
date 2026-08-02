# Dominio 4: Storage (10%)

## Temas cubiertos

- [ ] Understand storage classes, persistent volumes
- [ ] Understand volume mode, access modes, reclaim policies
- [ ] Understand persistent volume claims
- [ ] Know how to configure applications with persistent storage

---

## Ejercicio 4.1: PV y PVC — Static Provisioning

**Task:**
1. Crea un PersistentVolume `pv-data` de 1Gi, accessMode ReadWriteOnce, hostPath `/data/pv-data`
2. Crea un PersistentVolumeClaim `pvc-data` que pida 500Mi con accessMode ReadWriteOnce
3. Verifica que el PVC se vincula al PV: `kubectl get pv,pvc`
4. Crea un Pod que monte el PVC en `/app/data`
5. Escribe un archivo desde el pod: `echo "hello" > /app/data/test.txt`
6. Borra el pod, crea uno nuevo con el mismo PVC → el archivo persiste

**Tiempo objetivo:** 6 minutos

---

## Ejercicio 4.2: StorageClass — Dynamic Provisioning

**Task:**
1. Verifica qué StorageClasses existen: `kubectl get sc`
2. Crea un PVC `dynamic-pvc` de 2Gi que use la StorageClass `standard` (o la default)
3. Verifica que un PV se crea automáticamente
4. Crea un Deployment que use ese PVC
5. Cambia la reclaimPolicy de la StorageClass a `Retain`

**Tiempo objetivo:** 5 minutos

---

## Ejercicio 4.3: Volumes — emptyDir y hostPath

**Task:**
1. Crea un Pod con 2 containers que comparten un volumen `emptyDir`:
   - Container `writer`: escribe la fecha cada segundo a `/shared/log.txt`
   - Container `reader`: lee de `/shared/log.txt` con `tail -f`
2. Verifica con logs del reader que ve lo que el writer escribe
3. Crea un Pod con volumen `hostPath` tipo `DirectoryOrCreate` montado en `/host-data`
4. Escribe un archivo → verifica que existe en el nodo host

**Tiempo objetivo:** 6 minutos

---

## Ejercicio 4.4: Expand PVC

**Task:**
1. Crea un PVC de 1Gi con una StorageClass que tenga `allowVolumeExpansion: true`
2. Edita el PVC para pedir 2Gi: `kubectl edit pvc <name>`
3. Verifica que la expansión se completa

**Tiempo objetivo:** 4 minutos

---

## Quick Reference

```bash
# PV/PVC imperativo (no existe, hay que usar YAML)
# Template rápido:
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-name
spec:
  capacity:
    storage: 1Gi
  accessModes: [ReadWriteOnce]
  hostPath:
    path: /data/pv-name
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-name
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 500Mi
EOF

# Access modes: ReadWriteOnce (RWO), ReadOnlyMany (ROX), ReadWriteMany (RWX)
# Reclaim policies: Retain, Delete, Recycle (deprecated)
```
