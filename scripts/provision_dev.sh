#!/usr/bin/env bash
# 42 서버 개발자 온보딩: 계정 생성 + 개인 dev 컨테이너 발급.
#
# 사용법 (42 서버에서 admin/sudo 로 실행):
#   sudo ./provision_dev.sh <username> <pubkey-file> [gpu-devices]
#   예: sudo ./provision_dev.sh dhkim keys/dhkim.pub          # GPU 전체 공유 (기본)
#       sudo ./provision_dev.sh dhkim keys/dhkim.pub 2,3      # 특정 GPU 만
#
# 하는 일:
#   1. Unix 계정 생성 (비밀번호 잠금, SSH 키 인증만)
#   2. docker 그룹 추가 (⚠️ 호스트 root 등가 — README 의 보안 절 참조)
#   3. 개발자 UID 로 이미지 빌드 (pia/dev-<user>)
#   4. GPU·리소스 제한 걸린 컨테이너 dev-<user> 실행 (홈 + weights + datasets 마운트)
#   5. 호스트 ~/.bashrc 에 conda 활성화 snippet 추가 (컨테이너 안에서만 동작)
set -euo pipefail

# ---- 팀 공통 설정 (필요 시 수정) ----
BASE_IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../docker" && pwd)"
DATASETS_DIR="/data/datasets"        # 공유 데이터셋 (read-only 마운트)
WEIGHTS_DIR="/data/weights"          # 공유 모델 weight (전 계정 read-write)
CPUS="16"
MEMORY="64g"
SHM_SIZE="16g"
# -------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: sudo 로 실행하세요." >&2
    exit 1
fi

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "usage: sudo $0 <username> <pubkey-file> [gpu-devices]" >&2
    echo "  gpu-devices 생략 시 전체 GPU 공유(--gpus all)" >&2
    exit 1
fi

USERNAME="$1"
PUBKEY_FILE="$2"
GPU_DEVICES="${3:-all}"

if [[ ! -f "$PUBKEY_FILE" ]]; then
    echo "ERROR: 공개키 파일이 없습니다: $PUBKEY_FILE" >&2
    exit 1
fi
if ! ssh-keygen -l -f "$PUBKEY_FILE" >/dev/null 2>&1; then
    echo "ERROR: 유효한 SSH 공개키가 아닙니다: $PUBKEY_FILE" >&2
    exit 1
fi

# ---- 1. 계정 생성 ----
if id "$USERNAME" &>/dev/null; then
    echo "[skip] 계정 $USERNAME 이미 존재"
else
    useradd -m -s /bin/bash "$USERNAME"
    passwd -l "$USERNAME"   # 비밀번호 로그인 차단 (키 인증만)
    echo "[ok] 계정 생성: $USERNAME"
fi

HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
DEV_UID="$(id -u "$USERNAME")"
DEV_GID="$(id -g "$USERNAME")"

# ---- SSH 키 등록 ----
install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$HOME_DIR/.ssh"
touch "$HOME_DIR/.ssh/authorized_keys"
if ! grep -qF "$(cat "$PUBKEY_FILE")" "$HOME_DIR/.ssh/authorized_keys"; then
    cat "$PUBKEY_FILE" >> "$HOME_DIR/.ssh/authorized_keys"
fi
chown "$USERNAME:$USERNAME" "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
echo "[ok] SSH 공개키 등록"

# ---- 2. docker 그룹 ----
usermod -aG docker "$USERNAME"
echo "[ok] docker 그룹 추가 (주의: 호스트 root 등가 권한)"

# ---- 공유 weights 디렉터리 (전 계정 rw) ----
if [[ ! -d "$WEIGHTS_DIR" ]]; then
    mkdir -p "$WEIGHTS_DIR"
    chmod 2775 "$WEIGHTS_DIR"    # setgid — 새 파일이 그룹 소유 유지
    echo "[ok] 공유 weights 디렉터리 생성: $WEIGHTS_DIR"
fi

# ---- 3. 개인 이미지 빌드 (UID 를 구워 볼륨 소유권을 맞춘다) ----
IMAGE="pia/dev-${USERNAME}"
docker build -t "$IMAGE" \
    --build-arg USERNAME="$USERNAME" \
    --build-arg UID="$DEV_UID" \
    --build-arg GID="$DEV_GID" \
    "$BASE_IMAGE_DIR"
echo "[ok] 이미지 빌드: $IMAGE"

# ---- 4. 컨테이너 실행 ----
CONTAINER="dev-${USERNAME}"
if [[ "$GPU_DEVICES" == "all" ]]; then
    GPU_FLAG=(--gpus all)
else
    GPU_FLAG=(--gpus "\"device=${GPU_DEVICES}\"")
fi

if docker inspect "$CONTAINER" &>/dev/null; then
    echo "[skip] 컨테이너 $CONTAINER 이미 존재 — 재발급하려면 먼저:" >&2
    echo "       docker rm -f $CONTAINER" >&2
else
    install -d -o "$USERNAME" -g "$USERNAME" "$HOME_DIR/work"
    DATASET_MOUNT=()
    if [[ -d "$DATASETS_DIR" ]]; then
        DATASET_MOUNT=(-v "$DATASETS_DIR":/datasets:ro)
    else
        echo "[warn] $DATASETS_DIR 없음 — 데이터셋 마운트 생략"
    fi
    docker run -d --name "$CONTAINER" \
        --restart unless-stopped \
        "${GPU_FLAG[@]}" \
        --cpus "$CPUS" --memory "$MEMORY" --shm-size "$SHM_SIZE" \
        --label "owner=${USERNAME}" \
        -v "$HOME_DIR":"/home/${USERNAME}" \
        -v "$WEIGHTS_DIR":/weights \
        "${DATASET_MOUNT[@]}" \
        -w "/home/${USERNAME}/work" \
        "$IMAGE"
    echo "[ok] 컨테이너 실행: $CONTAINER (GPU=${GPU_DEVICES})"
fi

# ---- 5. conda 활성화 snippet (호스트 ~/.bashrc — 컨테이너 안에서만 발동) ----
SNIPPET_MARK="# >>> 42-dev-env conda >>>"
if ! grep -qF "$SNIPPET_MARK" "$HOME_DIR/.bashrc" 2>/dev/null; then
    cat >> "$HOME_DIR/.bashrc" <<'EOF'

# >>> 42-dev-env conda >>>
# 컨테이너 안(/opt/conda 존재)에서만 conda 초기화 + dev env 활성화
if [ -f /opt/conda/etc/profile.d/conda.sh ]; then
    . /opt/conda/etc/profile.d/conda.sh
    conda activate dev
fi
# <<< 42-dev-env conda <<<
EOF
    chown "$USERNAME:$USERNAME" "$HOME_DIR/.bashrc"
    echo "[ok] ~/.bashrc 에 conda 활성화 snippet 추가"
fi

cat <<EOF

=== 발급 완료: $USERNAME ===
접속 안내 (개발자에게 전달):
  1) ssh ${USERNAME}@<42서버주소>
  2) docker exec -it ${CONTAINER} bash    # conda dev env 자동 활성화
  VS Code: Remote-SSH 로 호스트 접속 후
           "Dev Containers: Attach to Running Container" → ${CONTAINER}

할당: GPU=${GPU_DEVICES} · CPU=${CPUS} · MEM=${MEMORY}
마운트: 홈=${HOME_DIR} · weights=/weights(rw 공유) · datasets=/datasets(ro)
※ README 의 GPU 할당 대장에 이 내용을 기록할 것.
EOF
