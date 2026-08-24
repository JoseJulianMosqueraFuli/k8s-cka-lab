# Propuesta 01 — Descubrimiento de recursos robusto en los scripts de teardown

**Estado:** borrador, listo para abrir PR
**Alcance:** `eks/eks-*-lab/destroy.ps1`
**Motivación:** los scripts actuales pueden borrar el recurso equivocado, o no
borrar nada y reportar éxito. Ambos casos son silenciosos.

Este documento existe para no modificar los `.ps1` de otra persona sin discusión
previa. La implementación de referencia ya está en `eks/scripts/eks-teardown-lib.sh`
y en los `destroy.sh`, así que el PR sería portar esos cambios a PowerShell.

---

## Problema 1 — Filtros `tag:Name` con comodines

Los tres scripts localizan la Elastic IP así:

```powershell
# eks-ec2-lab/destroy.ps1
$eipAllocId = aws ec2 describe-addresses `
  --filters "Name=tag:Name,Values=*ec2-lab*" `
  --query "Addresses[0].AllocationId" --output text
```

Tres fallos distintos en cuatro líneas:

**a) El comodín puede matchear recursos ajenos.** `*lab*` en
`eks-fargate-lab/destroy.ps1` matchea cualquier EIP de la cuenta cuyo `Name`
contenga "lab". En una cuenta compartida o con otros experimentos, se libera una
IP que no es del lab.

**b) `[0]` asume que hay exactamente una.** Si el wizard de VPC creó más de una
EIP (por ejemplo si elegiste "NAT gateway in 1 per AZ" en vez de "in 1 AZ"), solo
se libera la primera. Las demás quedan cobrando y el script dice "LISTO!".

**c) El tag puede no existir.** El wizard "VPC and more" nombra la EIP con su
propio patrón derivado del name tag de la VPC. Si cambias el name tag del wizard
—o AWS cambia el patrón— el filtro devuelve `None`, el `if` no entra, y no se
libera nada. Sin error visible.

### Propuesta

No usar tags. La relación **NAT Gateway → Elastic IP** es la fuente de verdad, y
está en la API. Se capturan los `AllocationId` desde el NAT **antes** de borrarlo:

