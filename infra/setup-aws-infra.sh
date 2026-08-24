#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Aprovisionamiento manual de la infraestructura AWS necesaria ANTES de que
# el pipeline de GitHub Actions pueda desplegar la app.
#
# Ejecutar UNA SOLA VEZ, a mano, con tus propias credenciales AWS
# (aws configure). No lo ejecuta el pipeline. Requiere permisos de
# administrador o un rol con permisos sobre ECR, ECS, IAM, CloudWatch Logs,
# EC2 (para VPC/security groups) e IAM OIDC providers.
#
# Ajusta las variables de la seccion siguiente a tu cuenta/proyecto.
# ---------------------------------------------------------------------------
set -euo pipefail

# En Git Bash (Windows), MSYS reescribe argumentos que parecen rutas POSIX
# absolutas (ej. "/ecs/demo-task") antes de pasarlos al aws.exe nativo,
# lo que rompe nombres de recursos AWS que empiezan con "/". Se excluye ese
# prefijo de la conversion. No afecta a Linux/Mac (la variable simplemente
# no se usa alli).
export MSYS2_ARG_CONV_EXCL="/ecs"

# Carpeta temporal relativa (no absoluta) para los JSON de trust policy,
# asi se evita la ambiguedad de "/tmp" entre Git Bash y Windows nativo.
TMP_DIR="$(dirname "$0")/.infra-tmp"
mkdir -p "${TMP_DIR}"

AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

ECR_REPO_NAME="aws-ecr-ecs-demo"
ECS_CLUSTER_NAME="demo-cluster"
ECS_SERVICE_NAME="demo-service"
ECS_TASK_FAMILY="demo-task"
CONTAINER_NAME="demo-app"
LOG_GROUP="/ecs/${ECS_TASK_FAMILY}"

GITHUB_ORG="SoyAlex08"
GITHUB_REPO="ci-cd-ecs-pipeline"

echo ">> Cuenta AWS: ${AWS_ACCOUNT_ID} / Region: ${AWS_REGION}"

# ---------------------------------------------------------------------------
# 1. Repositorio en Amazon ECR (registry de la imagen Docker)
# ---------------------------------------------------------------------------
aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" \
  --region "${AWS_REGION}" >/dev/null 2>&1 || \
aws ecr create-repository \
  --repository-name "${ECR_REPO_NAME}" \
  --image-scanning-configuration scanOnPush=true \
  --region "${AWS_REGION}"

# ---------------------------------------------------------------------------
# 2. Log group de CloudWatch para los contenedores de la tarea ECS
# ---------------------------------------------------------------------------
aws logs describe-log-groups --log-group-name-prefix "${LOG_GROUP}" \
  --region "${AWS_REGION}" --query "logGroups[?logGroupName=='${LOG_GROUP}']" \
  --output text | grep -q "${LOG_GROUP}" || \
aws logs create-log-group --log-group-name "${LOG_GROUP}" --region "${AWS_REGION}"

# ---------------------------------------------------------------------------
# 3. Rol de ejecucion de tareas ECS (ecsTaskExecutionRole)
#    Permite a ECS descargar la imagen de ECR y escribir logs en CloudWatch.
# ---------------------------------------------------------------------------
if ! aws iam get-role --role-name ecsTaskExecutionRole >/dev/null 2>&1; then
  cat > "${TMP_DIR}/ecs-trust-policy.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ecs-tasks.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF
  aws iam create-role \
    --role-name ecsTaskExecutionRole \
    --assume-role-policy-document "file://${TMP_DIR}/ecs-trust-policy.json"

  aws iam attach-role-policy \
    --role-name ecsTaskExecutionRole \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
fi

# ---------------------------------------------------------------------------
# 4. OIDC provider de GitHub + rol que asume el workflow (sin access keys)
# ---------------------------------------------------------------------------
OIDC_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_ARN}" >/dev/null 2>&1; then
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
fi

if ! aws iam get-role --role-name github-actions-ecs-deploy >/dev/null 2>&1; then
  # El "*" en el sub tolera que GitHub agregue sufijos "@<id>" al org/repo
  # cuando la cuenta o el repositorio fueron renombrados
  # (ej. "repo:org@165087714/repo@1344516810:ref:refs/heads/main").
  cat > "${TMP_DIR}/github-trust-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": { "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}*/${GITHUB_REPO}*:ref:refs/heads/main" }
    }
  }]
}
EOF
  aws iam create-role \
    --role-name github-actions-ecs-deploy \
    --assume-role-policy-document "file://${TMP_DIR}/github-trust-policy.json"

  # Permisos minimos para build/push a ECR y deploy en ECS.
  # Para el curso se usan policies administradas; en produccion conviene
  # una policy propia mas restrictiva (least privilege).
  aws iam attach-role-policy --role-name github-actions-ecs-deploy \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
  aws iam attach-role-policy --role-name github-actions-ecs-deploy \
    --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess
  aws iam attach-role-policy --role-name github-actions-ecs-deploy \
    --policy-arn arn:aws:iam::aws:policy/IAMReadOnlyAccess
