#!/usr/bin/env bash
# 42 서버 개발자 온보딩: 계정 생성 + 개인 dev 컨테이너 발급.
#
# 사용법 (42 서버에서 admin/sudo 로 실행):
#   sudo ./provision_dev.sh <username> <pubkey-file> <gpu-devices>
#   예: sudo ./provision_dev.sh jhkwak ./keys/jhkwak.pub 0
#       sudo ./provision_dev.sh mkim ./keys/mkim.pub 2,3
#
# 하는 일:
#   1. Unix 계정 생성 (비밀번호 잠금, SSH 키 인증만)
#   2. docker 그룹 추가 (⚠️ 호스트 root 등가 — README 의 보안 절 참조)
#   3. 개발자 UID 로 이미지 빌드 (pia/dev-<user>)
#   4. GPU·리소스 제한 걸린 컨테이너 dev-<user> 실행 (홈 마운트)
set -euo pipefail

# ---- 팀 공통 설정 (필요 시 수정) ----
BASE_IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../docker" && pwd)"
DATASETS_DIR="/data/datasets"        # 공유 데이터셋 (read-only 마운트)
CPUS="16"
MEMORY="64g"
SHM_SIZE="16g"
# -------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: sudo 로 실행하세요." >&2
    exit 1
fi

if [[ $# -ne 3 ]]; then
    echo "usage: sudo $0 <username> <pubkey-file> <gpu-devices>" >&2
    echo "  ex) sudo $0 jhkwak ./keys/jhkwak.pub 0" >&2
    exit 1
fi

USERNAME="$1"
PUBKEY_FILE="$2"
GPU_DEVICES="$3"

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
        --gpus "\"device=${GPU_DEVICES}\"" \
        --cpus "$CPUS" --memory "$MEMORY" --shm-size "$SHM_SIZE" \
        --label "owner=${USERNAME}" \
        -v "$HOME_DIR":"/home/${USERNAME}" \
        "${DATASET_MOUNT[@]}" \
        -w "/home/${USERNAME}/work" \
        "$IMAGE"
    echo "[ok] 컨테이너 실행: $CONTAINER (GPU=${GPU_DEVICES})"
fi

cat <<EOF

=== 발급 완료: $USERNAME ===
접속 안내 (개발자에게 전달):
  1) ssh ${USERNAME}@<42서버주소>
  2) docker exec -it ${CONTAINER} bash
  VS Code: Remote-SSH 로 호스트 접속 후
           "Dev Containers: Attach to Running Container" → ${CONTAINER}

할당: GPU=${GPU_DEVICES} · CPU=${CPUS} · MEM=${MEMORY}
※ README 의 GPU 할당 대장에 이 내용을 기록할 것.
EOF
