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

echo "============================================================"
echo "Starting application deployment"
echo "============================================================"
echo "Frontend image: ${FRONTEND_IMAGE_TAG}"
echo "Backend image : ${BACKEND_IMAGE_TAG}"
echo "AWS region    : ${AWS_REGION}"
echo "============================================================"

# ------------------------------------------------------------
# Read Terraform outputs
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
# Wait for SSM command on all instances
# ------------------------------------------------------------

wait_for_command() {
    local command_id="$1"
    local instance_ids="$2"
    local service_name="$3"

    local failed=0

    for instance_id in ${instance_ids}; do

        echo ""
        echo "Waiting for ${service_name} deployment on ${instance_id}..."

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
    local parameters_file
    local command_id

    commands_file="$(mktemp)"
    parameters_file="$(mktemp)"

    # --------------------------------------------------------
    # Create commands that will execute ON EC2.
    #
    # Important:
    # This heredoc is quoted so DB_USERNAME, DB_PASSWORD etc.
    # are NOT expanded on the GitHub runner.
    # --------------------------------------------------------

    cat > "${commands_file}" <<'SSM_COMMANDS'
#!/bin/bash
set -euo pipefail

echo "============================================================"
echo "Backend deployment started"
echo "============================================================"

echo "Pulling backend image..."

docker pull "__BACKEND_IMAGE_TAG__"

echo "Retrieving database credentials from Secrets Manager..."

SECRET="$(aws secretsmanager get-secret-value \
    --secret-id "__DB_SECRET_NAME__" \
    --region "__AWS_REGION__" \
    --query SecretString \
    --output text)"

if [[ -z "${SECRET}" ]]; then
    echo "ERROR: Database secret is empty."
    exit 1
fi

DB_USERNAME="$(echo "${SECRET}" | jq -r '.username')"
DB_PASSWORD="$(echo "${SECRET}" | jq -r '.password')"
DB_HOST="$(echo "${SECRET}" | jq -r '.host')"
DB_PORT="$(echo "${SECRET}" | jq -r '.port')"
DB_NAME="$(echo "${SECRET}" | jq -r '.dbname')"

if [[ -z "${DB_USERNAME}" || "${DB_USERNAME}" == "null" ]]; then
    echo "ERROR: DB_USERNAME is missing."
    exit 1
fi

if [[ -z "${DB_PASSWORD}" || "${DB_PASSWORD}" == "null" ]]; then
    echo "ERROR: DB_PASSWORD is missing."
    exit 1
fi

if [[ -z "${DB_HOST}" || "${DB_HOST}" == "null" ]]; then
    echo "ERROR: DB_HOST is missing."
    exit 1
fi

if [[ -z "${DB_PORT}" || "${DB_PORT}" == "null" ]]; then
    echo "ERROR: DB_PORT is missing."
    exit 1
fi

if [[ -z "${DB_NAME}" || "${DB_NAME}" == "null" ]]; then
    echo "ERROR: DB_NAME is missing."
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
    -e DB_USERNAME="${DB_USERNAME}" \
    -e DB_PASSWORD="${DB_PASSWORD}" \
    -e DB_HOST="${DB_HOST}" \
    -e DB_PORT="${DB_PORT}" \
    -e DB_NAME="${DB_NAME}" \
    -e SSL=require \
    -e PORT=8080 \
    "__BACKEND_IMAGE_TAG__"

echo "Waiting for backend to start..."

sleep 15

if ! docker ps --format '{{.Names}}' | grep -qx "__BACKEND_CONTAINER__"; then

    echo "ERROR: Backend container is not running."

    docker ps -a || true

    docker logs "__BACKEND_CONTAINER__" || true

    exit 1
fi

echo "Checking backend endpoint..."

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

    # --------------------------------------------------------
    # Replace only deployment-specific placeholders.
    # --------------------------------------------------------

    sed -i \
        -e "s|__BACKEND_IMAGE_TAG__|${BACKEND_IMAGE_TAG}|g" \
        -e "s|__DB_SECRET_NAME__|${DB_SECRET_NAME}|g" \
        -e "s|__AWS_REGION__|${AWS_REGION}|g" \
        -e "s|__BACKEND_CONTAINER__|${BACKEND_CONTAINER}|g" \
        "${commands_file}"

    # --------------------------------------------------------
    # Convert commands file into SSM parameters JSON.
    #
    # This is the important fix:
    #
    # WRONG:
    #   commands=file:///tmp/...
    #
    # CORRECT:
    #   {"commands":["command1","command2",...]}
    # --------------------------------------------------------

    jq -n \
        --rawfile commands "${commands_file}" \
        '{commands: ($commands | split("\n") | map(select(length > 0)))}' \
        > "${parameters_file}"

    echo ""
    echo "Sending backend deployment command through SSM..."

    command_id="$(
        aws ssm send-command \
            --document-name "AWS-RunShellScript" \
            --comment "Deploy backend ${BACKEND_IMAGE_TAG}" \
            --instance-ids ${instance_ids} \
            --parameters "file://${parameters_file}" \
            --region "${AWS_REGION}" \
            --query "Command.CommandId" \
            --output text
    )"

    rm -f "${commands_file}" "${parameters_file}"

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
    local parameters_file
    local command_id

    commands_file="$(mktemp)"
    parameters_file="$(mktemp)"

    # Frontend talks to the internal ALB.
    BACKEND_URL="http://${INTERNAL_ALB}:8080"

    # --------------------------------------------------------
    # Commands that execute ON frontend EC2.
    # --------------------------------------------------------

    cat > "${commands_file}" <<'SSM_COMMANDS'
