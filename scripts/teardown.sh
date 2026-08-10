#!/bin/bash
# Tier-2 teardown: deletes the WHOLE stack — VPC, security group, IAM, DNS
# records, DLM policy, SNS topic, and (if still present) the EC2 instance —
# down to zero running/billed infra. The S3 backup bucket has
# DeletionPolicy: Retain, so it survives even this — empty/delete it
# yourself once you've confirmed you don't need the backups (see the
# command this script prints below).
#
# For tier-1 teardown instead — keep the VPC/SG/IAM/S3 backups/DNS/DLM/SNS
# in place, only tear down the EC2 instance/EBS volume/EIP association —
# use `DEPLOY_COMPUTE=false scripts/deploy.sh` (a stack update, not a
# delete). See POST_DEPLOY.md's teardown section.
set -euo pipefail
PROFILE="${AWS_PROFILE:-dev-lab}"
REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-minecraft-server}"

read -rp "Delete CloudFormation stack '$STACK_NAME' in $REGION (profile $PROFILE)? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

aws cloudformation delete-stack --profile "$PROFILE" --region "$REGION" --stack-name "$STACK_NAME"
echo "Delete initiated. Track with:"
echo "  aws cloudformation describe-stacks --profile $PROFILE --region $REGION --stack-name $STACK_NAME"
echo
echo "The backup S3 bucket was retained. To remove it once you're sure:"
echo "  aws s3 rb s3://minecraft-backups-<account-id>-$REGION --force --profile $PROFILE"
