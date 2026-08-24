#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Crea el topico SNS de alertas (suscrito por correo) y las alarmas basicas
# de CloudWatch: CPU alta en ECS, hosts no saludables en el ALB, y CPU /
# espacio libre bajos en RDS.
#
# El servicio ECS y el listener del ALB ya deben existir antes de correr
# este script para que las alarmas de ECS/ALB tengan a que apuntar.
# ---------------------------------------------------------------------------
set -euo pipefail

export MSYS2_ARG_CONV_EXCL="*"

TMP_DIR="$(dirname "$0")/.infra-tmp"
source "${TMP_DIR}/outputs.env"

ALERT_EMAIL="${1:?Uso: setup-monitoring.sh <correo-para-alertas>}"
SNS_TOPIC_NAME="ecommerce-alerts"

echo ">> Cuenta AWS: ${AWS_ACCOUNT_ID} / Region: ${AWS_REGION}"

# ---------------------------------------------------------------------------
# 1. Topico SNS + suscripcion por correo (el destinatario debe confirmarla
#    dando clic en el correo que le llega de AWS antes de recibir alertas).
# ---------------------------------------------------------------------------
SNS_TOPIC_ARN="$(aws sns create-topic --name "${SNS_TOPIC_NAME}" --region "${AWS_REGION}" \
  --query 'TopicArn' --output text)"

EXISTING_SUB="$(aws sns list-subscriptions-by-topic --topic-arn "${SNS_TOPIC_ARN}" --region "${AWS_REGION}" \
  --query "Subscriptions[?Endpoint=='${ALERT_EMAIL}'].SubscriptionArn" --output text)"

if [ -z "${EXISTING_SUB}" ]; then
  aws sns subscribe --topic-arn "${SNS_TOPIC_ARN}" --protocol email --notification-endpoint "${ALERT_EMAIL}" \
    --region "${AWS_REGION}" >/dev/null
  echo ">> Suscripcion creada para ${ALERT_EMAIL}. Debe confirmarse desde el correo que envia AWS."
else
  echo ">> Ya existia una suscripcion para ${ALERT_EMAIL}."
fi

echo ">> Topico SNS: ${SNS_TOPIC_ARN}"

# ---------------------------------------------------------------------------
# 2. Alarma: CPU alta en el servicio ECS
# ---------------------------------------------------------------------------
aws cloudwatch put-metric-alarm \
  --alarm-name "ecommerce-ecs-cpu-alta" \
  --alarm-description "CPU del servicio ECS por encima de 80% durante 10 minutos" \
  --namespace "AWS/ECS" --metric-name CPUUtilization \
  --dimensions Name=ClusterName,Value="${ECS_CLUSTER_NAME}" Name=ServiceName,Value=ecommerce-service \
  --statistic Average --period 300 --evaluation-periods 2 --threshold 80 \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" --ok-actions "${SNS_TOPIC_ARN}" \
  --region "${AWS_REGION}"

# ---------------------------------------------------------------------------
# 3. Alarma: hosts no saludables detras del ALB
# ---------------------------------------------------------------------------
ALB_ARN_SUFFIX="$(echo "${ALB_ARN}" | sed -E 's#.*loadbalancer/##')"
TG_ARN_SUFFIX="$(echo "${TG_ARN}" | sed -E 's#.*(targetgroup/.*)#\1#')"

aws cloudwatch put-metric-alarm \
  --alarm-name "ecommerce-alb-hosts-no-saludables" \
  --alarm-description "Al menos un target detras del ALB esta unhealthy" \
  --namespace "AWS/ApplicationELB" --metric-name UnHealthyHostCount \
  --dimensions Name=LoadBalancer,Value="${ALB_ARN_SUFFIX}" Name=TargetGroup,Value="${TG_ARN_SUFFIX}" \
  --statistic Maximum --period 60 --evaluation-periods 2 --threshold 0 \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" --ok-actions "${SNS_TOPIC_ARN}" \
  --region "${AWS_REGION}"

# ---------------------------------------------------------------------------
# 4. Alarmas de RDS: CPU alta y poco espacio libre
# ---------------------------------------------------------------------------
aws cloudwatch put-metric-alarm \
  --alarm-name "ecommerce-rds-cpu-alta" \
  --alarm-description "CPU de RDS por encima de 80% durante 10 minutos" \
  --namespace "AWS/RDS" --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=ecommerce-db \
  --statistic Average --period 300 --evaluation-periods 2 --threshold 80 \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" --ok-actions "${SNS_TOPIC_ARN}" \
  --region "${AWS_REGION}"

aws cloudwatch put-metric-alarm \
  --alarm-name "ecommerce-rds-espacio-bajo" \
  --alarm-description "Espacio libre en RDS por debajo de 2 GB" \
  --namespace "AWS/RDS" --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value=ecommerce-db \
  --statistic Average --period 300 --evaluation-periods 1 --threshold 2147483648 \
  --comparison-operator LessThanThreshold --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" --ok-actions "${SNS_TOPIC_ARN}" \
  --region "${AWS_REGION}"

echo ">> Alarmas creadas: ecommerce-ecs-cpu-alta, ecommerce-alb-hosts-no-saludables, ecommerce-rds-cpu-alta, ecommerce-rds-espacio-bajo"

echo "SNS_TOPIC_ARN=${SNS_TOPIC_ARN}" >> "${TMP_DIR}/outputs.env"
