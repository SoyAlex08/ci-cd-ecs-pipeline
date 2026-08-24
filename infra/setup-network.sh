#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Aprovisiona la red (subredes publicas/privadas adicionales), los security
# groups en cascada (ALB -> ECS -> RDS), el Application Load Balancer y el
# cluster ECS para la implementacion funcional de la arquitectura de
# Semana 11 (version MVP: sin NAT Gateway, sin Secrets Manager/SSM porque
# el usuario IAM del curso no tiene esos permisos).
#
# Ejecutar a mano, una vez, con tus propias credenciales AWS.
# ---------------------------------------------------------------------------
set -euo pipefail

export MSYS2_ARG_CONV_EXCL="*"

TMP_DIR="$(dirname "$0")/.infra-tmp"
mkdir -p "${TMP_DIR}"
OUT_FILE="${TMP_DIR}/outputs.env"

AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# VPC reutilizada del modulo de RDS (10.0.0.0/16)
VPC_ID="vpc-03891a0d36a73171b"
PUBLIC_RT_ID="rtb-0d41fd79c64b1e420"   # ruta 0.0.0.0/0 -> IGW
PRIVATE_RT_ID="rtb-02b35c8f33c399e15"  # solo ruta local, sin salida a internet

PUBLIC_SUBNET_A="subnet-01b1e2a4f534de1f2"   # 10.0.1.0/24, us-east-1a (ya existe)
PRIVATE_SUBNET_A="subnet-0273cfdeb43af3ed9"  # 10.0.2.0/24, us-east-1b (ya existe)

PUBLIC_SUBNET_B_CIDR="10.0.3.0/24"
PUBLIC_SUBNET_B_AZ="us-east-1c"
PRIVATE_SUBNET_B_CIDR="10.0.4.0/24"
PRIVATE_SUBNET_B_AZ="us-east-1d"

ALB_SG_NAME="ecommerce-alb-sg"
APP_SG_NAME="ecommerce-app-sg"
DB_SG_NAME="ecommerce-db-sg"

ALB_NAME="ecommerce-alb"
TG_NAME="ecommerce-tg"
ECS_CLUSTER_NAME="ecommerce-cluster"

echo ">> Cuenta AWS: ${AWS_ACCOUNT_ID} / Region: ${AWS_REGION}"

find_or_create_subnet() {
  local cidr="$1" az="$2" rt_id="$3" map_public="$4" tag="$5"
  local sid
  sid="$(aws ec2 describe-subnets --filters Name=vpc-id,Values="${VPC_ID}" Name=cidr-block,Values="${cidr}" \
    --query 'Subnets[0].SubnetId' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
  if [ -z "${sid}" ] || [ "${sid}" = "None" ]; then
    sid="$(aws ec2 create-subnet --vpc-id "${VPC_ID}" --cidr-block "${cidr}" --availability-zone "${az}" \
      --region "${AWS_REGION}" --query 'Subnet.SubnetId' --output text)"
    aws ec2 associate-route-table --subnet-id "${sid}" --route-table-id "${rt_id}" --region "${AWS_REGION}" >/dev/null
    aws ec2 create-tags --resources "${sid}" --tags "Key=Name,Value=${tag}" --region "${AWS_REGION}" >/dev/null
    if [ "${map_public}" = "true" ]; then
      aws ec2 modify-subnet-attribute --subnet-id "${sid}" --map-public-ip-on-launch --region "${AWS_REGION}"
    fi
  fi
  echo "${sid}"
}

# ---------------------------------------------------------------------------
# 1. Segunda subred publica (para el ALB, requiere >= 2 AZ) y segunda subred
#    privada (para el DB subnet group de RDS, tambien requiere >= 2 AZ)
# ---------------------------------------------------------------------------
PUBLIC_SUBNET_B="$(find_or_create_subnet "${PUBLIC_SUBNET_B_CIDR}" "${PUBLIC_SUBNET_B_AZ}" "${PUBLIC_RT_ID}" true "ecommerce-public-b")"
PRIVATE_SUBNET_B="$(find_or_create_subnet "${PRIVATE_SUBNET_B_CIDR}" "${PRIVATE_SUBNET_B_AZ}" "${PRIVATE_RT_ID}" false "ecommerce-private-b")"

echo ">> Subredes publicas: ${PUBLIC_SUBNET_A}, ${PUBLIC_SUBNET_B}"
echo ">> Subredes privadas: ${PRIVATE_SUBNET_A}, ${PRIVATE_SUBNET_B}"

