# EKS vs ECS — cuándo usar cada uno

Documento de referencia para sustentar la decisión de orquestador de contenedores
en AWS. No es un tutorial — es el argumento que necesitas cuando alguien pregunta
"¿por qué EKS y no ECS?" (o al revés), y quieres una respuesta que no sea
"porque todo el mundo usa Kubernetes".

---

## No son la misma herramienta

ECS y EKS resuelven el mismo problema (correr contenedores en AWS) pero con
modelos fundamentalmente distintos:

|                       | ECS                                                       | EKS                                                                              |
| --------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------- |
| **Qué es**            | Orquestador propietario de AWS                            | Kubernetes upstream gestionado por AWS                                           |
| **API**               | Solo AWS (task definitions, services, capacity providers) | API estándar de Kubernetes, portable a GKE/AKS/on-prem                           |
| **Compute**           | EC2 o Fargate                                             | EC2, Fargate o Auto Mode                                                         |
| **Extensibilidad**    | Lo que AWS ofrezca como servicio                          | Todo el ecosistema CNCF (Helm, Argo, Kyverno, Prometheus, Operators, KEDA, etc.) |
| **Control plane**     | Gestionado por AWS, invisible, gratis                     | Gestionado por AWS, con versiones y add-ons que tú actualizas, $0.10/hr          |
| **Modelo de tenancy** | Cluster + Service como unidad                             | Cluster + Namespace como unidad                                                  |

La consecuencia directa: ECS te ata a AWS. EKS te ata a Kubernetes (que corre en
cualquier cloud). Ambas son formas de lock-in, pero la segunda es reversible entre
proveedores.

---

## Qué resuelve cada uno mejor

### ECS gana cuando:

**1. La prioridad es entregar rápido con poco equipo.**
Un servicio en ECS con Fargate es: task definition → service → target group. Son
15 minutos. No hay OIDC, no hay Helm, no hay controllers, no hay versiones del
control plane que se venzan.

**2. El equipo de plataforma es chico o no existe.**
ECS sin equipo de plataforma funciona. EKS sin equipo de plataforma se degrada
silenciosamente: nadie hace upgrades, nadie revisa policies, los controllers se
desactualizan, y un día se rompe todo.

**3. El blast radius importa más que la flexibilidad.**
En ECS cada servicio es una isla: su task definition, su despliegue, su rollback.
Un despliegue malo afecta ese servicio. En EKS, un controlador mal configurado
(Kyverno, Karpenter, VPC CNI) puede tumbar **todos** los servicios del cluster de
un golpe. El plano compartido es poder y es riesgo.

**4. No hay upgrade que planear.**
ECS no tiene "versiones" que se venzan. El control plane se actualiza solo, sin
disrupción, sin tu participación. En EKS, cada minor de Kubernetes tiene ~14 meses
de soporte estándar. Son dos upgrades al año como proyecto (2-4 semanas cada uno
contando preparación y testing). Si te pasas, el cluster cae a extended support:
$0.60/hr en vez de $0.10/hr — 6 veces más.

**5. La curva para los desarrolladores importa.**
Un desarrollador promedio entiende ECS en una tarde: "mi contenedor corre ahí,
tiene estos puertos, usa ese rol". Kubernetes tiene una curva de meses. Con 50
equipos, esa curva multiplicada es formación, soporte interno, errores evitables y
frustración. No todo el mundo quiere ni necesita saber qué es un
PodDisruptionBudget.

**6. Batch jobs y scheduled tasks.**
ECS scheduled tasks son triviales. En Kubernetes necesitas CronJobs + monitoring +
history management + cleanup de jobs completados. Funciona, pero es más piezas.

---

### EKS gana cuando:

**1. Multi-cloud o hybrid es una realidad, no una aspiración.**
Si hoy corres en AWS y en otro cloud (o en on-prem), Kubernetes es el denominador
común. Tus manifests migran. En ECS no tienes a dónde ir. Esta decisión es la más
difícil de revertir: si arrancas con ECS y después necesitas multi-cloud, migras
todo. Si arrancas con EKS "por si acaso" y nunca lo necesitas, pagaste la
complejidad por nada.

**2. Muchos equipos necesitan self-service.**
Un equipo nuevo necesita un namespace con sus cuotas, su RBAC, su NetworkPolicy, su
Argo CD project, y está operando. Sin tickets, sin pedir un cluster nuevo o acceso
a un ALB. El namespace es la unidad de tenancy. En ECS no existe un equivalente tan
limpio — el aislamiento es por cuenta AWS o por cluster ECS, ambos más pesados de
crear y de gobernar.

**3. La interfaz del desarrollador debe ser una sola, independiente del lenguaje.**
Un Deployment, un Service, un Ingress. No importa si el servicio es Java, Go,
Python o Node. No importa la región. El desarrollador escribe el mismo manifiesto,
usa el mismo `kubectl`, ve los mismos logs. La abstracción unificada tiene valor
real cuando hay 50 equipos que de otro modo reinventarían cada uno su propia forma
de desplegar.

