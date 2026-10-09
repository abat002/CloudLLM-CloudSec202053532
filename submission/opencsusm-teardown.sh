#!/bin/bash
export REGION="us-east-1"
export OWNER="abat"
export KEY="opencsusm-$OWNER-key"

echo "finding instance"
IDS=$(aws ec2 describe-instances --region $REGION \
   --filters "Name=tag:Owner,Values=$OWNER" "Name=tag:Course,Values=CS446" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
   --query 'Reservations[].Instances[].InstanceId' --output text)

if [ -n "$IDS" ]; then
   echo "terminating: $IDS"
   aws ec2 terminate-instances --region $REGION --instance-ids $IDS
   aws ec2 wait instance-terminated --region $REGION --instance-ids $IDS
else
   echo "no matching instances found!"
fi

echo "deleting security group"
SG=$(aws ec2 describe-security-groups --region $REGION \
   --filters "Name=group-name,Values=opencsusm-sg" \
   --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG" != "None" ] && [ -n "$SG" ]; then
   aws ec2 delete-security-group --region $REGION --group-id "$SG"
else
   echo "no matching security group found!"
fi

echo "deleting key pair"
aws ec2 delete-key-pair --region $REGION --key-name "$KEY"
rm -f "$KEY.pem"
echo "deleting startup user data file init.sh"
rm init.sh

echo "done!"