# ---------------------------------------------------------------------------
# 2. Security groups en cascada: internet -> ALB -> ECS -> RDS
#    Ningun recurso de computo/BD queda abierto directamente a 0.0.0.0/0.
# ---------------------------------------------------------------------------
find_or_create_sg() {
  local name="$1" desc="$2"
  local sgid
  sgid="$(aws ec2 describe-security-groups --filters Name=group-name,Values="${name}" Name=vpc-id,Values="${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
  if [ -z "${sgid}" ] || [ "${sgid}" = "None" ]; then
    sgid="$(aws ec2 create-security-group --group-name "${name}" --description "${desc}" --vpc-id "${VPC_ID}" \
      --region "${AWS_REGION}" --query 'GroupId' --output text)"
  fi
  echo "${sgid}"
}

ALB_SG_ID="$(find_or_create_sg "${ALB_SG_NAME}" "Trafico HTTP publico hacia el ALB")"
APP_SG_ID="$(find_or_create_sg "${APP_SG_NAME}" "Trafico hacia las tareas ECS, solo desde el ALB")"
DB_SG_ID="$(find_or_create_sg "${DB_SG_NAME}" "Trafico MySQL hacia RDS, solo desde las tareas ECS")"

# authorize-security-group-ingress falla si la regla ya existe; se ignora ese error puntual.
aws ec2 authorize-security-group-ingress --group-id "${ALB_SG_ID}" --protocol tcp --port 80 --cidr 0.0.0.0/0 \
  --region "${AWS_REGION}" 2>&1 | grep -q "InvalidPermission.Duplicate" && echo ">> Regla ALB 80 ya existia." || true

aws ec2 authorize-security-group-ingress --group-id "${APP_SG_ID}" --protocol tcp --port 8080 \
  --source-group "${ALB_SG_ID}" --region "${AWS_REGION}" 2>&1 | grep -q "InvalidPermission.Duplicate" && echo ">> Regla APP 8080 ya existia." || true

aws ec2 authorize-security-group-ingress --group-id "${DB_SG_ID}" --protocol tcp --port 3306 \
  --source-group "${APP_SG_ID}" --region "${AWS_REGION}" 2>&1 | grep -q "InvalidPermission.Duplicate" && echo ">> Regla DB 3306 ya existia." || true

echo ">> Security groups -> ALB: ${ALB_SG_ID} | APP: ${APP_SG_ID} | DB: ${DB_SG_ID}"

# ---------------------------------------------------------------------------
# 3. Application Load Balancer + Target Group + Listener
# ---------------------------------------------------------------------------
ALB_ARN="$(aws elbv2 describe-load-balancers --names "${ALB_NAME}" --region "${AWS_REGION}" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"

if [ -z "${ALB_ARN}" ] || [ "${ALB_ARN}" = "None" ]; then
  ALB_ARN="$(aws elbv2 create-load-balancer --name "${ALB_NAME}" \
    --subnets "${PUBLIC_SUBNET_A}" "${PUBLIC_SUBNET_B}" \
    --security-groups "${ALB_SG_ID}" --scheme internet-facing --type application \
    --region "${AWS_REGION}" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
fi

TG_ARN="$(aws elbv2 describe-target-groups --names "${TG_NAME}" --region "${AWS_REGION}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"

if [ -z "${TG_ARN}" ] || [ "${TG_ARN}" = "None" ]; then
  TG_ARN="$(aws elbv2 create-target-group --name "${TG_NAME}" --protocol HTTP --port 8080 \
    --vpc-id "${VPC_ID}" --target-type ip \
    --health-check-path /health --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
    --region "${AWS_REGION}" --query 'TargetGroups[0].TargetGroupArn' --output text)"
fi

LISTENER_ARN="$(aws elbv2 describe-listeners --load-balancer-arn "${ALB_ARN}" --region "${AWS_REGION}" \
  --query 'Listeners[0].ListenerArn' --output text 2>/dev/null || true)"

if [ -z "${LISTENER_ARN}" ] || [ "${LISTENER_ARN}" = "None" ]; then
  aws elbv2 create-listener --load-balancer-arn "${ALB_ARN}" --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn="${TG_ARN}" --region "${AWS_REGION}" >/dev/null
fi

ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "${ALB_ARN}" --region "${AWS_REGION}" \
  --query 'LoadBalancers[0].DNSName' --output text)"

echo ">> ALB: ${ALB_DNS}"

# ---------------------------------------------------------------------------
# 4. Cluster ECS (Fargate). El servicio se crea despues, cuando ya exista
#    la primera imagen en ECR (lo hace el pipeline de GitHub Actions).
# ---------------------------------------------------------------------------
aws ecs describe-clusters --clusters "${ECS_CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query "clusters[?status=='ACTIVE']" --output text | grep -q ACTIVE || \
aws ecs create-cluster --cluster-name "${ECS_CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

echo ">> Cluster ECS: ${ECS_CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# 5. Log group de CloudWatch para los contenedores
# ---------------------------------------------------------------------------
LOG_GROUP="/ecs/ecommerce-app"
aws logs describe-log-groups --log-group-name-prefix "${LOG_GROUP}" --region "${AWS_REGION}" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}']" --output text | grep -q "${LOG_GROUP}" || \
aws logs create-log-group --log-group-name "${LOG_GROUP}" --region "${AWS_REGION}"

# ---------------------------------------------------------------------------
# 6. Repositorio ECR para la imagen de la app
# ---------------------------------------------------------------------------
ECR_REPO_NAME="ecommerce-app"
aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1 || \
aws ecr create-repository --repository-name "${ECR_REPO_NAME}" --image-scanning-configuration scanOnPush=true \
  --region "${AWS_REGION}" >/dev/null

cat > "${OUT_FILE}" <<EOF
AWS_REGION=${AWS_REGION}
AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}
VPC_ID=${VPC_ID}
PUBLIC_SUBNET_A=${PUBLIC_SUBNET_A}
PUBLIC_SUBNET_B=${PUBLIC_SUBNET_B}
PRIVATE_SUBNET_A=${PRIVATE_SUBNET_A}
PRIVATE_SUBNET_B=${PRIVATE_SUBNET_B}
ALB_SG_ID=${ALB_SG_ID}
APP_SG_ID=${APP_SG_ID}
DB_SG_ID=${DB_SG_ID}
ALB_ARN=${ALB_ARN}
TG_ARN=${TG_ARN}
ALB_DNS=${ALB_DNS}
ECS_CLUSTER_NAME=${ECS_CLUSTER_NAME}
ECR_REPO_NAME=${ECR_REPO_NAME}
LOG_GROUP=${LOG_GROUP}
EOF

echo ">> Listo. Variables guardadas en ${OUT_FILE}"
