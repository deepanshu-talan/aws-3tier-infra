```bash
#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Deploy application containers to existing EC2 instances
# through AWS Systems Manager (SSM).
#
# Terraform infrastructure is NOT changed here.
# This script only deploys the new Docker images.
# ============================================================

: "${AWS_REGION:?AWS_REGION is required}"
: "${FRONTEND_IMAGE_TAG:?FRONTEND_IMAGE_TAG is required}"
: "${BACKEND_IMAGE_TAG:?BACKEND_IMAGE_TAG is required}"

TF_WORKING_DIR="${TF_WORKING_DIR:-terraform-infra/environments/dev}"

FRONTEND_CONTAINER="goal-tracker-frontend"
BACKEND_CONTAINER="goal-tracker-backend"

echo "============================================================"
echo "Starting application deployment"
echo "============================================================"
echo "Frontend image: ${FRONTEND_IMAGE_TAG}"
echo "Backend image : ${BACKEND_IMAGE_TAG}"
echo "AWS region    : ${AWS_REGION}"
echo "============================================================"

# ------------------------------------------------------------
# Terraform outputs
# ------------------------------------------------------------

cd "${TF_WORKING_DIR}"

echo "Reading Terraform outputs..."

FRONTEND_ASG="$(terraform output -raw frontend_asg_name)"
BACKEND_ASG="$(terraform output -raw backend_asg_name)"
INTERNAL_ALB="$(terraform output -raw internal_alb_dns_name)"
DB_SECRET_NAME="$(terraform output -raw db_secret_name)"

if [[ -z "${FRONTEND_ASG}" ]]; then
  echo "ERROR: frontend_asg_name output is empty."
  exit 1
fi

if [[ -z "${BACKEND_ASG}" ]]; then
  echo "ERROR: backend_asg_name output is empty."
  exit 1
fi

if [[ -z "${INTERNAL_ALB}" ]]; then
  echo "ERROR: internal_alb_dns_name output is empty."
  exit 1
fi

if [[ -z "${DB_SECRET_NAME}" ]]; then
  echo "ERROR: db_secret_name output is empty."
  exit 1
fi

echo "Frontend ASG : ${FRONTEND_ASG}"
echo "Backend ASG  : ${BACKEND_ASG}"
echo "Internal ALB : ${INTERNAL_ALB}"
echo "DB secret    : ${DB_SECRET_NAME}"

# ------------------------------------------------------------
# Get InService EC2 instances
# ------------------------------------------------------------

get_instances() {
  local asg_name="$1"

  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "${asg_name}" \
    --region "${AWS_REGION}" \
    --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" \
    --output text
}

# ------------------------------------------------------------
# Send command and wait
# ------------------------------------------------------------

wait_for_ssm_command() {
  local command_id="$1"
  local instance_ids="$2"
  local service_name="$3"

  local failed=0

  for instance_id in ${instance_ids}; do

    echo ""
    echo "Waiting for ${service_name} on ${instance_id}..."

    if ! aws ssm wait command-executed \
      --command-id "${command_id}" \
      --instance-id "${instance_id}" \
      --region "${AWS_REGION}"; then

      echo "ERROR: SSM command failed on ${instance_id}"

      aws ssm get-command-invocation \
        --command-id "${command_id}" \
        --instance-id "${instance_id}" \
        --region "${AWS_REGION}" \
        --query '{
          Status:Status,
          StatusDetails:StatusDetails,
          Output:StandardOutputContent,
          Error:StandardErrorContent
        }' \
        --output json || true

      failed=1
      continue
    fi

    echo "SSM command succeeded on ${instance_id}"

    aws ssm get-command-invocation \
      --command-id "${command_id}" \
      --instance-id "${instance_id}" \
      --region "${AWS_REGION}" \
      --query 'StandardOutputContent' \
      --output text || true
  done

  if [[ "${failed}" -ne 0 ]]; then
    echo "ERROR: ${service_name} deployment failed."
    exit 1
  fi
}

# ------------------------------------------------------------
# Deploy backend
# ------------------------------------------------------------

deploy_backend() {

  echo ""
  echo "============================================================"
  echo "Deploying BACKEND"
  echo "============================================================"

  local instance_ids

  instance_ids="$(get_instances "${BACKEND_ASG}")"

  if [[ -z "${instance_ids}" || "${instance_ids}" == "None" ]]; then
    echo "ERROR: No InService backend instances found."
    exit 1
  fi

  echo "Backend instances:"
  echo "${instance_ids}"

  local commands_file
  commands_file="$(mktemp)"

  # The backend user-data already uses the EC2 instance role
  # to retrieve the DB secret. We do the same here.
  cat > "${commands_file}" <<EOF
[
  "set -euo pipefail",

  "echo 'Pulling backend image: ${BACKEND_IMAGE_TAG}'",
  "docker pull '${BACKEND_IMAGE_TAG}'",

  "echo 'Retrieving database credentials from Secrets Manager...'",
  "SECRET=\\$(aws secretsmanager get-secret-value --secret-id '${DB_SECRET_NAME}' --region '${AWS_REGION}' --query SecretString --output text)",

  "DB_USERNAME=\\$(echo \\\"\\\$SECRET\\\" | jq -r '.username')",
  "DB_PASSWORD=\\$(echo \\\"\\\$SECRET\\\" | jq -r '.password')",
  "DB_HOST=\\$(echo \\\"\\\$SECRET\\\" | jq -r '.host')",
  "DB_PORT=\\$(echo \\\"\\\$SECRET\\\" | jq -r '.port')",
  "DB_NAME=\\$(echo \\\"\\\$SECRET\\\" | jq -r '.dbname')",

  "test -n \\\"\\\$DB_USERNAME\\\"",
  "test -n \\\"\\\$DB_PASSWORD\\\"",
  "test -n \\\"\\\$DB_HOST\\\"",
  "test -n \\\"\\\$DB_PORT\\\"",
  "test -n \\\"\\\$DB_NAME\\\"",

  "echo 'Stopping old backend container...'",
  "docker stop '${BACKEND_CONTAINER}' || true",

  "echo 'Removing old backend container...'",
  "docker rm '${BACKEND_CONTAINER}' || true",

  "echo 'Starting new backend container...'",
  "docker run -d --name '${BACKEND_CONTAINER}' --restart unless-stopped -p 8080:8080 -e DB_USERNAME=\\\"\$DB_USERNAME\\\" -e DB_PASSWORD=\\\"\$DB_PASSWORD\\\" -e DB_HOST=\\\"\$DB_HOST\\\" -e DB_PORT=\\\"\$DB_PORT\\\" -e DB_NAME=\\\"\$DB_NAME\\\" -e SSL=require -e PORT=8080 '${BACKEND_IMAGE_TAG}'",

  "sleep 10",

  "docker ps --filter 'name=^/${BACKEND_CONTAINER}$' --format '{{.Names}} {{.Status}}'",

  "curl --fail --silent --show-error --max-time 15 http://localhost:8080/health",

  "echo 'Backend deployment successful.'"
]
EOF

  local command_id

  command_id="$(
    aws ssm send-command \
      --document-name "AWS-RunShellScript" \
      --comment "Deploy backend ${BACKEND_IMAGE_TAG}" \
      --instance-ids ${instance_ids} \
      --parameters "commands=file://${commands_file}" \
      --region "${AWS_REGION}" \
      --query "Command.CommandId" \
      --output text
  )"

  rm -f "${commands_file}"

  echo "Backend SSM command: ${command_id}"

  wait_for_ssm_command \
    "${command_id}" \
    "${instance_ids}" \
    "backend"

  echo "Backend deployment completed."
}

# ------------------------------------------------------------
# Deploy frontend
# ------------------------------------------------------------

deploy_frontend() {

  echo ""
  echo "============================================================"
  echo "Deploying FRONTEND"
  echo "============================================================"

  local instance_ids

  instance_ids="$(get_instances "${FRONTEND_ASG}")"

  if [[ -z "${instance_ids}" || "${instance_ids}" == "None" ]]; then
    echo "ERROR: No InService frontend instances found."
    exit 1
  fi

  echo "Frontend instances:"
  echo "${instance_ids}"

  local commands_file
  commands_file="$(mktemp)"

  # The frontend user-data uses:
  # BACKEND_URL=<internal ALB>
  # PORT=3000
  # NODE_ENV=production
  #
  # We preserve exactly that configuration here.
  local backend_url="http://${INTERNAL_ALB}:8080"

  cat > "${commands_file}" <<EOF
[
  "set -euo pipefail",

  "echo 'Pulling frontend image: ${FRONTEND_IMAGE_TAG}'",
  "docker pull '${FRONTEND_IMAGE_TAG}'",

  "echo 'Stopping old frontend container...'",
  "docker stop '${FRONTEND_CONTAINER}' || true",

  "echo 'Removing old frontend container...'",
  "docker rm '${FRONTEND_CONTAINER}' || true",

  "echo 'Starting new frontend container...'",
  "docker run -d --name '${FRONTEND_CONTAINER}' --restart unless-stopped -p 3000:3000 -e PORT=3000 -e BACKEND_URL='${backend_url}' -e NODE_ENV=production '${FRONTEND_IMAGE_TAG}'",

  "sleep 5",

  "docker ps --filter 'name=^/${FRONTEND_CONTAINER}$' --format '{{.Names}} {{.Status}}'",

  "curl --fail --silent --show-error --max-time 15 http://localhost:3000/",

  "echo 'Frontend deployment successful.'"
]
EOF

  local command_id

  command_id="$(
    aws ssm send-command \
      --document-name "AWS-RunShellScript" \
      --comment "Deploy frontend ${FRONTEND_IMAGE_TAG}" \
      --instance-ids ${instance_ids} \
      --parameters "commands=file://${commands_file}" \
      --region "${AWS_REGION}" \
      --query "Command.CommandId" \
      --output text
  )"

  rm -f "${commands_file}"

  echo "Frontend SSM command: ${command_id}"

  wait_for_ssm_command \
    "${command_id}" \
    "${instance_ids}" \
    "frontend"

  echo "Frontend deployment completed."
}

# ------------------------------------------------------------
# Deployment order
# ------------------------------------------------------------
#
# Backend first:
#   Frontend depends on the backend endpoint.
#
# Then frontend:
#   Frontend gets the internal ALB URL.
#
# ------------------------------------------------------------

deploy_backend
deploy_frontend

echo ""
echo "============================================================"
echo "APPLICATION DEPLOYMENT SUCCESSFUL"
echo "============================================================"
echo "Frontend image: ${FRONTEND_IMAGE_TAG}"
echo "Backend image : ${BACKEND_IMAGE_TAG}"
echo "============================================================"
```
