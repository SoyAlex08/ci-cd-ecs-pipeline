#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Registra una Task Definition inicial y crea el servicio ECS Fargate detras
# del target group del ALB, en las subredes PUBLICAS (sin NAT Gateway en
# este MVP) pero con el security group ecommerce-app-sg, que solo acepta
# trafico desde el ALB (puerto 8080, ver Dockerfile: el contenedor corre
# como usuario no-root y no puede escuchar en el 80).
#
# El pipeline de GitHub Actions vuelve a registrar la Task Definition con
# la imagen real (y las variables de conexion a la BD) en cada deploy.
#
# El comando create-service falla si el load balancer (containerPort) ya
# quedo mal configurado en un intento anterior: en ese caso hay que borrar
# el servicio primero (aws ecs delete-service --force) porque ese campo es
# inmutable una vez creado el servicio.
# ---------------------------------------------------------------------------
set -euo pipefail

export MSYS2_ARG_CONV_EXCL="*"

TMP_DIR="$(dirname "$0")/.infra-tmp"
source "${TMP_DIR}/outputs.env"

ECS_SERVICE_NAME="ecommerce-service"
ECS_TASK_FAMILY="ecommerce-task"
CONTAINER_NAME="ecommerce-app"

echo ">> Cuenta AWS: ${AWS_ACCOUNT_ID} / Region: ${AWS_REGION}"

# Nota: la primera vez que se corrio este script (bootstrap desde cero) se
# uso una imagen placeholder de nginx en el puerto 80 antes de que existiera
# imagen propia en ECR. Una vez que el pipeline ya construyo y subio la
# imagen real (que escucha en 8080, ver Dockerfile), este script la reusa
# directamente para no repetir el problema de puerto privilegiado del
# placeholder.
DB_PASSWORD_FILE="$(dirname "$0")/../.db-password.txt"
DB_HOST="$(aws rds describe-db-instances --db-instance-identifier "${DB_INSTANCE_ID}" --region "${AWS_REGION}" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"
sed \
  -e "s|PLACEHOLDER_IMAGE|${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}:latest|g" \
  -e "s|\"environment\": \[\]|\"environment\": [{\"name\":\"DB_HOST\",\"value\":\"${DB_HOST:-}\"},{\"name\":\"DB_NAME\",\"value\":\"${DB_NAME:-}\"},{\"name\":\"DB_USER\",\"value\":\"${DB_USERNAME:-}\"},{\"name\":\"DB_PASSWORD\",\"value\":\"$(cat "${DB_PASSWORD_FILE}" 2>/dev/null)\"}]|" \
  "$(dirname "$0")/../ecs-task-definition.json" > "${TMP_DIR}/ecs-task-definition-initial.json"

aws ecs register-task-definition \
  --cli-input-json "file://${TMP_DIR}/ecs-task-definition-initial.json" \
  --region "${AWS_REGION}" >/dev/null

echo ">> Task definition inicial (imagen real + conexion a BD) registrada."

aws ecs describe-services --cluster "${ECS_CLUSTER_NAME}" --services "${ECS_SERVICE_NAME}" \
  --region "${AWS_REGION}" --query "services[?status=='ACTIVE']" --output text | grep -q ACTIVE || \
aws ecs create-service \
  --cluster "${ECS_CLUSTER_NAME}" \
  --service-name "${ECS_SERVICE_NAME}" \
  --task-definition "${ECS_TASK_FAMILY}" \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[${PUBLIC_SUBNET_A},${PUBLIC_SUBNET_B}],securityGroups=[${APP_SG_ID}],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=${TG_ARN},containerName=${CONTAINER_NAME},containerPort=8080" \
  --health-check-grace-period-seconds 60 \
  --region "${AWS_REGION}" >/dev/null

echo ">> Servicio ECS creandose (o ya existente): ${ECS_SERVICE_NAME}"
echo ">> Prueba en un par de minutos: http://${ALB_DNS}"
