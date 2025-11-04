- ssh 키 만들어서 github에 올림
- service account를 gcp에서 만들어서 설정함.
- 워크로드 아이덴티티 풀이란 뭘까??

GCP Compute Engine(GCE), Ansible, 그리고 GitHub Actions를 워크로드 아이덴티티 제휴(WIF)로 엮어 배포 환경을 구축하는 것은 현대적인 CI/CD 파이프라인의 핵심입니다. JSON 키가 필요 없는 **'Keyless' 인증**을 통해 보안을 극대화하는 이 과정을 '하나부터 열까지' 차근차근 설명해 드리겠습니다.

### 🏛️ 전체 아키텍처 비유: '신뢰 기반의 자동화된 건설 현장'

이 시스템의 핵심 원리는 \*\*'신원 보증을 통한 권한 대행'\*\*입니다.

1.  **GCP (건설 현장):** VM과 리소스가 생성되는 장소입니다.
2.  **GCP 서비스 계정 (SA) (현장 감독관 역할):** '서버를 건설할 권한'(`compute.admin`)을 가진 \*\*GCP 내부의 '역할'\*\*입니다. 이 감독관은 현장 밖으로 나가지 않습니다.
3.  **워크로드 아이덴티티 풀/공급자 (현장 출입 게이트):** "GitHub의 `my-org/my-repo` 저장소에서 온 작업만 신뢰한다"고 설정된 \*\*'보안 게이트'\*\*입니다.
4.  **GitHub Actions (신원 보증된 외부 작업자):** GitHub가 OIDC 토큰으로 신원을 보증한 \*\*'외부 작업자'\*\*입니다.
5.  **Ansible (작업 도구 세트):** 이 '작업자'가 들고 있는 \*\*'설계도(Playbook)'\*\*와 \*\*'건설 도구(Module)'\*\*입니다.

**전체 흐름:**
외부 작업자(GitHub Action)가 출입 게이트(WIF)에 도착해 신분증(OIDC 토큰)을 보여줍니다. -\> 게이트는 "당신은 `my-org/my-repo`에서 왔으니 신뢰할 수 있군요"라고 확인합니다. -\> "GCP 내부의 '현장 감독관'(SA) 역할을 \*\*1시간 동안 대행(impersonate)\*\*할 수 있는 임시 출입증을 발급해 드립니다." -\> 작업자(Action)는 임시 출입증을 받고, 자신의 도구(Ansible)를 사용해 현장(GCP)에 서버를 건설(프로비저닝)합니다.

-----

### 1단계: SSH 키 및 GitHub 리포지토리 준비

가장 먼저 Ansible이 GCE에 접속할 때 사용할 SSH 키와 코드를 저장할 공간이 필요합니다.

1.  **SSH 키 생성:**

      * Ansible이 GCE VM에 (API가 아닌) SSH로 접속하여 *구성* 작업을 할 때 필요합니다.
      * 로컬 터미널에서 실행합니다. (키가 이미 있다면 생략 가능)

    <!-- end list -->

    ```bash
    ssh-keygen -t rsa -b 4096 -f ~/gcp_key -C "ansible-gcp-key"
    # ~/gcp_key (비공개 키)와 ~/gcp_key.pub (공개 키) 파일이 생성됩니다.
    ```

2.  **GitHub 리포지토리 생성:**

      * (예: `my-org/gcp-ansible-deploy`) 리포지토리를 생성합니다.

3.  **GitHub Secrets 설정:**

      * 생성한 리포지토리의 **Settings \> Secrets and variables \> Actions**로 이동합니다.
      * \*\*'New repository secret'\*\*을 클릭하여 다음 비밀들을 등록합니다.
      * **`GCP_SSH_PRIVATE_KEY`:**
          * `~/gcp_key` (비공개 키) 파일의 내용을 **전체 복사**하여 붙여넣습니다. (-----BEGIN RSA PRIVATE KEY----- ... -----END RSA PRIVATE KEY-----)
      * **(참고)** 나머지 GCP 관련 정보(프로젝트 ID 등)도 여기에 추가할 것입니다.

