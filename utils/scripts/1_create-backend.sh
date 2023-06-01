#!/bin/bash

cd "$WORKING_DIR" || {
  echo "Error moving to the application's root directory."
  exit 1
}

function assignS3BucketForAccessLogs() {
  echo ""
  read -r -p 'Do you want to create a <S3 Bucket> to store the ALB access logs? [Y/n] ' create_s3_bucket
  if [ -z "$create_s3_bucket" ] || [ "$create_s3_bucket" == "Y" ] || [ "$create_s3_bucket" == "y" ]; then
    read -r -p 'Please, enter the <Bucket> name: ' s3_bucket_name
    if [ -z "$s3_bucket_name" ]; then
      echo ""
      echo "Error: S3 Bucket name is required."
      sh "$WORKING_DIR"/utils/scripts/helper/1_revert-automated-scripts.sh
      exit 1
    fi
    echo ""
    echo "CREATING S3 BUCKET..."
    aws s3api create-bucket                   \
        --bucket "$s3_bucket_name"            \
        --profile "$AWS_WORKLOADS_PROFILE"
    echo "DONE!"

    echo ""
    echo "ASSIGNING S3 BUCKET POLICY..."
    workloads_account_id=$(aws configure get sso_account_id --profile "$AWS_WORKLOADS_PROFILE")
    sed -i'.bak' -e "s/aws_account_id/$workloads_account_id/g; s/bucket_name/$s3_bucket_name/g" \
          "$WORKING_DIR"/utils/aws/iam/s3-alb-access-logs-policy.json
    rm -f "$WORKING_DIR"/utils/aws/iam/s3-alb-access-logs-policy.json.bak

    aws s3api put-bucket-policy               \
        --bucket "$s3_bucket_name"            \
        --policy file://"$WORKING_DIR"/utils/aws/iam/s3-alb-access-logs-policy.json \
        --profile "$AWS_WORKLOADS_PROFILE"
    echo "DONE!"
  else
    read -r -p 'Enter the existing <S3 Bucket> name: [city-tasks-alb-dev]' s3_bucket_name
    if [ -z "$s3_bucket_name" ]; then
      s3_bucket_name='city-tasks-alb-dev'
    fi
    echo "DONE!"
  fi
  ### UPDATING ENVIRONMENT MANIFEST FILE
  sed -i'.bak' -e "s/s3_bucket_name/$s3_bucket_name/g" \
        "$WORKING_DIR"/copilot/environments/"$AWS_WORKLOADS_ENV"/manifest.yml
  rm -f "$WORKING_DIR"/copilot/environments/"$AWS_WORKLOADS_ENV"/manifest.yml.bak
}

echo ""
read -r -p 'Enter the <Domain Name> to use in your ALB: [example.com] ' domain_name
if [ -z "$domain_name" ]; then
  domain_name='example.com'
fi

echo "Getting Certificate ARN using profile: '$AWS_WORKLOADS_PROFILE'"
acm_arn=$(aws acm list-certificates   \
  --profile "$AWS_WORKLOADS_PROFILE"  \
  --output text                       \
  --query "CertificateSummaryList[?contains(DomainName, '$domain_name')].[CertificateArn]")
if [ -z "$acm_arn" ]; then
  echo ""
  echo "Error: No ACM Certificate found with name: '$domain_name'."
  echo "You can create an <ACM Certificate> using 'Helper Menu' option: '3. Request ACM Certificate'."
  exit 1
fi
echo "ACM Certificate found: $acm_arn"

assignS3BucketForAccessLogs

echo ""
echo "Getting information from AWS. Please wait..."

cognito_user_pool_id=$(aws cognito-idp list-user-pools --max-results 1 --output text  \
  --query "UserPools[?contains(Name, 'CityUserPool')].[Id]"                           \
  --profile "$AWS_IDP_PROFILE")
if [ -z "$cognito_user_pool_id" ]; then
  echo ""
  echo "Error: No Cognito User Pool found with name: 'CityUserPool' in the profile: '$AWS_IDP_PROFILE'."
  sh "$WORKING_DIR"/utils/scripts/helper/1_revert-automated-scripts.sh
  exit 0
fi

### UPDATING API MANIFEST FILE
idp_aws_region=$(aws configure get region --profile "$AWS_IDP_PROFILE")
sed -i'.bak' -e "s/root_domain_name/$domain_name/g; s/idp_aws_region/$idp_aws_region/g; s/cognito_user_pool_id/$cognito_user_pool_id/g"  \
      "$WORKING_DIR"/copilot/api/manifest.yml
rm -f "$WORKING_DIR"/copilot/api/manifest.yml.bak

### UPDATING ENVIRONMENT MANIFEST FILE
workloads_aws_region=$(aws configure get region --profile "$AWS_WORKLOADS_PROFILE")
workloads_aws_account_id=$(aws configure get sso_account_id --profile "$AWS_WORKLOADS_PROFILE")
acm_certificate_number=$(echo "$acm_arn" | cut -d'/' -f2)
sed -i'.bak' -e "s/workloads_aws_region/$workloads_aws_region/g; s/workloads_aws_account_id/$workloads_aws_account_id/g; s/acm_certificate_number/$acm_certificate_number/g" \
      "$WORKING_DIR"/copilot/environments/"$AWS_WORKLOADS_ENV"/manifest.yml
rm -f "$WORKING_DIR"/copilot/environments/"$AWS_WORKLOADS_ENV"/manifest.yml.bak
echo "DONE!"

echo ""
echo "INITIALIZING COPILOT STACK ON AWS..."
copilot init                              \
  --app city-tasks                        \
  --name api                              \
  --type 'Load Balanced Web Service'      \
  --dockerfile './Dockerfile-native'      \
  --port 8080                             \
  --tag '1.5.0'
echo ""
echo "DONE!"

echo ""
echo "INITIALIZING ENVIRONMENT ON AWS..."
copilot env init                          \
  --app city-tasks                        \
  --name "$AWS_WORKLOADS_ENV"             \
  --import-cert-arns "$acm_arn"           \
  --profile "$AWS_WORKLOADS_PROFILE"      \
  --default-config "$WORKING_DIR"/copilot/environments/"$AWS_WORKLOADS_ENV"/manifest.yml
echo ""
echo "DONE!"

echo ""
echo "DEPLOYING ENVIRONMENT NETWORKING ON AWS..."
copilot env deploy                        \
  --app city-tasks                        \
  --name "$AWS_WORKLOADS_ENV"
echo ""
echo "DONE!"

echo ""
echo "DEPLOYING CONTAINER APPLICATION ON AWS..."
copilot deploy                            \
  --app city-tasks                        \
  --name api                              \
  --env "$AWS_WORKLOADS_ENV"              \
  --tag '1.5.0'                           \
  --resource-tags project=Hiperium,copilot-application-type=api,copilot-application-version=1.5.0
echo ""
echo "DONE!"

echo ""
echo "GETTING ALB HOST NAME..."
alb_domain_name=$(aws cloudformation describe-stacks --stack-name city-tasks-"$AWS_WORKLOADS_ENV" \
  --query "Stacks[0].Outputs[?OutputKey=='PublicLoadBalancerDNSName'].OutputValue" \
  --output text \
  --profile "$AWS_WORKLOADS_PROFILE")
echo "ALB Domain Name: $alb_domain_name"

echo ""
echo "IMPORTANT!!: Create new CNAME record in your Route53 Hosted Zone with your ALB Domain Name."
echo ""
echo "DONE!"
