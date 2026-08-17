#!/bin/bash
# Deploys/updates the Minecraft stack via CloudFormation, using your
# dev-lab AWS CLI profile. Safe to re-run — `deploy` is idempotent and only
# applies the diff.
#
# Usage:
#   ./deploy.sh                     # interactive prompts for required params
#   ADMIN_CIDR=1.2.3.4/32 NOTIFICATION_EMAIL=you@example.com ./deploy.sh
#
#   # Tier-1 teardown: tear down EC2/EBS/EIP-association/alarms, keep
#   # VPC/SG/IAM/S3 backups/DNS/DLM/SNS in place:
#   DEPLOY_COMPUTE=false ./deploy.sh
#
#   # Rebuild after a tier-1 teardown (or a genuine EC2/EBS failure): a
#   # fresh instance boots via the same bootstrap and re-associates with
#   # the same Elastic IP, so DNS needs no changes. World data is gone —
#   # restore from the S3 backup bucket or a DLM snapshot afterward.
#   ./deploy.sh
#
# Redeploying from scratch after a full (tier-2) teardown: the S3 backup
# bucket survives on purpose (DeletionPolicy: Retain) and this script
# auto-detects that and adjusts (BackupBucketExists) — no flag needed.
#
set -euo pipefail

PROFILE="${AWS_PROFILE:-dev-lab}"
REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-minecraft-server}"
TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/cloudformation/minecraft-stack.yaml"

echo "Using profile: $PROFILE   region: $REGION   stack: $STACK_NAME"

if ! aws sts get-caller-identity --profile "$PROFILE" --region "$REGION" >/dev/null 2>&1; then
  echo "Could not authenticate with profile '$PROFILE'. Check 'aws configure list-profiles'." >&2
  exit 1
fi

if [ -z "${ADMIN_CIDR:-}" ]; then
  MY_IP=$(curl -s https://checkip.amazonaws.com || true)
  read -rp "CIDR allowed to reach the panel (443) [${MY_IP:-e.g. 1.2.3.4}/32]: " ADMIN_CIDR
  ADMIN_CIDR="${ADMIN_CIDR:-${MY_IP}/32}"
fi

if [ -z "${NOTIFICATION_EMAIL:-}" ]; then
  read -rp "Email for CloudWatch alarm notifications: " NOTIFICATION_EMAIL
fi

GAME_CIDR="${GAME_CIDR:-0.0.0.0/0}"
INSTANCE_TYPE="${INSTANCE_TYPE:-c6g.xlarge}"
DATA_VOLUME_SIZE="${DATA_VOLUME_SIZE:-60}"
ROOT_DOMAIN="${ROOT_DOMAIN:-charliesystems.ai}"
SUBDOMAIN_LABEL="${SUBDOMAIN_LABEL:-blockparty}"
DEPLOY_COMPUTE="${DEPLOY_COMPUTE:-true}"

# S3 bucket names are globally unique and the backup bucket has
# DeletionPolicy: Retain, so it can survive a tier-2 teardown and still be
# sitting there on a from-scratch redeploy — trying to create it again
# fails CloudFormation's early validation before the changeset even builds.
# Auto-detect instead of requiring anyone to remember a flag.
if [ -z "${BACKUP_BUCKET_EXISTS:-}" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)
  EXPECTED_BUCKET="minecraft-backups-${ACCOUNT_ID}-${REGION}"
  if aws s3api head-bucket --profile "$PROFILE" --region "$REGION" --bucket "$EXPECTED_BUCKET" >/dev/null 2>&1; then
    BACKUP_BUCKET_EXISTS=true
    echo "Found existing backup bucket $EXPECTED_BUCKET — will reference it instead of trying to create it."
  else
    BACKUP_BUCKET_EXISTS=false
  fi
fi

if [ -z "${HOSTED_ZONE_ID:-}" ]; then
  echo "Looking up the Route 53 hosted zone for $ROOT_DOMAIN..."
  HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --profile "$PROFILE" \
    --dns-name "${ROOT_DOMAIN}." \
    --query "HostedZones[0].Id" --output text 2>/dev/null | sed 's#/hostedzone/##')
  if [ -z "$HOSTED_ZONE_ID" ] || [ "$HOSTED_ZONE_ID" = "None" ]; then
    echo "Could not find a hosted zone for $ROOT_DOMAIN in profile '$PROFILE'." >&2
    echo "Set HOSTED_ZONE_ID explicitly, or check 'aws route53 list-hosted-zones'." >&2
    exit 1
  fi