4.  **공개 키 커밋:**

      * **`gcp_key.pub` (공개 키)** 파일은 비밀이 아니므로, 리포지토리에 **커밋**합니다. 이는 나중에 Ansible이 VM을 생성할 때 "이 공개 키를 가진 사용자만 접속 허용" 설정에 사용됩니다.

-----

### 2단계: GCP 설정 (서비스 계정 및 WIF)

이제 GCP가 GitHub Actions를 신뢰하도록 설정합니다.

1.  **서비스 계정(SA) 생성:**

      * Ansible이 대행할 '역할'입니다.
      * `gcloud` CLI (권장) 또는 GCP 콘솔에서 생성합니다.

    <!-- end list -->

    ```bash
    gcloud iam service-accounts create ansible-deployer \
        --display-name "Ansible Deployer SA"
    ```

      * **(중요)** 생성된 SA의 이메일 주소를 복사해 둡니다. (예: `ansible-deployer@<PROJECT_ID>.iam.gserviceaccount.com`)

2.  **SA에 권한 부여:**

      * 이 SA가 GCE를 관리할 수 있도록 `compute.admin` 역할을 부여합니다.

    <!-- end list -->

    ```bash
    gcloud projects add-iam-policy-binding <PROJECT_ID> \
        --member "serviceAccount:ansible-deployer@<PROJECT_ID>.iam.gserviceaccount.com" \
        --role "roles/compute.admin"
    ```

    *(참고: SA가 다른 SA를 다룰 필요가 있다면 `iam.serviceAccountUser` 역할도 필요할 수 있습니다.)*

3.  **워크로드 아이덴티티 풀(Pool) 생성:**

    ```bash
    gcloud iam workload-identity-pools create github-pool \
        --location "global" --display-name "GitHub Actions Pool"
    ```

4.  **WIF 공급자(Provider) 생성 (GitHub 신뢰 설정):**

      * 이 단계가 `my-org/my-repo`를 지정하는 핵심입니다.
      * (1) 풀의 전체 ID를 가져옵니다.
        ```bash
        gcloud iam workload-identity-pools describe github-pool --location global --format 'value(name)'
        # 출력 예: projects/123456789/locations/global/workloadIdentityPools/github-pool
        ```
      * (2) 공급자를 생성하고 **리포지토리 조건을 설정**합니다.
        ```bash
        gcloud iam workload-identity-pools providers create-oidc github-provider \
            --workload-identity-pool "github-pool" \
            --location "global" \
            --issuer-uri "https://token.actions.githubusercontent.com" \
            --attribute-mapping "google.subject=assertion.sub" \
            --attribute-condition "assertion.repository == 'my-org/gcp-ansible-deploy'"
        # (주의!) 'my-org/gcp-ansible-deploy'를 본인의 리포지토리 경로로 변경하세요.
        ```

5.  **WIF와 SA 연결 (권한 대행 설정):**

      * GitHub Actions(`assertion.repository`)가 SA(`ansible-deployer`)를 '대행'할 수 있도록 `workloadIdentityUser` 역할을 부여합니다.

    <!-- end list -->

    ```bash
    gcloud iam service-accounts add-iam-policy-binding \
        ansible-deployer@<PROJECT_ID>.iam.gserviceaccount.com \
        --role "roles/iam.workloadIdentityUser" \
        --member "principalSet://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-pool/subject/repo:my-org/gcp-ansible-deploy:ref:refs/heads/main"
    ```

      * **(주의\!)**
          * `<PROJECT_NUMBER>`: GCP 프로젝트 *번호* (ID 아님)
          * `subject/...`: `main` 브랜치에서 실행될 때만 허용하도록 더욱 엄격하게 제한했습니다. (`:ref:refs/heads/main` 부분)

6.  **GitHub Secrets에 나머지 정보 추가:**

      * 1단계에서 만든 GitHub Secrets로 돌아가 다음을 추가합니다.
      * **`GCP_PROJECT_ID`:** 여러분의 GCP 프로젝트 ID
      * **`GCP_SA_EMAIL`:** 1단계에서 복사한 SA 이메일 (예: `ansible-deployer@...`)
      * **`GCP_WIF_PROVIDER`:** 4-1단계에서 확인한 WIF 공급자 *전체 경로* (예: `projects/123456789/.../providers/github-provider`)

