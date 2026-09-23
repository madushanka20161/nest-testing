#!/bin/bash

set -e

# ============================================================
# Configuration
# ============================================================

AWS_REGION="ap-south-1"

APP_NAME="nest-backend"
ENV_NAME="nest-backend-env"

PIPELINE_NAME="${APP_NAME}-pipeline"
CODEBUILD_PROJECT="${APP_NAME}-build"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ARTIFACT_BUCKET="nest-backend-pipeline-artifacts-${ACCOUNT_ID}-${AWS_REGION}"

echo "============================================================"
echo " AWS NestJS Infrastructure Cleanup"
echo "============================================================"
echo "Account: ${ACCOUNT_ID}"
echo "Region:  ${AWS_REGION}"
echo ""


# ============================================================
# 1. Delete CodePipeline
# ============================================================

echo "==> Checking CodePipeline..."

if aws codepipeline get-pipeline \
    --name "${PIPELINE_NAME}" \
    --region "${AWS_REGION}" >/dev/null 2>&1; then

    echo "==> Deleting CodePipeline: ${PIPELINE_NAME}"

    aws codepipeline delete-pipeline \
        --name "${PIPELINE_NAME}" \
        --region "${AWS_REGION}"

    echo "==> CodePipeline deleted"

else
    echo "==> CodePipeline does not exist - skipping"
fi

# ============================================================
# 2. Delete CodeBuild project
# ============================================================

echo ""
echo "==> Checking CodeBuild project..."

PROJECT_EXISTS=$(aws codebuild batch-get-projects \
    --names "${CODEBUILD_PROJECT}" \
    --region "${AWS_REGION}" \
    --query "length(projects)" \
    --output text)

if [ "${PROJECT_EXISTS}" -gt 0 ]; then

    echo "==> Deleting CodeBuild project: ${CODEBUILD_PROJECT}"

    aws codebuild delete-project \
        --name "${CODEBUILD_PROJECT}" \
        --region "${AWS_REGION}"

    echo "==> CodeBuild project deleted"

else
    echo "==> CodeBuild project does not exist - skipping"
fi

# ============================================================
# 3. Terminate Elastic Beanstalk environment
# ============================================================

echo ""
echo "==> Checking Elastic Beanstalk environment..."

ENV_STATUS=$(aws elasticbeanstalk describe-environments \
    --environment-names "${ENV_NAME}" \
    --region "${AWS_REGION}" \
    --include-deleted \
    --query "Environments[0].Status" \
    --output text 2>/dev/null || echo "None")

if [ "${ENV_STATUS}" != "None" ] && [ "${ENV_STATUS}" != "Terminated" ]; then

    echo "==> Current environment status: ${ENV_STATUS}"

    # Only send terminate request if it is not already terminating
    if [ "${ENV_STATUS}" != "Terminating" ]; then

        echo "==> Sending termination request for: ${ENV_NAME}"

        aws elasticbeanstalk terminate-environment \
            --environment-name "${ENV_NAME}" \
            --region "${AWS_REGION}"

    else
        echo "==> Environment is already terminating"
    fi

    echo ""
    echo "==> Waiting for Elastic Beanstalk environment to terminate..."

    WAIT_COUNT=0

    while true; do

        ENV_STATUS=$(aws elasticbeanstalk describe-environments \
            --environment-names "${ENV_NAME}" \
            --region "${AWS_REGION}" \
            --include-deleted \
            --query "Environments[0].Status" \
            --output text 2>/dev/null || echo "None")

        if [ "${ENV_STATUS}" = "Terminated" ] || [ "${ENV_STATUS}" = "None" ]; then
            echo ""
            echo "==> Environment successfully terminated"
            break
        fi

        WAIT_COUNT=$((WAIT_COUNT + 1))
        ELAPSED=$((WAIT_COUNT * 10))

        echo "    [${ELAPSED}s] Status: ${ENV_STATUS} - checking again in 10 seconds..."

        sleep 10

    done

else
    echo "==> Environment already terminated or does not exist - skipping"
fi

# ============================================================
# 4. Delete Elastic Beanstalk application
# ============================================================

echo ""
echo "==> Checking Elastic Beanstalk application..."

APP_EXISTS=$(aws elasticbeanstalk describe-applications \
    --application-names "${APP_NAME}" \
    --region "${AWS_REGION}" \
    --query "length(Applications)" \
    --output text)

if [ "${APP_EXISTS}" -gt 0 ]; then

    echo "==> Deleting Elastic Beanstalk application: ${APP_NAME}"

    aws elasticbeanstalk delete-application \
        --application-name "${APP_NAME}" \
        --terminate-env-by-force \
        --region "${AWS_REGION}"

    echo "==> Elastic Beanstalk application deleted"

else
    echo "==> Elastic Beanstalk application does not exist - skipping"
fi


# ============================================================
# 5. Delete pipeline artifact S3 bucket
# ============================================================

echo ""
echo "==> Checking artifact bucket..."

if aws s3api head-bucket \
    --bucket "${ARTIFACT_BUCKET}" 2>/dev/null; then

    echo "==> Emptying artifact bucket: ${ARTIFACT_BUCKET}"

    aws s3 rm \
        "s3://${ARTIFACT_BUCKET}" \
        --recursive \
        --region "${AWS_REGION}"

    echo "==> Deleting artifact bucket"

    aws s3api delete-bucket \
        --bucket "${ARTIFACT_BUCKET}" \
        --region "${AWS_REGION}"

    echo "==> Artifact bucket deleted"

else
    echo "==> Artifact bucket does not exist - skipping"
fi


# ============================================================
# Finished
# ============================================================

echo ""
echo "============================================================"
echo " Main application infrastructure cleanup completed"
echo "============================================================"