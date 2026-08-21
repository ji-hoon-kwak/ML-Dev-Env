#!/usr/bin/env bash
# 42 서버 플랫폼(BE/FE) 개발자 온보딩: 계정 생성 + 개인 pf 컨테이너 발급.
#   ⭐ 컨테이너 접두사 = pf-  (GPU·torch 없음, python + node). AI(ML)는 provision_dev.sh(ml-).
#
# AI 컨테이너와의 차이:
#   - GPU 미할당 (플랫폼은 모델을 직접 안 돌리고 AI 서비스를 HTTP 호출만 함)
#   - torch/CUDA 없음 · Node.js 있음 (Next.js FE)
#   - piascope 서비스 네트워크에 자동 연결 → gateway/FE 가 postgres/redis/milvus/
#     ssave-scene/ssave-fg/trace-api 를 서비스명으로 접근(배포 .env.dev 재사용 가능)
#
# 사용법 (42 서버에서 admin/sudo 로 실행):
#   sudo ./provision_platform.sh <username> <pubkey-file>
set -euo pipefail

# ---- 팀 공통 설정 (필요 시 수정) ----
BASE_IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../docker" && pwd)"
DATASETS_DIR="/data/datasets"        # 공유 데이터셋 (read-only 마운트)
WEIGHTS_DIR="/data/weights"          # 공유 모델 weight (mlteam rw 공유)
LIBS_DIR="/data/libs"                # 공유 라이브러리 (read-only 마운트)
MLTEAM_GROUP="mlteam"                # 개발자 공용 기본 그룹 (primary group)
MLTEAM_GID="2000"                    # 고정 GID
# 플랫폼 서비스가 붙을 piascope compose 네트워크. 비워두면 자동 감지(실행 중 gateway 기준).
SERVICE_NETWORK="${SERVICE_NETWORK:-}"
CPUS="8"                             # 플랫폼은 학습 안 하니 AI(16)보다 가볍게
MEMORY="32g"
# -------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: sudo 로 실행하세요." >&2
    exit 1
fi

