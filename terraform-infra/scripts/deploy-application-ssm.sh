#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Application Deployment via AWS SSM
# ============================================================

: "${AWS_REGION:?AWS_REGION is required}"
: "${FRONTEND_IMAGE_TAG:?FRONTEND_IMAGE_TAG is required}"
: "${BACKEND_IMAGE_TAG:?BACKEND_IMAGE_TAG is required}"
: "${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}"
: "${DOCKERHUB_TOKEN:?DOCKERHUB_TOKEN is required}"

FRONTEND_CONTAINER="goal-tracker-frontend"
BACKEND_CONTAINER="goal-tracker-backend"

FRONTEND_PORT="3000"
BACKEND_PORT="8080"

echo "=============================================="
echo "Application Deployment"
echo "=============================================="
echo "AWS Region       : ${AWS_REGION}"
echo "Frontend image   : ${FRONTEND_IMAGE_TAG}"
echo "Backend image    : ${BACKEND_IMAGE_TAG}"
echo "=============================================="

# ------------------------------------------------------------
# Get ASG names from Terraform outputs
# ------------------------------------------------------------

TF_WORKING_DIR="${TF_WORKING_DIR:-terraform-infra/environments/dev}"

cd "${TF_WORKING_DIR}"

echo "Getting Auto Scaling Group names from Terraform..."

FRONTEND_ASG="$(terraform output -raw frontend_asg_name)"
BACKEND_ASG="$(terraform output -raw backend_asg_name)"

if [[ -z "${FRONTEND_ASG}" || "${FRONTEND_ASG}" == "null" ]]; then
  echo "ERROR: frontend_asg_name Terraform output is empty."
  exit 1
fi

if [[ -z "${BACKEND_ASG}" || "${BACKEND_ASG}" == "null" ]]; then
  echo "ERROR: backend_asg_name Terraform output is empty."
  exit 1
fi

echo "Frontend ASG: ${FRONTEND_ASG}"
echo "Backend ASG : ${BACKEND_ASG}"

# ------------------------------------------------------------
# Get InService instances for an ASG
# ------------------------------------------------------------

get_instance_ids() {
  local asg_name="$1"

  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "${asg_name}" \
    --region "${AWS_REGION}" \
    --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" \
    --output text
}

# ------------------------------------------------------------
# Deploy a service using SSM
# ------------------------------------------------------------

deploy_service() {
  local asg_name="$1"
  local service_name="$2"
  local image_tag="$3"
  local port="$4"

  echo ""
  echo "=============================================="
  echo "Deploying ${service_name}"
  echo "=============================================="
  echo "ASG   : ${asg_name}"
  echo "Image : ${image_tag}"
  echo "Port  : ${port}"

  local instance_ids

  instance_ids="$(get_instance_ids "${asg_name}")"

  if [[ -z "${instance_ids}" || "${instance_ids}" == "None" ]]; then
    echo "ERROR: No InService instances found for ${asg_name}"
    exit 1
  fi

  echo "Instances:"
  echo "${instance_ids}"

  # ----------------------------------------------------------
  # Build SSM command
  # ----------------------------------------------------------

  local commands_file
  commands_file="$(mktemp)"

  cat > "${commands_file}" <<EOF
[
  "set -euo pipefail",

  "echo 'Logging in to Docker Hub...'",
  "echo '${DOCKERHUB_TOKEN}' | docker login -u '${DOCKERHUB_USERNAME}' --password-stdin",

  "echo 'Pulling image: ${image_tag}'",
  "docker pull '${image_tag}'",

  "echo 'Stopping existing container if present...'",
  "docker stop '${service_name}' || true",

  "echo 'Removing existing container if present...'",
  "docker rm '${service_name}' || true",

  "echo 'Starting new container...'",
  "docker run -d --name '${service_name}' --restart unless-stopped -p ${port}:${port} '${image_tag}'",

  "echo 'Removing unused Docker images...'",
  "docker image prune -af",

  "echo 'Checking container status...'",
  "docker ps --filter 'name=^/${service_name}$' --format '{{.Names}} {{.Status}}'",

  "echo '${service_name} deployment completed.'"
]
EOF

  # ----------------------------------------------------------
  # Send command through SSM
  # ----------------------------------------------------------

  local command_id

  command_id="$(
    aws ssm send-command \
      --document-name "AWS-RunShellScript" \
      --comment "Deploy ${service_name}" \
      --instance-ids ${instance_ids} \
      --parameters "commands=file://${commands_file}" \
      --region "${AWS_REGION}" \
      --query "Command.CommandId" \
      --output text
  )"

  rm -f "${commands_file}"

  echo "SSM Command ID: ${command_id}"

  # ----------------------------------------------------------
  # Wait for every instance
  # ----------------------------------------------------------

  local failed=0

  for instance_id in ${instance_ids}; do
    echo ""
    echo "Waiting for ${service_name} deployment on ${instance_id}..."

    if aws ssm wait command-executed \
      --command-id "${command_id}" \
      --instance-id "${instance_id}" \
      --region "${AWS_REGION}"; then

      echo "SSM command completed on ${instance_id}."

      aws ssm get-command-invocation \
        --command-id "${command_id}" \
        --instance-id "${instance_id}" \
        --region "${AWS_REGION}" \
        --query 'StandardOutputContent' \
        --output text || true

    else
      echo "ERROR: SSM command failed on ${instance_id}."

      aws ssm get-command-invocation \
        --command-id "${command_id}" \
        --instance-id "${instance_id}" \
        --region "${AWS_REGION}" \
        --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
        --output json || true

      failed=1
    fi
  done

  if [[ "${failed}" -ne 0 ]]; then
    echo "ERROR: ${service_name} deployment failed."
    exit 1
  fi

  echo "${service_name} deployment successful."
}

# ------------------------------------------------------------
# Deploy frontend
# ------------------------------------------------------------

deploy_service \
  "${FRONTEND_ASG}" \
  "${FRONTEND_CONTAINER}" \
  "${FRONTEND_IMAGE_TAG}" \
  "${FRONTEND_PORT}"

# ------------------------------------------------------------
# Deploy backend
# ------------------------------------------------------------

deploy_service \
  "${BACKEND_ASG}" \
  "${BACKEND_CONTAINER}" \
  "${BACKEND_IMAGE_TAG}" \
  "${BACKEND_PORT}"

echo ""
echo "=============================================="
echo "Application deployment completed successfully"
echo "=============================================="
