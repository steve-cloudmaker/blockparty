#!/bin/bash
# Tears down the stack. The S3 backup bucket has DeletionPolicy: Retain, so
# it survives stack deletion on purpose — empty/delete it yourself once
# you've confirmed you don't need the backups.
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