-----

### 3단계: Ansible 플레이북 및 인벤토리 작성

이제 리포지토리에 Ansible이 수행할 '설계도'를 추가합니다.

1.  **파일 구조:**

    ```
    .
    ├── .github/workflows/main.yml  (4단계에서 생성)
    ├── provision.yml               (VM 생성용)
    ├── configure.yml               (VM 설정용)
    ├── gcp_inventory.yml           (동적 인벤토리)
    ├── gcp_key.pub                 (1단계에서 커밋)
    └── ansible.cfg                 (Ansible 설정)
    ```

2.  **`ansible.cfg` (Ansible 설정 파일):**

      * SSH 접속 시 호스트 키 확인을 건너뛰고, 동적 인벤토리를 활성화합니다.

    <!-- end list -->

    ```ini
    [defaults]
    inventory = gcp_inventory.yml
    host_key_checking = False
    remote_user = ansible_user # VM에 생성할 사용자 이름

    [inventory]
    enable_plugins = google.cloud.gcp_compute
    ```

3.  **`provision.yml` (VM 생성 플레이북):**

      * 이 플레이북은 GCP API와 통신하므로 `hosts: localhost`에서 실행됩니다.
      * `gcp_key.pub` 파일의 내용을 읽어 VM의 메타데이터에 'ansible\_user'의 SSH 키로 등록합니다.

    <!-- end list -->

    ```yaml
    - name: GCP 인프라 프로비저닝
      hosts: localhost
      connection: local
      gather_facts: no

      vars:
        gcp_project: "{{ lookup('env', 'GCP_PROJECT_ID') }}" # GitHub Secrets에서 주입
        gcp_service_account_email: "{{ lookup('env', 'GCP_SA_EMAIL') }}" # GitHub Secrets에서 주입
        zone: "asia-northeast3-a" # 서울
        ssh_user: "ansible_user"
        ssh_pub_key: "{{ lookup('file', 'gcp_key.pub') }}" # 리포지토리의 공개 키 파일

      tasks:
        - name: GCE 인스턴스 생성
          google.cloud.gcp_compute_instance:
            name: "web-server-01"
            machine_type: "f1-micro"
            zone: "{{ zone }}"
            project: "{{ gcp_project }}"
            # (핵심) WIF를 통해 얻은 'Application Default Credentials'를 자동으로 사용
            auth_kind: "application" 
            
            disks:
              - auto_delete: true
                boot: true
                initialize_params:
                  source_image: "projects/debian-cloud/global/images/family/debian-11"
            network_interfaces:
              - access_configs: # 외부 IP 할당
                  - name: "External NAT"
                    type: "ONE_TO_ONE_NAT"
            
            # (핵심) 1단계의 공개 키를 'ansible_user' 사용자의 SSH 키로 등록
            metadata:
              ssh-keys: "{{ ssh_user }}:{{ ssh_pub_key }}"
            
            tags:
              items:
                - http-server # 방화벽 등에 사용할 태그

            state: present
    ```

4.  **`gcp_inventory.yml` (동적 인벤토리):**

      * Ansible이 GCP API를 쿼리하여 실시간으로 VM 목록을 가져오도록 합니다.

    <!-- end list -->

    ```yaml
    plugin: google.cloud.gcp_compute
    auth_kind: application # (핵심) WIF 인증 사용
    projects:
      - "{{ lookup('env', 'GCP_PROJECT_ID') }}"
    hostnames:
      - name # VM 이름으로 호스트 식별
    compose:
      ansible_host: networkInterfaces[0].accessConfigs[0].natIP # 외부 IP로 접속
    ```

5.  **`configure.yml` (VM 구성 플레이북):**

      * 이제 동적 인벤토리(`gcp_inventory.yml`)를 통해 찾은 VM에 SSH로 접속하여 Nginx를 설치합니다.

    <!-- end list -->

    ```yaml
    - name: 웹 서버 구성
      hosts: "tag_http_server" # provision.yml에서 설정한 태그로 호스트 그룹 자동 생성
      become: yes # 'sudo' 권한으로 실행

      tasks:
        - name: Nginx 설치
          apt:
            name: nginx
            state: present
            update_cache: yes
            
        - name: Nginx 시작
          service:
            name: nginx
            state: started
            enabled: yes
    ```