if [[ $# -ne 2 ]]; then
    echo "usage: sudo $0 <username> <pubkey-file>" >&2
    echo "  (플랫폼 컨테이너는 GPU 미할당 — gpu 인자 없음)" >&2
    exit 1
fi

USERNAME="$1"
PUBKEY_FILE="$2"

if [[ ! -f "$PUBKEY_FILE" ]]; then
    echo "ERROR: 공개키 파일이 없습니다: $PUBKEY_FILE" >&2
    exit 1
fi
if ! ssh-keygen -l -f "$PUBKEY_FILE" >/dev/null 2>&1; then
    echo "ERROR: 유효한 SSH 공개키가 아닙니다: $PUBKEY_FILE" >&2
    exit 1
fi

# ---- 0. mlteam 공용 그룹 보장 ----
if ! getent group "$MLTEAM_GROUP" >/dev/null; then
    groupadd -g "$MLTEAM_GID" "$MLTEAM_GROUP"
    echo "[ok] 그룹 생성: $MLTEAM_GROUP (gid=$MLTEAM_GID)"
else
    MLTEAM_GID="$(getent group "$MLTEAM_GROUP" | cut -d: -f3)"
fi

# ---- 1. 계정 생성 (기본 그룹 = mlteam) ----
if id "$USERNAME" &>/dev/null; then
    echo "[skip] 계정 $USERNAME 이미 존재"
    usermod -g "$MLTEAM_GROUP" "$USERNAME"
else
    useradd -m -g "$MLTEAM_GROUP" -s /bin/bash "$USERNAME"
    passwd -l "$USERNAME"
    echo "[ok] 계정 생성: $USERNAME (기본 그룹=$MLTEAM_GROUP)"
fi

HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
DEV_UID="$(id -u "$USERNAME")"

chgrp "$MLTEAM_GROUP" "$HOME_DIR"
chmod g+s "$HOME_DIR"

# ---- SSH 키 등록 ----
install -d -m 700 -o "$USERNAME" -g "$MLTEAM_GROUP" "$HOME_DIR/.ssh"
touch "$HOME_DIR/.ssh/authorized_keys"
if ! grep -qF "$(cat "$PUBKEY_FILE")" "$HOME_DIR/.ssh/authorized_keys"; then
    cat "$PUBKEY_FILE" >> "$HOME_DIR/.ssh/authorized_keys"
fi
chown "$USERNAME:$MLTEAM_GROUP" "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
echo "[ok] SSH 공개키 등록"

# ---- 2. docker 그룹 ----
usermod -aG docker "$USERNAME"
echo "[ok] docker 그룹 추가 (주의: 호스트 root 등가 권한)"

# ---- 공유 디렉터리 정렬 ----
mkdir -p "$WEIGHTS_DIR" "$LIBS_DIR"
chgrp "$MLTEAM_GROUP" "$WEIGHTS_DIR" "$LIBS_DIR"
chmod 2775 "$WEIGHTS_DIR" "$LIBS_DIR"
echo "[ok] 공유 디렉터리 정렬: $WEIGHTS_DIR, $LIBS_DIR (그룹=$MLTEAM_GROUP)"

# ---- 3. base 이미지 보장 + 개인 이미지 빌드 ----
if ! docker image inspect pia/pf-base &>/dev/null; then
    echo "[..] pia/pf-base 없음 — 최초 1회 빌드"
    "$(dirname "${BASH_SOURCE[0]}")/build_platform_base.sh"
fi

IMAGE="pia/pf-${USERNAME}"
docker build -t "$IMAGE" \
    --build-arg USERNAME="$USERNAME" \
    --build-arg UID="$DEV_UID" \
    -f "$BASE_IMAGE_DIR/Dockerfile.platform" \
    "$BASE_IMAGE_DIR"
echo "[ok] 이미지 빌드: $IMAGE (FROM pia/pf-base · GPU/torch 없음)"

# ---- 4. 컨테이너 실행 (GPU 없음) ----
CONTAINER="pf-${USERNAME}"
if docker inspect "$CONTAINER" &>/dev/null; then
    echo "[skip] 컨테이너 $CONTAINER 이미 존재 — 재발급하려면 먼저:" >&2
    echo "       docker rm -f $CONTAINER" >&2
else
    install -d -o "$USERNAME" -g "$MLTEAM_GROUP" "$HOME_DIR/work"
    DATASET_MOUNT=()
    [[ -d "$DATASETS_DIR" ]] && DATASET_MOUNT=(-v "$DATASETS_DIR":/datasets:ro)

    docker run -d --name "$CONTAINER" \
        --restart unless-stopped \
        --cpus "$CPUS" --memory "$MEMORY" \
        --group-add "$MLTEAM_GID" \
        --label "owner=${USERNAME}" \
        --label "role=platform" \
        -v "$HOME_DIR":"/home/${USERNAME}" \
        -v "$WEIGHTS_DIR":/weights \
        -v "$LIBS_DIR":/libs:ro \
        "${DATASET_MOUNT[@]}" \
        -w "/home/${USERNAME}/work" \
        "$IMAGE"
    echo "[ok] 컨테이너 실행: $CONTAINER (GPU 없음 · CPU=${CPUS} · MEM=${MEMORY})"
fi

# ---- 4-bis. piascope 서비스 네트워크에 연결 ----
# gateway/FE 가 postgres·redis·milvus·ssave-scene·ssave-fg·trace-api 를 '서비스명'으로
# 접근하려면 같은 docker 네트워크에 있어야 한다(배포 .env.dev 를 그대로 재사용 가능).
if [[ -z "$SERVICE_NETWORK" ]]; then
    # 실행 중인 piascope-gateway 가 붙어 있는 네트워크를 자동 감지
    SERVICE_NETWORK="$(docker inspect piascope-gateway \
        --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null \
        | grep -v '^$' | head -1 || true)"
fi
if [[ -n "$SERVICE_NETWORK" ]] && docker network inspect "$SERVICE_NETWORK" &>/dev/null; then
    if ! docker inspect "$CONTAINER" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' | grep -qw "$SERVICE_NETWORK"; then
        docker network connect "$SERVICE_NETWORK" "$CONTAINER"
    fi
    echo "[ok] 서비스 네트워크 연결: $SERVICE_NETWORK (서비스명 DNS 사용 가능)"
else
    echo "[warn] 서비스 네트워크를 못 찾음 — 호스트 IP+공개포트로 접근하거나"
    echo "       SERVICE_NETWORK=<네트워크명> sudo -E $0 ... 로 재실행"
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
    chown "$USERNAME:$MLTEAM_GROUP" "$HOME_DIR/.bashrc"
    echo "[ok] ~/.bashrc 에 conda 활성화 snippet 추가"
fi

cat <<EOF

=== 플랫폼 발급 완료: $USERNAME ===
접속 안내 (개발자에게 전달):
  1) ssh ${USERNAME}@<42서버주소>
  2) docker exec -it ${CONTAINER} bash    # conda dev env 자동 활성화 (python + node)
  VS Code: Remote-SSH 접속 후 "Attach to Running Container" → ${CONTAINER}

구성: GPU 없음 · CPU=${CPUS} · MEM=${MEMORY} · 기본그룹=${MLTEAM_GROUP} · 네트워크=${SERVICE_NETWORK:-(수동)}
마운트: 홈=${HOME_DIR} · weights=/weights(rw) · libs=/libs(ro) · datasets=/datasets(ro)

개발 흐름 (컨테이너 안):
  git clone <repo>; cd TRACE_SSAVE-AI-MVP
  pip install -e .                                   # light (torch 없음) — gateway
  uvicorn gateway.api.main:app --host 0.0.0.0 --port 3105 --reload
  cd ui/apps/scope && npm install && npm run dev -- --port 3405
  # 인프라는 공유 스택에 붙는다: 서비스명(postgres/redis/milvus/piascope-ssave-scene…)
  #   또는 호스트 10.128.30.42 + 공개포트. INTERNAL_SERVICE_SECRET·SSAVE_*_URL·
  #   TRACE_API_URL 은 배포 .env.dev 값 재사용. 포트는 3100/3401/8001 과 겹치지 않게.
  # ⚠️ M3 검증(8/19~28) 기간엔 공유 PG/Milvus 에 '쓰기' 금지 — 개인 저장소로 격리.
EOF