**4. Necesitas funcionalidad que solo existe en el ecosistema Kubernetes.**

| Necesidad                                            | En EKS                       | En ECS                                                     |
| ---------------------------------------------------- | ---------------------------- | ---------------------------------------------------------- |
| Canary con evaluación automática de métricas         | Argo Rollouts / Flagger      | CodeDeploy tiene canary pero sin evaluación automática     |
| Policy-as-code en admisión (rechazar deploys malos)  | Kyverno / Gatekeeper         | Validar en el pipeline; no hay admission control nativo    |
| Custom controllers / operators                       | Sí, cualquier operador       | No existe el concepto                                      |
| Service mesh con mTLS transparente                   | Istio / Linkerd              | App Mesh (AWS dejó de desarrollarlo activamente)           |
| Escalar por métricas custom (cola SQS, lag de Kafka) | KEDA                         | Application Auto Scaling con custom metrics (más limitado) |
| Provisionar infra desde el mismo manifiesto          | Crossplane / ACK             | CloudFormation / CDK / Terraform (separados)               |
| Operators de bases de datos (failover declarativo)   | Vitess, CockroachDB, Strimzi | No aplica                                                  |

Si la respuesta a todo es "no necesito nada de eso", ECS cubre tu caso.

**5. Escala pura: bin-packing y unit economics.**
Por encima de ~200 servicios, EKS con Karpenter eligiendo instancias óptimas y
empaquetando pods al máximo es más barato que ECS+Fargate. Fargate cobra por pod
con un overhead de ~20-30% sobre lo que realmente usa. A esa escala, el control
fino del cómputo paga el costo del equipo de plataforma varias veces.

**6. El equipo ya sabe Kubernetes.**
Si tu equipo viene de GKE, de on-prem, o simplemente ya lo aprendió, pedirles que
aprendan ECS es agregar un modelo mental más sin ganancia. La expertise existente
tiene valor.

---

## Cuánto cuesta cada uno a diferentes escalas

A escala de startup (5 servicios), el control plane de EKS es un overhead visible.
A escala enterprise (300 servicios, $2M/mes en AWS), los $73/mes del control plane
son ruido. Lo que cuesta es otra cosa:

| Factor de costo                     | ECS                                  | EKS                                                    |
| ----------------------------------- | ------------------------------------ | ------------------------------------------------------ |
| Control plane                       | $0                                   | $73/mes por cluster ($438 si caes en extended support) |
| Equipo de plataforma                | 1-3 personas                         | 4-8 personas para operarlo en serio                    |
| Upgrades                            | Cero esfuerzo                        | 2-4 semanas por cluster, 2 veces al año                |
| Formación de desarrolladores        | Baja (1-2 días)                      | Alta (semanas, soporte ongoing)                        |
| Costo de cómputo                    | Fargate: premium ~20-30%. EC2: igual | Mismo compute pricing, mejor bin-packing a escala      |
| Herramientas complementarias        | Servicios gestionados de AWS ($$$)   | Open source que tú operas (equipo)                     |
| Costo de un incidente de plataforma | Acotado a un servicio                | Potencialmente todos los servicios del cluster         |

**El cálculo que importa:** a $200-400k por ingeniero de plataforma senior, la
diferencia entre un equipo de 2 y uno de 6 es $800k-$1.6M al año en salarios.
Eso es más relevante que cualquier línea de la factura de AWS.

---

## El filtro de decisión

Cinco preguntas en orden. La primera que respondas con certeza te da la respuesta:

**1. ¿Multi-cloud o hybrid es real hoy?**

- Sí → EKS. No hay alternativa.
- No, ni en el plan a 2 años → sigue a la 2.

**2. ¿Necesitas algo que solo existe en el ecosistema Kubernetes?**

- Sí (operators, canary con métricas, policy en admisión, KEDA) → EKS.
- No, o puedes vivir sin ello → sigue a la 3.

**3. ¿Tienes o vas a construir un equipo de plataforma que opere K8s?**

- Sí, con al menos 3-4 personas dedicadas → EKS es viable.
- No, o el equipo ya está al límite → ECS. K8s sin ownership dedicado es deuda
  técnica silenciosa.

**4. ¿Cuántos equipos de producto consumen la plataforma?**

- 50+ equipos, 200+ servicios → la abstracción unificada de K8s empieza a justificar su costo.
- <15 equipos, <50 servicios → ECS probablemente sobra y te ahorra la complejidad.
- Entre medias → depende de las respuestas anteriores.

**5. ¿Qué pesa más: tiempo al mercado hoy o flexibilidad en 3 años?**

