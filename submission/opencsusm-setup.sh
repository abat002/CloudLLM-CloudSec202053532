#!/bin/bash
aws configure set region us-east-1
echo "get-caller-identity returns:"
aws sts get-caller-identity

export REGION="us-east-1"
export OWNER="abat"
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export KEY="opencsusm-$OWNER-key"

echo "creating keypair $KEY.pem"
aws ec2 create-key-pair --region $REGION --key-name "$KEY" --query KeyMaterial --output text > "$KEY.pem" && chmod 400 "$KEY.pem"

VPC=$(aws ec2 describe-vpcs --region $REGION --output text --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId')

echo "creating security group"
SG=$(aws ec2 create-security-group --region $REGION --vpc-id "$VPC" --group-name opencsusm-sg --description "OpenCSUSM LLM server" --query 'GroupId' --output text)

export MYIP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress --region $REGION --group-id "$SG" --protocol tcp --port 22 --cidr "${MYIP}/32"

# vLLM uses uses port 8000
aws ec2 authorize-security-group-ingress --region $REGION --group-id "$SG" --protocol tcp --port 8000 --cidr "${MYIP}/32"

export MODEL="Qwen/Qwen2.5-0.5B-Instruct"
echo "using model $MODEL"
echo "creating init.sh for startup user data"
cat << EOF > init.sh
#!/bin/bash
export HOME=/root
dnf update -y
dnf install python3.11 python3.11-pip -y
dnf install gcc gcc-c++ python3.11-devel -y
python3.11 -m pip install --upgrade pip
python3.11 -m pip install torch==2.8.0+cpu --index-url https://download.pytorch.org/whl/cpu
python3.11 -m pip install vllm-cpu==0.11.0.post2 transformers==4.57.6
python3.11 -m pip install --force-reinstall --no-deps torchvision==0.23.0 torchaudio==2.8.0 --index-url https://download.pytorch.org/whl/cpu
nohup python3.11 -m vllm.entrypoints.openai.api_server --model $MODEL --host 0.0.0.0 --port 8000 > /var/log/vllm.log 2>&1 &
EOF

echo "getting latest amazon linux ami"
AMI=$(aws ec2 describe-images --region $REGION --owners amazon --filters "Name=name,Values=al2023-ami-2023*-x86_64" Name=state,Values=available --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)

echo "launching instance (using m7i-flex.large as instance type for LLM)"
echo "using cpu-only version of vLLM for compatibility with m7i-flex"
T="{Key=Course,Value=CS446},{Key=Owner,Value=$OWNER}"
ID=$(aws ec2 run-instances --region $REGION --image-id "$AMI" --instance-type m7i-flex.large --key-name "$KEY" --security-group-ids "$SG" --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1 --user-data file://init.sh --tag-specifications "ResourceType=instance,Tags=[$T]" --output text --query 'Instances[0].InstanceId')

echo "waiting for instance to start"
aws ec2 wait instance-running --region $REGION --instance-ids "$ID"

PUBLIC_IP=$(aws ec2 describe-instances --region $REGION --instance-ids "$ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo "instance id: $ID"
echo "public ip: $PUBLIC_IP"

echo "the server is up, but vllm takes a few minutes to install. pinging the server every 15 seconds (times out after 30 mins)"
READY=0
for i in $(seq 1 120); do
   if curl -s -o /dev/null -m 5 "http://$PUBLIC_IP:8000/v1/models"; then
      READY=1
      break
   fi
   sleep 15
done

if [ "$READY" -eq 0 ]; then
   echo "vllm did not respond in time. ssh in and check /var/log/vllm.log"
   exit 1
fi

BODY=$(cat << 'JSON'
{
   "model": "Qwen/Qwen2.5-0.5B-Instruct",
   "messages": [
      {"role": "system", "content": "You are an assistant and remember names."},
      {"role": "user", "content": "Hi, I am John. What is my name?"}
   ]
}
JSON
)

echo "the model is running! sending default message:\nHi, I am John. What is my name?"
curl -s "http://$PUBLIC_IP:8000/v1/chat/completions" -H 'Content-Type: application/json' -d "$BODY" \
   | python3 -c 'import sys, json; print(json.load(sys.stdin)["choices"][0]["message"]["content"])'
echo ""

# interactive chat, only if a person is at the terminal (skipped when run unattended)
if [ -t 0 ]; then
   echo "test other messages if you want here!"
   echo "note: a new conversation is started for each message so it doesn't see previous messages, but in theory it should be able to continue a conversation if you provide those messages as well"
   echo "enter quit to exit"
   while true; do
      read -r -p "YOU: " MSG
      if [ -z "$MSG" ] || [ "$MSG" == "quit" ]; then
         break
      fi
      # python builds the json so quotes in your message cannot break it
      CHAT_BODY=$(MSG="$MSG" python3 -c 'import json, os; print(json.dumps({"model": os.environ["MODEL"], "messages": [{"role": "system", "content": "You are an assistant and remember names."}, {"role": "user", "content": os.environ["MSG"]}]}))')
      echo -n "MODEL: "
      curl -s "http://$PUBLIC_IP:8000/v1/chat/completions" -H 'Content-Type: application/json' -d "$CHAT_BODY" \
         | python3 -c 'import sys, json; print(json.load(sys.stdin)["choices"][0]["message"]["content"])'
   done
fi