fi

echo
echo "About to deploy with:"
echo "  AdminCidr:         $ADMIN_CIDR"
echo "  GameCidr:          $GAME_CIDR"
echo "  NotificationEmail: $NOTIFICATION_EMAIL"
echo "  InstanceType:      $INSTANCE_TYPE"
echo "  DataVolumeSizeGiB: $DATA_VOLUME_SIZE"
echo "  Subdomain:         ${SUBDOMAIN_LABEL}.${ROOT_DOMAIN} (+ wildcard)"
echo "  HostedZoneId:      $HOSTED_ZONE_ID"
echo "  DeployCompute:     $DEPLOY_COMPUTE"
echo "  BackupBucketExists: $BACKUP_BUCKET_EXISTS"
echo
if [ "$DEPLOY_COMPUTE" = "false" ]; then
  echo "DeployCompute=false: this TEARS DOWN the EC2 instance, its EBS data volume,"
  echo "the Elastic IP association, and the instance's CloudWatch alarms. World data"
  echo "on the EBS volume is gone after this — the VPC, security group, IAM, S3"
  echo "backup bucket, DNS records, SES mail identity, DLM snapshot policy, and SNS"
  echo "topics all stay in place. Re-run without DEPLOY_COMPUTE=false to rebuild."
else
  echo "This will create billed AWS resources (EC2, EBS, EIP, S3, CloudWatch, SNS,"
  echo "Route 53 records, SES) and gives the instance write access to that one hosted zone"
  echo "(needed for automatic wildcard cert issuance/renewal via certbot's DNS-01 challenge)."
fi
read -rp "Continue? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

aws cloudformation deploy \
  --profile "$PROFILE" \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    AdminCidr="$ADMIN_CIDR" \
    GameCidr="$GAME_CIDR" \
    NotificationEmail="$NOTIFICATION_EMAIL" \
    InstanceType="$INSTANCE_TYPE" \
    DataVolumeSizeGiB="$DATA_VOLUME_SIZE" \
    RootDomain="$ROOT_DOMAIN" \
    SubdomainLabel="$SUBDOMAIN_LABEL" \
    HostedZoneId="$HOSTED_ZONE_ID" \
    DeployCompute="$DEPLOY_COMPUTE" \
    BackupBucketExists="$BACKUP_BUCKET_EXISTS" \
  --tags \
    Project=blockparty \
    Build="$STACK_NAME" \
    ManagedBy=cloudformation

echo
echo "=== Stack outputs ==="
aws cloudformation describe-stacks \
  --profile "$PROFILE" --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs" --output table

echo
if [ "$DEPLOY_COMPUTE" = "false" ]; then
  echo "Compute torn down. Core infra (VPC/SG/IAM/S3 backups/DNS/SES/DLM/SNS) is still"
  echo "in place. Re-run without DEPLOY_COMPUTE=false to rebuild the instance."
else
  echo "Next: confirm BOTH SNS email subscriptions in your inbox (CloudWatch alarms"
  echo "and minecraft-server-ses-events for bounces/complaints), then wait ~3-5 min"
  echo "for bootstrap to finish (check with the SsmConnectCommand output above,"
  echo "then: sudo tail -f /var/log/bootstrap.log). After that, follow POST_DEPLOY.md"
  echo "(admin account, node registration, server creation, then the wildcard TLS cert)."
fi
