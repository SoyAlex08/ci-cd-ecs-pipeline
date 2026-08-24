#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Registra una Task Definition inicial (placeholder nginx, solo para poder
# levantar el servicio y que el ALB tenga targets saludables) y crea el
# servicio ECS Fargate detras del target group del ALB, en las subredes
# PUBLICAS (sin NAT Gateway en este MVP) pero con el security group
# ecommerce-app-sg, que solo acepta trafico desde el ALB.
#
# El pipeline de GitHub Actions vuelve a registrar la Task Definition con
# la imagen real (y las variables de conexion a la BD) en cada deploy.
# ---------------------------------------------------------------------------
set -euo pipefail

export MSYS2_ARG_CONV_EXCL="*"

TMP_DIR="$(dirname "$0")/.infra-tmp"
source "${TMP_DIR}/outputs.env"

ECS_SERVICE_NAME="ecommerce-service"
ECS_TASK_FAMILY="ecommerce-task"
CONTAINER_NAME="ecommerce-app"

echo ">> Cuenta AWS: ${AWS_ACCOUNT_ID} / Region: ${AWS_REGION}"

sed \
  -e "s|PLACEHOLDER_IMAGE|public.ecr.aws/nginx/nginx:latest|g" \
  -e 's|"environment": \[\]|"environment": [{"name":"PLACEHOLDER","value":"true"}]|' \
  "$(dirname "$0")/../ecs-task-definition.json" > "${TMP_DIR}/ecs-task-definition-initial.json"

aws ecs register-task-definition \
  --cli-input-json "file://${TMP_DIR}/ecs-task-definition-initial.json" \
  --region "${AWS_REGION}" >/dev/null

echo ">> Task definition inicial (placeholder nginx) registrada."

aws ecs describe-services --cluster "${ECS_CLUSTER_NAME}" --services "${ECS_SERVICE_NAME}" \
  --region "${AWS_REGION}" --query "services[?status=='ACTIVE']" --output text | grep -q ACTIVE || \
aws ecs create-service \
  --cluster "${ECS_CLUSTER_NAME}" \
  --service-name "${ECS_SERVICE_NAME}" \
  --task-definition "${ECS_TASK_FAMILY}" \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[${PUBLIC_SUBNET_A},${PUBLIC_SUBNET_B}],securityGroups=[${APP_SG_ID}],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=${TG_ARN},containerName=${CONTAINER_NAME},containerPort=80" \
  --health-check-grace-period-seconds 60 \
  --region "${AWS_REGION}" >/dev/null

echo ">> Servicio ECS creandose (o ya existente): ${ECS_SERVICE_NAME}"
echo ">> Prueba en un par de minutos: http://${ALB_DNS}"
