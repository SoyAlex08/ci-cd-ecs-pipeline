#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Destruye TODOS los recursos creados por setup-network.sh, setup-rds.sh,
# setup-ecs-service.sh y setup-monitoring.sh, en el orden correcto para
# evitar dependencias colgadas. Ejecutar a mano cuando ya se termino de
# probar/entregar, para dejar de pagar por ALB, RDS y Fargate.
#
# No borra: el repositorio ECR (las imagenes ya construidas), el rol
# ecsTaskExecutionRole ni el rol github-actions-ecs-deploy (se reutilizan
# entre modulos del curso), ni la policy IAM minima agregada a mano.
# ---------------------------------------------------------------------------
set -uo pipefail

export MSYS2_ARG_CONV_EXCL="*"

TMP_DIR="$(dirname "$0")/.infra-tmp"
source "${TMP_DIR}/outputs.env"

echo ">> Borrando servicio ECS..."
aws ecs update-service --cluster "${ECS_CLUSTER_NAME}" --service ecommerce-service --desired-count 0 --region "${AWS_REGION}" >/dev/null 2>&1
aws ecs delete-service --cluster "${ECS_CLUSTER_NAME}" --service ecommerce-service --force --region "${AWS_REGION}" >/dev/null 2>&1

echo ">> Borrando cluster ECS..."
aws ecs delete-cluster --cluster "${ECS_CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1

echo ">> Borrando alarmas de CloudWatch..."
aws cloudwatch delete-alarms --alarm-names ecommerce-ecs-cpu-alta ecommerce-alb-hosts-no-saludables ecommerce-rds-cpu-alta ecommerce-rds-espacio-bajo --region "${AWS_REGION}" >/dev/null 2>&1

if [ -n "${SNS_TOPIC_ARN:-}" ]; then
  echo ">> Borrando topico SNS..."
  aws sns delete-topic --topic-arn "${SNS_TOPIC_ARN}" --region "${AWS_REGION}" >/dev/null 2>&1
fi

echo ">> Borrando listener y ALB..."
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "${ALB_ARN}" --region "${AWS_REGION}" --query 'Listeners[0].ListenerArn' --output text 2>/dev/null)
[ -n "${LISTENER_ARN}" ] && [ "${LISTENER_ARN}" != "None" ] && aws elbv2 delete-listener --listener-arn "${LISTENER_ARN}" --region "${AWS_REGION}" >/dev/null 2>&1
aws elbv2 delete-load-balancer --load-balancer-arn "${ALB_ARN}" --region "${AWS_REGION}" >/dev/null 2>&1

echo ">> Esperando a que el ALB termine de borrarse antes de borrar el target group y los SGs (puede tardar ~1-2 min)..."
aws elbv2 wait load-balancers-deleted --load-balancer-arns "${ALB_ARN}" --region "${AWS_REGION}" 2>/dev/null

aws elbv2 delete-target-group --target-group-arn "${TG_ARN}" --region "${AWS_REGION}" >/dev/null 2>&1

echo ">> Borrando instancia RDS (sin snapshot final, es un entorno de curso)..."
aws rds delete-db-instance --db-instance-identifier ecommerce-db --skip-final-snapshot --region "${AWS_REGION}" >/dev/null 2>&1
echo ">> RDS borrandose en segundo plano (5-10 min). Revisa con:"
echo "   aws rds describe-db-instances --db-instance-identifier ecommerce-db --region ${AWS_REGION}"

echo ">> Recursos de red (subredes, security groups, DB subnet group) y el VPC se dejan intactos"
echo "   porque se comparten con el modulo rds-mysql-demo. Bórralos a mano si ya no los necesitas:"
echo "   - Security groups: ${ALB_SG_ID}, ${APP_SG_ID}, ${DB_SG_ID}"
echo "   - DB subnet group: ${DB_SUBNET_GROUP_NAME:-ecommerce-db-subnets} (borrar DESPUES de que RDS termine de eliminarse)"
echo ""
echo ">> Listo. Verifica en la consola de AWS que ALB, ECS y RDS ya no aparezcan activos para no seguir pagando."
