#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Sets up: GitHub -> CodePipeline -> CodeBuild -> Elastic Beanstalk
# No Docker involved anywhere. Push to your branch -> auto-deploys.
#
# One-time manual prerequisite (cannot be scripted):
#   AWS Console -> Developer Tools -> Settings -> Connections
#   -> Create connection -> GitHub -> authorize your account/repo.
#   Then run: aws codestar-connections list-connections --region <region>
#   to get the ConnectionArn used below.
# ============================================================

# ---- Config (edit these) ----
AWS_REGION="us-east-1"
APP_NAME="nest-backend"                 # used for EB app, CodeBuild project, pipeline name
ENV_NAME="nest-backend-env"              # EB environment name
GITHUB_OWNER=",adushanka20161"
GITHUB_REPO="nest-testing"
BRANCH="main"
CONNECTION_ARN="arn:aws:codeconnections:ap-south-1:310869708079:connection/153a4ff6-82d9-4a72-b368-87b6b2c03af0"
NODE_VERSION_LABEL="Node.js 20"           # must match a string in `list-available-solution-stacks`
# ------------------------------

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ARTIFACT_BUCKET="${APP_NAME}-pipeline-artifacts-${ACCOUNT_ID}"

echo "==> Account: ${ACCOUNT_ID}, Region: ${AWS_REGION}"

# ------------------------------------------------------------
# 1. Artifact bucket for the pipeline
# ------------------------------------------------------------
if ! aws s3api head-bucket --bucket "${ARTIFACT_BUCKET}" 2>/dev/null; then
  echo "==> Creating pipeline artifact bucket: ${ARTIFACT_BUCKET}"
  aws s3api create-bucket --bucket "${ARTIFACT_BUCKET}" --region "${AWS_REGION}" \
    $( [ "${AWS_REGION}" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=${AWS_REGION}" )
else
  echo "==> Artifact bucket already exists"
fi

# ------------------------------------------------------------
# 2. Elastic Beanstalk application + environment
# ------------------------------------------------------------
if ! aws elasticbeanstalk describe-applications --application-names "${APP_NAME}" \
    --region "${AWS_REGION}" --query "Applications[0]" --output text | grep -q "${APP_NAME}"; then
  echo "==> Creating Elastic Beanstalk application: ${APP_NAME}"
  aws elasticbeanstalk create-application --application-name "${APP_NAME}" --region "${AWS_REGION}"
else
  echo "==> EB application already exists"
fi

echo "==> Looking up current solution stack for ${NODE_VERSION_LABEL}"
SOLUTION_STACK=$(aws elasticbeanstalk list-available-solution-stacks --region "${AWS_REGION}" \
  --query "SolutionStacks[?contains(@, '${NODE_VERSION_LABEL}') && contains(@, 'Amazon Linux 2023')] | [0]" \
  --output text)
echo "==> Using solution stack: ${SOLUTION_STACK}"

if ! aws elasticbeanstalk describe-environments --environment-names "${ENV_NAME}" \
    --region "${AWS_REGION}" --query "Environments[?Status!='Terminated'] | [0]" --output text | grep -q "${ENV_NAME}"; then
  echo "==> Creating Elastic Beanstalk environment: ${ENV_NAME} (this takes several minutes)"
  aws elasticbeanstalk create-environment \
    --application-name "${APP_NAME}" \
    --environment-name "${ENV_NAME}" \
    --solution-stack-name "${SOLUTION_STACK}" \
    --region "${AWS_REGION}" \
    --option-settings \
      Namespace=aws:autoscaling:launchconfiguration,OptionName=InstanceType,Value=t3.micro \
      Namespace=aws:elasticbeanstalk:environment,OptionName=EnvironmentType,Value=LoadBalanced \
      Namespace=aws:elasticbeanstalk:environment:process:default,OptionName=Port,Value=8080
else
  echo "==> EB environment already exists"
fi

# ------------------------------------------------------------
# 3. IAM role for CodeBuild
# ------------------------------------------------------------
CODEBUILD_ROLE="codebuild-${APP_NAME}-role"
if ! aws iam get-role --role-name "${CODEBUILD_ROLE}" >/dev/null 2>&1; then
  echo "==> Creating IAM role for CodeBuild"
  aws iam create-role --role-name "${CODEBUILD_ROLE}" --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "codebuild.amazonaws.com"}, "Action": "sts:AssumeRole"}]
  }'
  aws iam put-role-policy --role-name "${CODEBUILD_ROLE}" --policy-name "codebuild-inline-policy" --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {\"Effect\": \"Allow\", \"Action\": [\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"], \"Resource\": \"*\"},
      {\"Effect\": \"Allow\", \"Action\": [\"s3:GetObject\",\"s3:PutObject\",\"s3:GetBucketAcl\",\"s3:GetBucketLocation\"], \"Resource\": [\"arn:aws:s3:::${ARTIFACT_BUCKET}\",\"arn:aws:s3:::${ARTIFACT_BUCKET}/*\"]}
    ]
  }"
  sleep 10
else
  echo "==> CodeBuild role already exists"
fi
CODEBUILD_ROLE_ARN=$(aws iam get-role --role-name "${CODEBUILD_ROLE}" --query 'Role.Arn' --output text)

