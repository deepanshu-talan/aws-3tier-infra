#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Goal Tracker - Application Deployment via AWS SSM
# ============================================================

: "${AWS_REGION:?AWS_REGION is required}"
: "${FRONTEND_IMAGE_TAG:?FRONTEND_IMAGE_TAG is required}"
: "${BACKEND_IMAGE_TAG:?BACKEND_IMAGE_TAG is required}"

TF_WORKING_DIR="${TF_WORKING_DIR:-terraform-infra/environments/dev}"

FRONTEND_CONTAINER="goal-tracker-frontend"
BACKEND_CONTAINER="goal-tracker-backend"

FRONTEND_PORT="3000"
BACKEND_PORT="8080"

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

echo "Frontend ASG : ${FRONTEND_ASG}"
echo "Backend ASG  : ${BACKEND_ASG}"
echo "Internal ALB : ${INTERNAL_ALB}"
echo "DB secret    : ${DB_SECRET_NAME}"

# ------------------------------------------------------------
# Get InService instances
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
# Wait for SSM command
# ------------------------------------------------------------

wait_for_command() {
    local command_id="$1"
    local instance_ids="$2"
    local service_name="$3"

    local failed=0

    for instance_id in ${instance_ids}; do
        echo ""
        echo "Waiting for ${service_name} on ${instance_id}..."

        if aws ssm wait command-executed \
            --command-id "${command_id}" \
            --instance-id "${instance_id}" \
            --region "${AWS_REGION}"; then

            echo "SSM command succeeded on ${instance_id}"

            aws ssm get-command-invocation \
                --command-id "${command_id}" \
                --instance-id "${instance_id}" \
                --region "${AWS_REGION}" \
                --query "StandardOutputContent" \
                --output text || true

        else

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
        fi
    done

    if [[ "${failed}" -ne 0 ]]; then
        echo "ERROR: ${service_name} deployment failed."
        exit 1
    fi
}

# ------------------------------------------------------------
# Backend deployment
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

    # IMPORTANT:
    # This heredoc is quoted so DB_USERNAME etc. are NOT expanded
    # on the GitHub runner. They will be expanded on the EC2 host.
    cat > "${commands_file}" <<'SSM_COMMANDS'
set -euo pipefail

echo "Pulling backend Docker image..."

docker pull "__BACKEND_IMAGE_TAG__"

echo "Retrieving database credentials..."

SECRET="$(aws secretsmanager get-secret-value \
  --secret-id "__DB_SECRET_NAME__" \
  --region "__AWS_REGION__" \
  --query SecretString \
  --output text)"

if [ -z "$SECRET" ]; then
  echo "ERROR: Could not retrieve database secret."
  exit 1
fi

DB_USERNAME="$(echo "$SECRET" | jq -r '.username')"
DB_PASSWORD="$(echo "$SECRET" | jq -r '.password')"
DB_HOST="$(echo "$SECRET" | jq -r '.host')"
DB_PORT="$(echo "$SECRET" | jq -r '.port')"
DB_NAME="$(echo "$SECRET" | jq -r '.dbname')"

if [ -z "$DB_USERNAME" ] ||
   [ -z "$DB_PASSWORD" ] ||
   [ -z "$DB_HOST" ] ||
   [ -z "$DB_PORT" ] ||
   [ -z "$DB_NAME" ]; then

    echo "ERROR: Required database configuration is missing."
    exit 1
fi

echo "Database configuration retrieved."

echo "Stopping old backend container..."

docker stop "__BACKEND_CONTAINER__" || true

echo "Removing old backend container..."

docker rm "__BACKEND_CONTAINER__" || true

echo "Starting new backend container..."

docker run -d \
  --name "__BACKEND_CONTAINER__" \
  --restart unless-stopped \
  -p 8080:8080 \
  -e DB_USERNAME="$DB_USERNAME" \
  -e DB_PASSWORD="$DB_PASSWORD" \
  -e DB_HOST="$DB_HOST" \
  -e DB_PORT="$DB_PORT" \
  -e DB_NAME="$DB_NAME" \
  -e SSL=require \
  -e PORT=8080 \
  "__BACKEND_IMAGE_TAG__"

