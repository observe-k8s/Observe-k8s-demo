#!/usr/bin/env bash

################################################################################
### This script is based on information found in:
### - https://kubernetes-sigs.github.io/aws-alb-ingress-controller/guide/controller/setup/
### - https://aws.amazon.com/blogs/containers/using-alb-ingress-controller-with-amazon-eks-on-fargate/
###

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

################################################################################
### Pre-flight checks for dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "Please install jq before continuing"
    exit 1
fi

if ! command -v eksctl >/dev/null 2>&1; then
    echo "Please install eksctl before continuing"
    exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
    echo "Please install aws before continuing"
    exit 1
fi

################################################################################
### Parameters for end-users to set (defaults should be fine as of 03/2020)
TARGET_REGION=${1:-eu-west-1}
ALB_MANIFEST=${2:-https://raw.githubusercontent.com/kubernetes-sigs/aws-alb-ingress-controller/v1.1.5/docs/examples/alb-ingress-controller.yaml}
ALB_IAM_POLICY_MANIFEST=${3:-https://raw.githubusercontent.com/kubernetes-sigs/aws-alb-ingress-controller/v1.1.5/docs/examples/iam-policy.json}
ALB_RBAC_MANIFEST=${4:-https://raw.githubusercontent.com/kubernetes-sigs/aws-alb-ingress-controller/v1.1.5/docs/examples/rbac-role.yaml}
CLUSTER_NAME=noteless

# download and patch the ALB Ingress Controller (IC) manifest:
curl $ALB_MANIFEST -o alb-ingress-controller.yaml
TARGET_VPC=$(aws eks describe-cluster --name $CLUSTER_NAME | jq .cluster.resourcesVpcConfig.vpcId -r)
sed -i '.tmp' "s|# - --aws-region=us-west-1|- --aws-region=$TARGET_REGION|" alb-ingress-controller.yaml
sed -i '.tmp' "s|# - --cluster-name=devCluster|- --cluster-name=$CLUSTER_NAME|" alb-ingress-controller.yaml
sed -i '.tmp' "s|# - --aws-vpc-id=vpc-xxxxxx|- --aws-vpc-id=$TARGET_VPC|" alb-ingress-controller.yaml

# create the IAM policy for the ALB, used by the ALB IC service account
# to manage ALBs for us (based on Ingress resources we define in the cluster):
curl $ALB_IAM_POLICY_MANIFEST -o alb-ic-iam-policy.json
IAM_POLICY_ARN=$(aws iam create-policy \
        --policy-name $CLUSTER_NAME-alb-ic \
        --policy-document file://alb-ic-iam-policy.json \
        | jq .Policy.Arn -r)

# create an IRSA-enabled service account for the ALB IC:
eksctl create iamserviceaccount \
       --name alb-ingress-controller \
       --namespace kube-system \
       --cluster $CLUSTER_NAME \
       --attach-policy-arn $IAM_POLICY_ARN \
       --approve \
       --override-existing-serviceaccounts

# install ALB IC RBAC and ALB IC itself:
kubectl apply -f $ALB_RBAC_MANIFEST
kubectl apply -f alb-ingress-controller.yaml

# clean up:
rm alb-ingress-controller.yaml*
rm alb-ic-iam-policy.json