# ------------------------------------------------------------
# 4. CodeBuild project
# ------------------------------------------------------------
if ! aws codebuild batch-get-projects --names "${APP_NAME}-build" --region "${AWS_REGION}" \
    --query "projects[0]" --output text | grep -q "${APP_NAME}"; then
  echo "==> Creating CodeBuild project: ${APP_NAME}-build"
  aws codebuild create-project \
    --name "${APP_NAME}-build" \
    --region "${AWS_REGION}" \
    --source "type=CODEPIPELINE,buildspec=buildspec.yml" \
    --artifacts "type=CODEPIPELINE" \
    --environment "type=LINUX_CONTAINER,image=aws/codebuild/amazonlinux2-x86_64-standard:5.0,computeType=BUILD_GENERAL1_SMALL" \
    --service-role "${CODEBUILD_ROLE_ARN}"
else
  echo "==> CodeBuild project already exists"
fi

# ------------------------------------------------------------
# 5. IAM role for CodePipeline
# ------------------------------------------------------------
PIPELINE_ROLE="codepipeline-${APP_NAME}-role"
if ! aws iam get-role --role-name "${PIPELINE_ROLE}" >/dev/null 2>&1; then
  echo "==> Creating IAM role for CodePipeline"
  aws iam create-role --role-name "${PIPELINE_ROLE}" --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "codepipeline.amazonaws.com"}, "Action": "sts:AssumeRole"}]
  }'
  aws iam put-role-policy --role-name "${PIPELINE_ROLE}" --policy-name "codepipeline-inline-policy" --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {\"Effect\": \"Allow\", \"Action\": [\"s3:GetObject\",\"s3:PutObject\",\"s3:GetBucketVersioning\",\"s3:GetBucketAcl\",\"s3:GetBucketLocation\"], \"Resource\": [\"arn:aws:s3:::${ARTIFACT_BUCKET}\",\"arn:aws:s3:::${ARTIFACT_BUCKET}/*\"]},
      {\"Effect\": \"Allow\", \"Action\": [\"codestar-connections:UseConnection\"], \"Resource\": \"${CONNECTION_ARN}\"},
      {\"Effect\": \"Allow\", \"Action\": [\"codebuild:BatchGetBuilds\",\"codebuild:StartBuild\"], \"Resource\": \"*\"},
      {\"Effect\": \"Allow\", \"Action\": [\"elasticbeanstalk:*\",\"ec2:*\",\"elasticloadbalancing:*\",\"autoscaling:*\",\"cloudwatch:*\",\"s3:*\",\"sns:*\",\"cloudformation:*\",\"rds:*\"], \"Resource\": \"*\"}
    ]
  }"
  sleep 10
else
  echo "==> CodePipeline role already exists"
fi
PIPELINE_ROLE_ARN=$(aws iam get-role --role-name "${PIPELINE_ROLE}" --query 'Role.Arn' --output text)

# ------------------------------------------------------------
# 6. CodePipeline: GitHub -> CodeBuild -> Elastic Beanstalk
# ------------------------------------------------------------
cat > /tmp/pipeline-${APP_NAME}.json <<EOF
{
  "pipeline": {
    "name": "${APP_NAME}-pipeline",
    "roleArn": "${PIPELINE_ROLE_ARN}",
    "artifactStore": { "type": "S3", "location": "${ARTIFACT_BUCKET}" },
    "stages": [
      {
        "name": "Source",
        "actions": [{
          "name": "Source",
          "actionTypeId": { "category": "Source", "owner": "AWS", "provider": "CodeStarSourceConnection", "version": "1" },
          "outputArtifacts": [{ "name": "SourceOutput" }],
          "configuration": {
            "ConnectionArn": "${CONNECTION_ARN}",
            "FullRepositoryId": "${GITHUB_OWNER}/${GITHUB_REPO}",
            "BranchName": "${BRANCH}"
          }
        }]
      },
      {
        "name": "Build",
        "actions": [{
          "name": "Build",
          "actionTypeId": { "category": "Build", "owner": "AWS", "provider": "CodeBuild", "version": "1" },
          "inputArtifacts": [{ "name": "SourceOutput" }],
          "outputArtifacts": [{ "name": "BuildOutput" }],
          "configuration": { "ProjectName": "${APP_NAME}-build" }
        }]
      },
      {
        "name": "Deploy",
        "actions": [{
          "name": "Deploy",
          "actionTypeId": { "category": "Deploy", "owner": "AWS", "provider": "ElasticBeanstalk", "version": "1" },
          "inputArtifacts": [{ "name": "BuildOutput" }],
          "configuration": { "ApplicationName": "${APP_NAME}", "EnvironmentName": "${ENV_NAME}" }
        }]
      }
    ]
  }
}
EOF

if ! aws codepipeline get-pipeline --name "${APP_NAME}-pipeline" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "==> Creating CodePipeline: ${APP_NAME}-pipeline"
  aws codepipeline create-pipeline --region "${AWS_REGION}" --cli-input-json "file:///tmp/pipeline-${APP_NAME}.json"
else
  echo "==> Pipeline already exists, updating definition"
  aws codepipeline update-pipeline --region "${AWS_REGION}" --cli-input-json "file:///tmp/pipeline-${APP_NAME}.json"
fi

echo ""
echo "==> Done. Every push to '${BRANCH}' on ${GITHUB_OWNER}/${GITHUB_REPO} will now:"
echo "    1. Trigger the pipeline"
echo "    2. Build your Nest app in CodeBuild (npm ci && npm run build)"
echo "    3. Deploy the result to Elastic Beanstalk"
echo ""
echo "==> Check environment URL once ready:"
echo "    aws elasticbeanstalk describe-environments --environment-names ${ENV_NAME} --region ${AWS_REGION} --query \"Environments[0].CNAME\" --output text"
echo ""
echo "==> Watch pipeline runs:"
echo "    aws codepipeline get-pipeline-state --name ${APP_NAME}-pipeline --region ${AWS_REGION}"
