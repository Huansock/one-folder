#!/bin/bash
set -e

# 설정 변수 (설정되지 않은 경우 입력 요청)
PROJECT_ID="${GCP_PROJECT_ID}"
BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID}"
DOMAIN_NAME="${GCP_DOMAIN_NAME}"
GITHUB_REPO="${GITHUB_REPO}" # 형식: owner/repo
REGION="us-central1"
ZONE="us-central1-a"
VM_NAME="web-server-01"
SERVICE_ACCOUNT_NAME="github-actions-sa"
WIF_POOL_NAME="github-wif-pool"
WIF_PROVIDER_NAME="github-wif-provider"

# 색상
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}GCP 인프라 설정을 시작합니다...${NC}"

# 1. 필수 조건 확인
if ! command -v gcloud >/dev/null; then
    echo "오류: gcloud CLI가 설치되어 있지 않습니다."
    exit 1
fi

# 2. 정보 수집
if [ -z "$PROJECT_ID" ]; then
    gcloud projects list
    read -p "GCP 프로젝트 ID를 입력하세요 (새로 생성하거나 기존 ID): " PROJECT_ID
fi

if [ -z "$BILLING_ACCOUNT_ID" ]; then
    echo "사용 가능한 결제 계정:"
    gcloud billing accounts list --format="table(name, displayName)"
    read -p "결제 계정 ID를 입력하세요: " BILLING_ACCOUNT_ID
fi

if [ -z "$DOMAIN_NAME" ]; then
    read -p "도메인 이름을 입력하세요 (예: example.com): " DOMAIN_NAME
fi

if [ -z "$GITHUB_REPO" ]; then
    read -p "GitHub 저장소를 입력하세요 (owner/repo): " GITHUB_REPO
fi

# 3. 프로젝트 설정
echo -e "${GREEN}프로젝트 설정 중: $PROJECT_ID${NC}"
if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
    echo "프로젝트가 이미 존재합니다."
else
    echo "프로젝트를 생성하는 중..."
    gcloud projects create "$PROJECT_ID" --name="SvelteKit Project"
fi

# 기본 프로젝트를 설정합니다.
gcloud config set project "$PROJECT_ID"

echo "결제 계정 연결 중..."
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT_ID"

echo "API 활성화 중..."
gcloud services enable compute.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com iamcredentials.googleapis.com

# 4. IAM 및 워크로드 아이덴티티 연동(WIF)
echo -e "${GREEN}IAM 및 WIF 설정 중...${NC}"

# 서비스 계정 생성
if ! gcloud iam service-accounts describe "$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com" >/dev/null 2>&1; then
    gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="GitHub Actions SA"
fi

SA_EMAIL="$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com"

# 역할 부여
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA_EMAIL" --role="roles/compute.admin"
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA_EMAIL" --role="roles/iam.serviceAccountUser"
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA_EMAIL" --role="roles/iap.tunnelResourceAccessor"

# WIF 풀 생성
if ! gcloud iam workload-identity-pools describe "$WIF_POOL_NAME" --location="global" >/dev/null 2>&1; then
    gcloud iam workload-identity-pools create "$WIF_POOL_NAME" --location="global" --display-name="GitHub Actions Pool"
fi

# WIF 공급자 생성
WORKLOAD_IDENTITY_POOL_ID=$(gcloud iam workload-identity-pools describe "$WIF_POOL_NAME" --location="global" --format="value(name)")

if ! gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER_NAME" --workload-identity-pool="$WIF_POOL_NAME" --location="global" >/dev/null 2>&1; then
    gcloud iam workload-identity-pools providers create "$WIF_PROVIDER_NAME" \
        --workload-identity-pool="$WIF_POOL_NAME" \
        --location="global" \
        --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
        --issuer-uri="https://token.actions.githubusercontent.com"
fi

# WIF를 서비스 계정에 바인딩
REPO_MEMBER="principalSet://iam.googleapis.com/${WORKLOAD_IDENTITY_POOL_ID}/attribute.repository/${GITHUB_REPO}"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --role="roles/iam.workloadIdentityUser" \
    --member="$REPO_MEMBER"

WIF_PROVIDER_RESOURCE_NAME=$(gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER_NAME" --workload-identity-pool="$WIF_POOL_NAME" --location="global" --format="value(name)")

# 5. 네트워크 및 보안
echo -e "${GREEN}네트워크 및 보안 설정 중...${NC}"

# 고정 IP 생성
if ! gcloud compute addresses describe "$VM_NAME-ip" --region="$REGION" >/dev/null 2>&1; then
    gcloud compute addresses create "$VM_NAME-ip" --region="$REGION"
fi
STATIC_IP=$(gcloud compute addresses describe "$VM_NAME-ip" --region="$REGION" --format="value(address)")

# 방화벽 규칙
if ! gcloud compute firewall-rules describe "allow-http-https" >/dev/null 2>&1; then
    gcloud compute firewall-rules create "allow-http-https" --allow tcp:80,tcp:443 --target-tags="http-server"
fi

# SSH 키
mkdir -p infrastructure
SSH_KEY_PATH="infrastructure/gcp_key"
if [ ! -f "$SSH_KEY_PATH" ]; then
    ssh-keygen -t rsa -f "$SSH_KEY_PATH" -C "ansible" -N ""
fi
SSH_PUB_KEY=$(cat "$SSH_KEY_PATH.pub")

# 6. VM 생성
echo -e "${GREEN}VM 인스턴스 생성 중...${NC}"
if ! gcloud compute instances describe "$VM_NAME" --zone="$ZONE" >/dev/null 2>&1; then
    gcloud compute instances create "$VM_NAME" \
        --zone="$ZONE" \
        --machine-type="e2-medium" \
        --image-family="ubuntu-2204-lts" \
        --image-project="ubuntu-os-cloud" \
        --address="$STATIC_IP" \
        --tags="http-server" \
        --metadata="ssh-keys=ansible:$SSH_PUB_KEY"
else
    echo "VM $VM_NAME 이(가) 이미 존재합니다."
fi

# 7. 정보 출력
echo -e "${GREEN}설정 완료!${NC}"
echo "------------------------------------------------"
echo "Project ID: $PROJECT_ID"
echo "Service Account: $SA_EMAIL"
echo "WIF Provider: $WIF_PROVIDER_RESOURCE_NAME"
echo "VM IP Address: $STATIC_IP"
echo "Domain: $DOMAIN_NAME"
echo "------------------------------------------------"
echo "다음 단계:"
echo "1. dnsexit.com으로 이동하여 $DOMAIN_NAME 의 A 레코드를 $STATIC_IP 로 설정하세요."
echo "2. GitHub 저장소($GITHUB_REPO)에 다음 Secrets를 추가하세요:"
echo "   - GCP_PROJECT_ID: $PROJECT_ID"
echo "   - GCP_WORKLOAD_IDENTITY_PROVIDER: $WIF_PROVIDER_RESOURCE_NAME"
echo "   - GCP_SERVICE_ACCOUNT: $SA_EMAIL"
echo "   - SSH_PRIVATE_KEY: (infrastructure/gcp_key 파일의 내용)"
echo "------------------------------------------------"