- Entregar hoy, iterar después → ECS.
- Construir plataforma a largo plazo → EKS.

Si llegas al final sin certeza, la recomendación por defecto es **ECS hasta que
duela, y migrar cuando haya una razón concreta**. Migrar después cuesta, pero
cuesta menos que operar Kubernetes sin necesidad durante años.

---

## Patrones comunes en organizaciones grandes

**Unicornios y big tech (escala de Netflix, Uber, Spotify):**
Kubernetes (EKS o propio). La escala justifica equipos de plataforma de 20-50
personas. El ecosistema les da flexibilidad que ECS no tiene. Netflix empezó con
ECS y eventualmente complementó con Kubernetes para workloads específicos.

**Enterprise financiero / healthcare (bancos, aseguradoras):**
Dividido. Los que venían de infra on-prem con Kubernetes migran a EKS. Los que
nacieron en cloud y priorizan compliance + bajo blast radius se quedan con ECS
porque el upgrade invisible y el aislamiento por servicio les importan más.

**SaaS B2B medianos (50-500 empleados, 20-100 servicios):**
La mayoría que eligió EKS tiene 1-3 personas de plataforma sobrecargadas, haciendo
upgrades a las carreras, sin tiempo para policies ni observabilidad seria. Muchos
admiten en privado que ECS habría sido suficiente. Los que eligieron ECS funcionan
con menos drama pero a veces les falta una pieza y construyen workarounds.

**La tendencia 2025-2026:**
EKS Auto Mode cerró la brecha significativamente. Al eliminar la gestión de nodos,
controllers, drivers y upgrades de nodos, quitó ~60% de la carga operativa. La
pregunta "¿puedes mantener K8s?" se hizo más fácil de responder "sí". Pero la
curva para los desarrolladores que consumen la plataforma sigue igual.

---

## Los argumentos que no se sostienen

| Argumento                                              | Por qué no                                                                                                                             |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| "EKS porque es el estándar de la industria"            | Kubernetes es popular, no es obligatorio. Netflix corre en ECS. Popular ≠ necesario para tu caso                                       |
| "ECS porque es más simple"                             | Simple de arrancar ≠ simple de operar a escala. A 200 servicios sin namespace-as-tenancy, estás reinventando lo que K8s ya resuelve    |
| "EKS porque quizás necesitemos multi-cloud"            | Si "quizás" no tiene fecha ni presupuesto, no es un requisito, es una fantasía que cuesta real                                         |
| "ECS porque no queremos vendor lock-in con Kubernetes" | Kubernetes no es un vendor. Es un estándar abierto con múltiples implementaciones. El lock-in de ECS (AWS-only) es estrictamente mayor |
| "EKS porque nuestros devs quieren aprenderlo"          | CV-driven architecture. La plataforma existe para servir al producto, no para entrenar al equipo                                       |
| "ECS porque EKS es caro"                               | A escala, el costo del compute es idéntico y EKS puede ser más barato por bin-packing. El costo real es el equipo, no la factura       |

---

## Una comparación que ayuda: ECS es un sedán automático, EKS es un camión con caja manual

El sedán te lleva del punto A al B con poco esfuerzo. No necesitas saber mecánica.
Arranca y funciona. Pero si necesitas llevar 20 toneladas por una ruta que eliges
tú, necesitas el camión.

El error más común es comprar el camión "por si acaso" necesitas las 20 toneladas.
El segundo error más común es forzar las 20 toneladas en el sedán porque "ya
elegimos este y funciona bien".

---

## Por qué este repo usa EKS

1. Es un lab de CKA. Practicar Kubernetes en ECS no tiene sentido.
2. El objetivo es aprender a **operar** Kubernetes en AWS, no "desplegar
   contenedores de la forma más rápida posible".
3. Conocer EKS a profundidad te capacita para tomar la decisión EKS vs ECS con
   criterio. Conocer solo ECS no te da eso.

Pero ten claro: **"aprendí EKS" no es sinónimo de "la respuesta siempre es EKS"**.
A veces la respuesta responsable para un proyecto real es "esto no necesita
Kubernetes, ponlo en ECS y ahórrate la complejidad".

---

## Lecturas de referencia

- [ECS vs EKS: Complete Comparison & Decision Guide](https://middleware.io/blog/aws-ecs-vs-eks/) — comparación técnica actualizada
- [EKS Best Practices Guide](https://docs.aws.amazon.com/eks/latest/best-practices/) — si eliges EKS, cómo operarlo bien
- [ECS Best Practices Guide](https://docs.aws.amazon.com/AmazonECS/latest/bestpracticesguide/) — si eliges ECS, cómo operarlo bien
- [Kubernetes vs ECS: Cost, Skills, Portability Compared](https://www.learnersink.com/blog/kubernetes-vs-ecs-when-each-wins) — análisis de trade-offs económicos
