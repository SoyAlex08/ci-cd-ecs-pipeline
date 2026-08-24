# aws-ecr-ecs-demo

App Docker minima (nginx + `index.html`) usada para practicar un pipeline de
CI/CD que construye la imagen, la sube a Amazon ECR y despliega
automaticamente en Amazon ECS (Fargate) en cada push a `main`.

## Estructura

- `Dockerfile`, `index.html` — la aplicacion.
- `.github/workflows/deploy.yml` — pipeline de GitHub Actions (build, push a ECR, deploy en ECS).
- `ecs-task-definition.json` — plantilla de Task Definition que el pipeline actualiza con la imagen nueva en cada ejecucion.
- `infra/setup-aws-infra.sh` — script documentado con los comandos AWS CLI para crear, **una sola vez y a mano**, la infraestructura previa (ECR, cluster/servicio ECS, roles IAM, red). El pipeline no lo ejecuta.

## Pasos para dejarlo funcionando

1. **Crear el repositorio en GitHub** y subir este contenido a la rama `main`.
2. **Aprovisionar AWS** (una vez, con tus propias credenciales `aws configure`):
   - Edita las variables `GITHUB_ORG` / `GITHUB_REPO` en `infra/setup-aws-infra.sh`.
   - Ejecuta el script: `bash infra/setup-aws-infra.sh`.
   - Anota el ARN del rol `github-actions-ecs-deploy` que imprime al final.
3. **Reemplazar placeholders**:
   - En `.github/workflows/deploy.yml`, sustituye `<AWS_ACCOUNT_ID>` por el ID real de tu cuenta AWS (o el ARN completo del rol).
   - En `ecs-task-definition.json`, sustituye `<AWS_ACCOUNT_ID>` en `executionRoleArn`.
4. **Hacer push a `main`** — esto dispara el workflow automaticamente (tambien se puede lanzar a mano desde la pestana Actions con "Run workflow").
5. **Verificar el despliegue**: en la consola de ECS, el servicio `demo-service` debe quedar `ACTIVE` con la tarea `RUNNING`; la IP publica de la tarea (puerto 80) debe mostrar la pagina "Hola desde AWS ECS".

## Que capturar para el PDF del entregable

1. Vista del repositorio en GitHub mostrando `.github/workflows/deploy.yml`.
2. Contenido del archivo `deploy.yml` (puede ser la misma vista del editor de GitHub).
3. Pestana **Actions** con la ejecucion del workflow en verde (exitosa), mostrando los pasos: build/push a ECR y deploy a ECS.
4. Consola de **Amazon ECR** con la imagen subida (tag con el SHA del commit).
5. Consola de **Amazon ECS** con el servicio y la tarea en estado `RUNNING`.
6. Navegador mostrando la app respondiendo en la IP publica de la tarea.

## Notas de seguridad

El pipeline usa **OIDC** (`aws-actions/configure-aws-credentials`) en vez de
access keys estaticas guardadas como secreto: GitHub Actions obtiene
credenciales temporales al asumir el rol `github-actions-ecs-deploy`, cuya
trust policy solo permite el `assume` desde este repositorio y la rama
`main`. Las policies adjuntas al rol en el script son policies administradas
por simplicidad; en un entorno real conviene una policy propia de permisos
minimos.