fi

echo ">> Rol para GitHub Actions: arn:aws:iam::${AWS_ACCOUNT_ID}:role/github-actions-ecs-deploy"
echo "   Copia este ARN en .github/workflows/deploy.yml (campo role-to-assume)"
echo "   y en ecs-task-definition.json (campo executionRoleArn)."

# ---------------------------------------------------------------------------
# 5. Red: subnets de la VPC default + security group (puerto 80 abierto)
# ---------------------------------------------------------------------------
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "${AWS_REGION}")"

# Algunas cuentas no tienen VPC "default" (se borro o nunca se creo).
# En ese caso se usa la primera VPC disponible en la region.
if [ -z "${VPC_ID}" ] || [ "${VPC_ID}" = "None" ]; then
  VPC_ID="$(aws ec2 describe-vpcs --query 'Vpcs[0].VpcId' \
    --output text --region "${AWS_REGION}")"
  echo ">> No hay VPC default, usando la primera VPC disponible: ${VPC_ID}"
fi

if [ -z "${VPC_ID}" ] || [ "${VPC_ID}" = "None" ]; then
  echo "ERROR: no se encontro ninguna VPC en ${AWS_REGION}. Crea una VPC (con subnet publica e internet gateway) antes de continuar." >&2
  exit 1
fi

SUBNET_IDS="$(aws ec2 describe-subnets --filters Name=vpc-id,Values="${VPC_ID}" \
  --query 'Subnets[].SubnetId' --output text --region "${AWS_REGION}" | tr '\t' ',')"

SG_ID="$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=demo-ecs-sg Name=vpc-id,Values="${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text --region "${AWS_REGION}" 2>/dev/null || true)"

if [ -z "${SG_ID}" ] || [ "${SG_ID}" = "None" ]; then
  SG_ID="$(aws ec2 create-security-group \
    --group-name demo-ecs-sg \
    --description "Permite HTTP entrante para la demo ECS" \
    --vpc-id "${VPC_ID}" --region "${AWS_REGION}" \
    --query 'GroupId' --output text)"

  aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" --protocol tcp --port 80 --cidr 0.0.0.0/0 \
    --region "${AWS_REGION}"
fi

echo ">> VPC: ${VPC_ID} | Subnets: ${SUBNET_IDS} | Security Group: ${SG_ID}"

# ---------------------------------------------------------------------------
# 6. Cluster ECS (Fargate)
# ---------------------------------------------------------------------------
aws ecs describe-clusters --clusters "${ECS_CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query "clusters[?status=='ACTIVE']" --output text | grep -q ACTIVE || \
aws ecs create-cluster --cluster-name "${ECS_CLUSTER_NAME}" --region "${AWS_REGION}"

# ---------------------------------------------------------------------------
# 7. Registrar una primera Task Definition (imagen placeholder de nginx)
#    El pipeline la vuelve a registrar en cada deploy con la imagen nueva.
# ---------------------------------------------------------------------------
sed \
  -e "s|<AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
  -e "s|PLACEHOLDER_IMAGE|public.ecr.aws/nginx/nginx:latest|g" \
  -e "s|us-east-1|${AWS_REGION}|g" \
  "$(dirname "$0")/../ecs-task-definition.json" > "${TMP_DIR}/ecs-task-definition-initial.json"

aws ecs register-task-definition \
  --cli-input-json "file://${TMP_DIR}/ecs-task-definition-initial.json" \
  --region "${AWS_REGION}"

# ---------------------------------------------------------------------------
# 8. Servicio ECS (Fargate, 1 tarea, IP publica para poder probarlo)
# ---------------------------------------------------------------------------
aws ecs describe-services --cluster "${ECS_CLUSTER_NAME}" --services "${ECS_SERVICE_NAME}" \
  --region "${AWS_REGION}" --query "services[?status=='ACTIVE']" --output text | grep -q ACTIVE || \
aws ecs create-service \
  --cluster "${ECS_CLUSTER_NAME}" \
  --service-name "${ECS_SERVICE_NAME}" \
  --task-definition "${ECS_TASK_FAMILY}" \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${SG_ID}],assignPublicIp=ENABLED}" \
  --region "${AWS_REGION}"

echo ">> Listo. Recuerda:"
echo "   1) Reemplazar <AWS_ACCOUNT_ID> en deploy.yml y ecs-task-definition.json"
echo "   2) Reemplazar <tu-usuario-o-org-de-github>/<nombre-del-repositorio> arriba"
echo "   3) Hacer push a la rama main para disparar el pipeline"
