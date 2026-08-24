#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Aprovisiona la base de datos gestionada (RDS MySQL) en las subredes
# PRIVADAS (sin ruta a internet, PubliclyAccessible=false). Solo acepta
# trafico 3306 desde el security group de las tareas ECS (ecommerce-app-sg).
#
# A diferencia del modulo anterior (rds-mysql-demo), aqui la base de datos
# no es accesible desde ninguna IP externa: el unico camino es a traves de
# la app que corre dentro de la VPC.
#
# Requiere haber corrido antes infra/setup-network.sh (usa sus outputs).
# ---------------------------------------------------------------------------
set -euo pipefail

export MSYS2_ARG_CONV_EXCL="*"

TMP_DIR="$(dirname "$0")/.infra-tmp"
source "${TMP_DIR}/outputs.env"

DB_SUBNET_GROUP_NAME="ecommerce-db-subnets"
DB_INSTANCE_ID="ecommerce-db"
DB_NAME="ecommercedb"
DB_USERNAME="appadmin"
DB_INSTANCE_CLASS="db.t3.micro"
DB_ENGINE_VERSION="8.0"
DB_ALLOCATED_STORAGE=20

DB_PASSWORD_FILE="$(dirname "$0")/../.db-password.txt"
if [ ! -f "${DB_PASSWORD_FILE}" ]; then
  # Genera una password aleatoria (32 caracteres alfanumericos) si no existe.
  # (evitar "| head -c" aqui: en Git Bash/MSYS un pipe truncado por head
  # puede devolver exit 0 con salida vacia en vez de una senal SIGPIPE real)
  RAW_PASSWORD="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
  printf '%s' "${RAW_PASSWORD:0:32}" > "${DB_PASSWORD_FILE}"
  echo ">> Password generada en ${DB_PASSWORD_FILE} (NO se sube a git, ver .gitignore)"
fi
DB_PASSWORD="$(cat "${DB_PASSWORD_FILE}")"

echo ">> Cuenta AWS: ${AWS_ACCOUNT_ID} / Region: ${AWS_REGION}"

# ---------------------------------------------------------------------------
# 1. DB Subnet Group (subredes privadas, 2 AZ distintas)
# ---------------------------------------------------------------------------
aws rds describe-db-subnet-groups --db-subnet-group-name "${DB_SUBNET_GROUP_NAME}" \
  --region "${AWS_REGION}" >/dev/null 2>&1 || \
aws rds create-db-subnet-group \
  --db-subnet-group-name "${DB_SUBNET_GROUP_NAME}" \
  --db-subnet-group-description "Subredes privadas para ecommerce-db" \
  --subnet-ids "${PRIVATE_SUBNET_A}" "${PRIVATE_SUBNET_B}" \
  --region "${AWS_REGION}" >/dev/null

echo ">> DB subnet group: ${DB_SUBNET_GROUP_NAME}"

# ---------------------------------------------------------------------------
# 2. Instancia RDS MySQL, privada, sin Multi-AZ (MVP de bajo costo)
# ---------------------------------------------------------------------------
if ! aws rds describe-db-instances --db-instance-identifier "${DB_INSTANCE_ID}" \
  --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws rds create-db-instance \
    --db-instance-identifier "${DB_INSTANCE_ID}" \
    --db-name "${DB_NAME}" \
    --engine mysql \
    --engine-version "${DB_ENGINE_VERSION}" \
    --master-username "${DB_USERNAME}" \
    --master-user-password "${DB_PASSWORD}" \
    --db-instance-class "${DB_INSTANCE_CLASS}" \
    --allocated-storage "${DB_ALLOCATED_STORAGE}" \
    --db-subnet-group-name "${DB_SUBNET_GROUP_NAME}" \
    --vpc-security-group-ids "${DB_SG_ID}" \
    --backup-retention-period 1 \
    --no-multi-az \
    --no-publicly-accessible \
    --region "${AWS_REGION}" >/dev/null

  echo ">> Instancia RDS creandose (5-10 min). Revisa el estado con:"
  echo "   aws rds describe-db-instances --db-instance-identifier ${DB_INSTANCE_ID} --region ${AWS_REGION} --query 'DBInstances[0].DBInstanceStatus'"
else
  echo ">> La instancia ${DB_INSTANCE_ID} ya existe."
fi

{
  echo "DB_SUBNET_GROUP_NAME=${DB_SUBNET_GROUP_NAME}"
  echo "DB_INSTANCE_ID=${DB_INSTANCE_ID}"
  echo "DB_NAME=${DB_NAME}"
  echo "DB_USERNAME=${DB_USERNAME}"
} >> "${TMP_DIR}/outputs.env"