```powershell
$nats = aws ec2 describe-nat-gateways --region $Region `
  --filter "Name=vpc-id,Values=$vpcId" `
  --query "NatGateways[?State!='deleted'].NatGatewayId" --output text

$allocIds = @()
foreach ($nat in $nats -split '\s+' | Where-Object { $_ }) {
    $allocIds += aws ec2 describe-nat-gateways --region $Region --nat-gateway-ids $nat `
      --query "NatGateways[].NatGatewayAddresses[].AllocationId" --output text -split '\s+'
    aws ec2 delete-nat-gateway --nat-gateway-id $nat --region $Region | Out-Null
}
foreach ($nat in $nats -split '\s+' | Where-Object { $_ }) {
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids $nat --region $Region
}
# Ahora sí: liberar cada EIP, verificando que ya no esté asociada
foreach ($a in $allocIds | Sort-Object -Unique | Where-Object { $_ -and $_ -ne 'None' }) {
    $assoc = aws ec2 describe-addresses --allocation-ids $a --region $Region `
      --query "Addresses[0].AssociationId" --output text
    if ($assoc -eq 'None') { aws ec2 release-address --allocation-id $a --region $Region }
}
```

Aplica igual al VPC ID. En vez de buscarlo por nombre:

```powershell
# Antes
$vpcId = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=ec2-lab-vpc" ...

# Después: lo dice el propio cluster, resuelto ANTES de borrarlo
$vpcId = aws eks describe-cluster --name $Cluster --region $Region `
  --query "cluster.resourcesVpcConfig.vpcId" --output text
```

Con el filtro por nombre, dos labs con VPCs de nombre parecido se pisan. Con
`describe-cluster` no hay ambigüedad posible.

---

## Problema 2 — ARNs de policies hardcodeados

```powershell
aws iam detach-role-policy --role-name eks-ec2-lab-node-role `
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
# ... 2 más ...
aws iam delete-role --role-name eks-ec2-lab-node-role
```

Si durante el lab le agregaste una policy al rol (algo normal cuando estás
depurando permisos), `delete-role` falla con `DeleteConflict` porque queda una
policy adjunta. El script no revisa el exit code, así que continúa y reporta éxito
con el rol todavía ahí. En el siguiente lab, crear el rol falla con
`EntityAlreadyExists`.

### Propuesta

Listar lo que está adjunto y soltarlo, sin asumir cuáles son:

```powershell
foreach ($arn in (aws iam list-attached-role-policies --role-name $Role `
                  --query "AttachedPolicies[].PolicyArn" --output text) -split '\s+') {
    if ($arn) { aws iam detach-role-policy --role-name $Role --policy-arn $arn }
}
foreach ($p in (aws iam list-role-policies --role-name $Role `
                --query "PolicyNames" --output text) -split '\s+') {
    if ($p) { aws iam delete-role-policy --role-name $Role --policy-name $p }
}
```

Y sacar el rol de su instance profile, que es un paso que falta por completo en
`eks-ec2-lab` y `eks-automode-lab`. Un rol de nodos siempre está dentro de un
instance profile creado por EKS; sin este paso `delete-role` falla siempre:

```powershell
foreach ($prof in (aws iam list-instance-profiles-for-role --role-name $Role `
                   --query "InstanceProfiles[].InstanceProfileName" --output text) -split '\s+') {
    if ($prof) {
        aws iam remove-role-from-instance-profile --instance-profile-name $prof --role-name $Role
        aws iam delete-instance-profile --instance-profile-name $prof
    }
}
```

---

## Problema 3 — `Start-Sleep` fijo en vez de esperar de verdad

```powershell
Write-Host "Esperando 60s para que AWS elimine el Load Balancer..."
Start-Sleep -Seconds 60
```

60 segundos suele alcanzar. Cuando no alcanza, el ENI del Load Balancer sigue en la
VPC y el borrado de la VPC falla más adelante, cuando ya perdiste el contexto de por
qué. Es el tipo de fallo que aparece una vez de cada cinco corridas.

### Propuesta

Sondear hasta que el LB realmente no esté:

```powershell
for ($i = 0; $i -lt 30; $i++) {
    $v2 = (aws elbv2 describe-load-balancers --region $Region `
           --query "LoadBalancers[?VpcId=='$vpcId'].LoadBalancerArn" --output text) -split '\s+' `
          | Where-Object { $_ }
    $v1 = (aws elb describe-load-balancers --region $Region `
           --query "LoadBalancerDescriptions[?VPCId=='$vpcId'].LoadBalancerName" --output text) -split '\s+' `
          | Where-Object { $_ }
    if (-not $v2 -and -not $v1) { break }
    Start-Sleep -Seconds 15
}
```

El `elb` (Classic) hay que consultarlo aparte del `elbv2`: son APIs distintas, y el
lab de EC2 crea un Classic LB con el `kubectl expose`.

---

## Problema 4 — El borrado de la VPC queda manual

Los tres scripts terminan con:

```powershell
Write-Host "Ahora ve a la consola: VPC -> $vpcId -> Actions -> Delete VPC"
```

Dos consecuencias:

- **Costo.** Si te distraes, el NAT sigue cobrando $0.045/hr (~$32/mes). Es el
  recurso más caro que dejarías olvidado, más que el control plane.
- **Ese clic falla.** EKS deja ENIs en estado `available` y security groups
  gestionados por el cluster. La consola responde "has dependencies and cannot be
  deleted" sin decir cuáles. En ese punto la mayoría lo deja para después.

### Propuesta

Automatizar la cascada, en este orden estricto: VPC endpoints → NAT + EIP → ENIs
disponibles → IGW (detach y delete) → subnets → route tables no-main → security
groups no-default (vaciando reglas antes, porque se referencian entre sí) → VPC,
con reintentos.

Implementación completa en
[`eks/scripts/eks-teardown-lib.sh`](../scripts/eks-teardown-lib.sh),
función `vpc_delete_full`.

---

## Problema 5 — Recursos que sobreviven y nadie revisa

Ninguno de los tres scripts toca:

| Recurso                             | Por qué importa                                                                               |
| ----------------------------------- | --------------------------------------------------------------------------------------------- |
| Log groups `/aws/eks/<cluster>/*`   | Sobreviven al cluster y cobran almacenamiento indefinidamente                                 |
| Target groups huérfanos             | Quedan si el LB se borró antes que el Service                                                 |
| Stacks `eksctl-*` en CloudFormation | El de Fargate borra el service account con `eksctl`, pero si ese comando falla el stack queda |
| Volúmenes EBS `available`           | Solo aparecen si usaste PVCs (paso 10 del lab Auto Mode)                                      |
| PVCs antes del cluster              | En Auto Mode, borrar el cluster antes que los PVCs deja los volúmenes EBS cobrando            |

### Propuesta

Agregar `logs_delete_cluster_groups` y el borrado de PVCs antes del cluster
(ambos ya están en los `.sh`), y ejecutar `scripts/verify-clean.sh` al final como
red de seguridad. `verify-clean.sh` solo reporta, no borra, y devuelve exit code 1
si encuentra algo — así sirve tanto para revisar a mano como para CI.

---

## Resumen del PR propuesto

| Cambio                                               | Riesgo que elimina                                             |
| ---------------------------------------------------- | -------------------------------------------------------------- |
| VPC ID desde `describe-cluster` en vez de `tag:Name` | Borrar la VPC del lab equivocado                               |
| EIPs desde los `NatGatewayAddresses` del NAT         | Liberar una IP ajena, o no liberar ninguna en silencio         |
| Iterar todos los NAT/EIP en vez de `[0]`             | Recursos olvidados cobrando                                    |
| `list-attached-role-policies` en vez de ARNs fijos   | `DeleteConflict` silencioso en los roles                       |
| Quitar el rol de su instance profile                 | El `delete-role` de los roles de nodos nunca funciona sin esto |
| Sondeo de LBs en vez de `Start-Sleep 60`             | ENIs huérfanos que bloquean la VPC                             |
| Cascada completa de borrado de VPC                   | ~$32/mes de NAT olvidado                                       |
| Log groups, target groups, PVCs, stacks              | Costos residuales y colisiones en el siguiente lab             |
| Verificar exit codes y reportar fallos               | "LISTO!" cuando en realidad no                                 |

**Nota de compatibilidad:** todo se puede hacer con AWS CLI v2 sin dependencias
nuevas (sin `jq`), usando `--query` y `--output text`.