echo "Waiting for backend..."

sleep 15

if ! docker ps --format '{{.Names}}' | grep -qx "__BACKEND_CONTAINER__"; then
    echo "ERROR: Backend container is not running."
    docker logs "__BACKEND_CONTAINER__" || true
    exit 1
fi

echo "Checking backend..."

for attempt in $(seq 1 30); do

    if curl \
        --fail \
        --silent \
        --show-error \
        --max-time 10 \
        http://localhost:8080/goals \
        > /dev/null; then

        echo "Backend is healthy."
        exit 0
    fi

    echo "Backend not ready. Attempt ${attempt}/30"
    sleep 2

done

echo "ERROR: Backend health check failed."

docker logs "__BACKEND_CONTAINER__" || true

exit 1
SSM_COMMANDS

    # Replace placeholders AFTER creating the SSM script.
    sed -i \
        -e "s|__BACKEND_IMAGE_TAG__|${BACKEND_IMAGE_TAG}|g" \
        -e "s|__DB_SECRET_NAME__|${DB_SECRET_NAME}|g" \
        -e "s|__AWS_REGION__|${AWS_REGION}|g" \
        -e "s|__BACKEND_CONTAINER__|${BACKEND_CONTAINER}|g" \
        "${commands_file}"

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

    echo "Backend SSM command ID: ${command_id}"

    wait_for_command \
        "${command_id}" \
        "${instance_ids}" \
        "backend"

    echo "Backend deployment completed."
}

# ------------------------------------------------------------
# Frontend deployment
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

    # Frontend talks to the internal ALB.
    BACKEND_URL="http://${INTERNAL_ALB}:8080"

    cat > "${commands_file}" <<'SSM_COMMANDS'
set -euo pipefail

echo "Pulling frontend Docker image..."

docker pull "__FRONTEND_IMAGE_TAG__"

echo "Stopping old frontend container..."

docker stop "__FRONTEND_CONTAINER__" || true

echo "Removing old frontend container..."

docker rm "__FRONTEND_CONTAINER__" || true

echo "Starting new frontend container..."

docker run -d \
  --name "__FRONTEND_CONTAINER__" \
  --restart unless-stopped \
  -p 3000:3000 \
  -e PORT=3000 \
  -e BACKEND_URL="__BACKEND_URL__" \
  -e NODE_ENV=production \
  "__FRONTEND_IMAGE_TAG__"

echo "Waiting for frontend..."

sleep 10

if ! docker ps --format '{{.Names}}' | grep -qx "__FRONTEND_CONTAINER__"; then
    echo "ERROR: Frontend container is not running."
    docker logs "__FRONTEND_CONTAINER__" || true
    exit 1
fi

echo "Checking frontend..."

for attempt in $(seq 1 30); do

    if curl \
        --fail \
        --silent \
        --show-error \
        --max-time 10 \
        http://localhost:3000/ \
        > /dev/null; then

        echo "Frontend is healthy."
        exit 0
    fi

    echo "Frontend not ready. Attempt ${attempt}/30"
    sleep 2

done

echo "ERROR: Frontend health check failed."

docker logs "__FRONTEND_CONTAINER__" || true

exit 1
SSM_COMMANDS

    sed -i \
        -e "s|__FRONTEND_IMAGE_TAG__|${FRONTEND_IMAGE_TAG}|g" \
        -e "s|__FRONTEND_CONTAINER__|${FRONTEND_CONTAINER}|g" \
        -e "s|__BACKEND_URL__|${BACKEND_URL}|g" \
        "${commands_file}"

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

    echo "Frontend SSM command ID: ${command_id}"

    wait_for_command \
        "${command_id}" \
        "${instance_ids}" \
        "frontend"

    echo "Frontend deployment completed."
}

# ------------------------------------------------------------
# Deploy backend first, then frontend
# ------------------------------------------------------------

deploy_backend
deploy_frontend

echo ""
echo "============================================================"
echo "APPLICATION DEPLOYMENT SUCCESSFUL"
echo "============================================================"
echo "Frontend: ${FRONTEND_IMAGE_TAG}"
echo "Backend : ${BACKEND_IMAGE_TAG}"
echo "============================================================"