-----

### 4단계: GitHub Actions 워크플로 작성 (지휘자)

이제 모든 것을 하나로 묶는 자동화 스크립트입니다.

  * `.github/workflows/main.yml` 파일을 생성하고 다음 내용을 작성합니다.

<!-- end list -->

```yaml
name: Deploy GCP Infrastructure with Ansible

on:
  push:
    branches:
      - main # (중요) 2-5단계에서 설정한 브랜치와 일치해야 함

# (핵심) WIF를 위한 OIDC 토큰 발급 권한 부여
permissions:
  contents: 'read'
  id-token: 'write'

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v3

      # (핵심) 1. GCP 인증 (WIF 사용)
      - name: Authenticate to Google Cloud
        id: auth
        uses: 'google-github-actions/auth@v2'
        with:
          # GitHub Secrets에서 정보 가져오기
          workload_identity_provider: ${{ secrets.GCP_WIF_PROVIDER }}
          service_account: ${{ secrets.GCP_SA_EMAIL }}
          # (선택) 이 단계를 통해 gcloud SDK가 인증됨
          create_credentials_file: true

      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.9'

      - name: Install Ansible and GCP Libraries
        run: |
          pip install ansible google-auth

      # (핵심) 2. SSH 비공개 키 설정
      # configure.yml이 SSH로 접속할 수 있도록 GitHub Secret의 비공개 키를 등록
      - name: Setup SSH Key
        uses: webfactory/ssh-agent@v0.7.0
        with:
          ssh-private-key: ${{ secrets.GCP_SSH_PRIVATE_KEY }}

      # 3. Ansible 프로비저닝 실행 (VM 생성)
      - name: Run Ansible Provisioning
        env:
          # 플레이북에서 사용할 수 있도록 환경 변수로 주입
          GCP_PROJECT_ID: ${{ secrets.GCP_PROJECT_ID }}
          GCP_SA_EMAIL: ${{ secrets.GCP_SA_EMAIL }}
        run: |
          ansible-playbook provision.yml

      # 4. Ansible 구성 실행 (Nginx 설치)
      - name: Run Ansible Configuration
        env:
          GCP_PROJECT_ID: ${{ secrets.GCP_PROJECT_ID }}
        run: |
          echo "Waiting for SSH to be ready on new instance..."
          sleep 30 # VM 부팅 및 SSH 데몬 시작 대기 (실제로는 더 나은 wait_for 모듈 사용 권장)
          ansible-playbook configure.yml
```

-----

### 5단계: 실행 및 검증

1.  지금까지 작성한 모든 파일 (`provision.yml`, `configure.yml`, `gcp_inventory.yml`, `ansible.cfg`, `gcp_key.pub`, `.github/workflows/main.yml`)을 GitHub 리포지토리의 `main` 브랜치로 `git push` 합니다.
2.  Push가 감지되면 GitHub 리포지토리의 **'Actions'** 탭으로 이동합니다.
3.  `Deploy GCP Infrastructure with Ansible` 워크플로가 실행되는 것을 확인합니다.
4.  워크플로가 성공하면 GCP 콘솔의 **Compute Engine** 페이지로 이동합니다.
5.  `web-server-01` 인스턴스가 생성되고 실행 중인지 확인합니다.
6.  인스턴스의 외부 IP를 복사하여 웹 브라우저에 붙여넣으면 "Welcome to nginx\!" 페이지가 표시되어야 합니다. (단, GCP 방화벽에서 HTTP(80) 포트를 열어야 합니다.)

이것으로 JSON 키 없이 WIF와 Ansible, GitHub Actions를 사용한 완전 자동화 배포 환경 구축이 완료되었습니다.

GCP 방화벽 규칙을 Ansible로 추가하는 방법이나 VM을 삭제하는 플레이북을 만드는 방법에 대해 더 알아보고 싶으신가요?


----

이대로 했음.