#!/bin/bash
set -euo pipefail

echo "============================================================"
echo "Frontend deployment started"
echo "============================================================"

echo "Pulling frontend image..."

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

echo "Waiting for frontend to start..."

sleep 10

if ! docker ps --format '{{.Names}}' | grep -qx "__FRONTEND_CONTAINER__"; then

    echo "ERROR: Frontend container is not running."

    docker ps -a || true

    docker logs "__FRONTEND_CONTAINER__" || true

    exit 1
fi

echo "Checking frontend endpoint..."

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

    # --------------------------------------------------------
    # Replace deployment-specific placeholders.
    # --------------------------------------------------------

    sed -i \
        -e "s|__FRONTEND_IMAGE_TAG__|${FRONTEND_IMAGE_TAG}|g" \
        -e "s|__FRONTEND_CONTAINER__|${FRONTEND_CONTAINER}|g" \
        -e "s|__BACKEND_URL__|${BACKEND_URL}|g" \
        "${commands_file}"

    # --------------------------------------------------------
    # Convert commands into proper SSM JSON parameters.
    # --------------------------------------------------------

    jq -n \
        --rawfile commands "${commands_file}" \
        '{commands: ($commands | split("\n") | map(select(length > 0)))}' \
        > "${parameters_file}"

    echo ""
    echo "Sending frontend deployment command through SSM..."

    command_id="$(
        aws ssm send-command \
            --document-name "AWS-RunShellScript" \
            --comment "Deploy frontend ${FRONTEND_IMAGE_TAG}" \
            --instance-ids ${instance_ids} \
            --parameters "file://${parameters_file}" \
            --region "${AWS_REGION}" \
            --query "Command.CommandId" \
            --output text
    )"

    rm -f "${commands_file}" "${parameters_file}"

    echo "Frontend SSM command ID: ${command_id}"

    wait_for_command \
        "${command_id}" \
        "${instance_ids}" \
        "frontend"

    echo "Frontend deployment completed."
}

# ============================================================
# Deployment order
#
# Backend first:
#   frontend depends on backend.
#
# Frontend second:
#   frontend uses backend internal ALB URL.
# ============================================================

deploy_backend
deploy_frontend

echo ""
echo "============================================================"
echo "APPLICATION DEPLOYMENT SUCCESSFUL"
echo "============================================================"
echo "Frontend image: ${FRONTEND_IMAGE_TAG}"
echo "Backend image : ${BACKEND_IMAGE_TAG}"
echo "============================================================"