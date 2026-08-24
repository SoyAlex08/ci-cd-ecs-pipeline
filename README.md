# Implementacion funcional de la arquitectura cloud (e-commerce, version MVP)

Implementacion real y funcional de la arquitectura propuesta en el modulo de
diseno (`arquitectura-ecommerce-cloud/entregable-arquitectura.html`), acotada
a los 5 requisitos de esta entrega: red/balanceador, app en contenedores,
base de datos gestionada, pipeline CI/CD y logs/alertas basicas.

Este repositorio evoluciona el pipeline construido en el modulo de CI/CD
(`ci-cd-ecs-pipeline`): la app dejo de ser un `index.html` estatico servido
por nginx y ahora es una API Flask que se conecta a una base de datos RDS
MySQL real, desplegada detras de un Application Load Balancer.

## Arquitectura implementada

```
Internet
   |
   v
Application Load Balancer (subredes publicas, 2 AZ)
   |  (solo puerto 80 abierto a 0.0.0.0/0)
   v
ECS Fargate service (2 tareas, puerto 8080, subredes publicas, security
   |                  group que solo acepta trafico del ALB en 8080; el
   |                  contenedor corre como usuario no-root y no puede
   |                  escuchar en el 80)
   v
RDS MySQL (subredes PRIVADAS, sin IP publica, security group que solo
            acepta trafico 3306 desde las tareas ECS)

CloudWatch Logs (contenedores) + CloudWatch Alarms -> SNS -> correo
GitHub Actions: push a main -> build/push imagen a ECR -> deploy en ECS
```

Security groups en cascada (`ecommerce-alb-sg` -> `ecommerce-app-sg` ->
`ecommerce-db-sg`): ningun recurso de computo o base de datos queda
alcanzable directamente desde internet, solo el ALB.

## Estructura

- `app.py`, `requirements.txt`, `Dockerfile` — API Flask que confirma la
  conexion a MySQL en `/` y expone `/health` para el health check del ALB.
- `ecs-task-definition.json` — plantilla de Task Definition (el pipeline la
  rellena con la imagen nueva y las variables de conexion a la BD).
- `.github/workflows/deploy.yml` — pipeline: build, push a ECR, render de la
  Task Definition (inyecta `DB_HOST`/`DB_NAME`/`DB_USER`/`DB_PASSWORD` desde
  GitHub Secrets) y deploy en ECS.
- `infra/setup-network.sh` — subredes publicas/privadas adicionales,
  security groups en cascada, ALB + target group + listener, cluster ECS,
  log group y repositorio ECR. Idempotente (se puede volver a correr).
- `infra/setup-rds.sh` — instancia RDS MySQL privada (`PubliclyAccessible=false`)
  en las subredes privadas. Genera una password aleatoria en `.db-password.txt`
  (no se sube a git).
- `infra/setup-ecs-service.sh` — registra una Task Definition placeholder
  (nginx) y crea el servicio ECS detras del ALB, para tener el servicio
  arriba antes de que corra el primer deploy del pipeline.
- `infra/setup-monitoring.sh` — topico SNS + suscripcion por correo, y 4
  alarmas de CloudWatch (CPU de ECS, hosts unhealthy del ALB, CPU y espacio
  libre de RDS).
- `infra/teardown.sh` — destruye ALB, servicio/cluster ECS, RDS, alarmas y
  topico SNS, para dejar de pagar por estos recursos al terminar de probar.
- `infra/cloudformation-template.yaml` — la misma arquitectura descrita como
  una sola plantilla de CloudFormation (IaC declarativo), equivalente a los
  4 scripts `setup-*.sh` de arriba. **No se pudo probar el despliegue**: el
  usuario IAM de este curso no tiene permisos de `cloudformation:*`. Se
  entrega como codigo revisado, documentando esa limitacion en el propio
  archivo.

## Como se desplego (orden real de ejecucion)

```bash
bash infra/setup-network.sh                       # red, SGs, ALB, cluster, ECR
bash infra/setup-rds.sh                           # RDS privada (tarda 5-10 min)
bash infra/setup-ecs-service.sh                   # servicio ECS con placeholder
gh secret set DB_HOST     --body "<endpoint-rds>"
gh secret set DB_NAME     --body "ecommercedb"
gh secret set DB_USER     --body "appadmin"
gh secret set DB_PASSWORD --body "$(cat .db-password.txt)"
bash infra/setup-monitoring.sh tu-correo@ejemplo.com
git push origin main                              # dispara el pipeline real
```

## Decisiones de seguridad y sus limitaciones

- **RDS sin acceso publico**: a diferencia del modulo de base de datos
  (`rds-mysql-demo`, publica pero restringida por IP), aqui la base de datos
  vive en subredes privadas y solo es alcanzable desde el security group de
  las tareas ECS.
- **Sin NAT Gateway**: para mantener el costo bajo en este MVP, las tareas
  ECS corren en subredes publicas con IP publica asignada (necesitan salida
  a internet para descargar la imagen de ECR y escribir logs), pero su
  security group solo acepta trafico entrante del ALB — no quedan expuestas
  directamente a internet aunque tengan IP publica.
- **Credenciales de BD sin Secrets Manager**: el usuario IAM de este curso
  no tiene permisos sobre Secrets Manager ni SSM Parameter Store. La
  password de RDS se genera localmente, se guarda solo en GitHub Secrets
  (cifrados) y el pipeline la inyecta como variable de entorno en la Task
  Definition al desplegar. Esto es mejor que dejarla en el codigo, pero es
  menos seguro que Secrets Manager: cualquier IAM principal con permiso
  `ecs:DescribeTaskDefinition` puede leerla. En un entorno real, este seria
  el primer punto a corregir en cuanto se disponga de esos permisos.
- **Permisos IAM ampliados a mano**: las policies administradas que trae el
  usuario del curso no alcanzaban para crear el ALB
  (`ec2:GetSecurityGroupsForVpc`, `ec2:CreateTags`) ni el topico SNS de
  alertas (`sns:CreateTopic`, `sns:Subscribe`, etc.) ni consultar la salud
  de los targets (`elasticloadbalancing:DescribeTargetHealth`). Se creo una
  policy adicional minima, `ecommerce-extra-ec2-elb-perms`, con exactamente
  esas acciones.

## Logs y alertas

- Logs de los contenedores en CloudWatch, log group `/ecs/ecommerce-app`.
- 4 alarmas (ver `infra/setup-monitoring.sh`) notifican por correo via SNS:
  CPU alta en ECS, hosts unhealthy en el ALB, CPU alta en RDS y espacio
  libre bajo en RDS. La suscripcion por correo debe confirmarse manualmente
  (enlace que envia AWS) antes de recibir notificaciones.

## Apagar todo al terminar

```bash
bash infra/teardown.sh
```

No borra el repositorio ECR, los roles IAM reutilizados entre modulos
(`ecsTaskExecutionRole`, `github-actions-ecs-deploy`) ni la policy IAM
minima agregada a mano; esos se pueden dejar entre modulos del curso.
