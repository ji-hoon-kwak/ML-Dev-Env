#!/usr/bin/env bash
# 42 서버 플랫폼(BE/FE) 개발자 온보딩: 계정 생성 + 개인 pf 컨테이너 발급.
#   ⭐ 컨테이너 접두사 = pf-  (GPU·torch 없음, python + node). AI(ML)는 provision_ml.sh(ml-).
#
# AI 컨테이너와의 차이:
#   - GPU 미할당 (플랫폼은 모델을 직접 안 돌리고 AI 서비스를 HTTP 호출만 함)
#   - torch/CUDA 없음 · Node.js 있음 (Next.js FE)
#
# ⭐ 격리 접속 모델은 ml 과 동일: docker 그룹 미부여 · 호스트 nologin · 컨테이너 sshd 직결.
#    플랫폼은 scene/fg/trace 를 HTTP 로 '읽기 소비'하므로 공유 서비스 접근이 정당하다 →
#    그 경우 EGRESS_NETWORK=<piascope net> 로 명시 연결(읽기전용 외부 의존 예외).
#    상태를 쓰는 gateway 개발용 PG/Redis 는 컨테이너 안 devstores 로.
#
# 사용법 (42 서버에서 admin/sudo 로 실행):
#   sudo ./provision_pf.sh <username> <pubkey-file>
#   옵션(env): SSH_PORT=2211 · EGRESS_NETWORK=<piascope net>(공유 AI서비스 HTTP 소비 시)
set -euo pipefail

# ---- 팀 공통 설정 (필요 시 수정) ----
BASE_IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../docker" && pwd)"
DATASETS_DIR="/data/datasets"        # 공유 데이터셋 (read-only 마운트)
WEIGHTS_DIR="/data/weights"          # 공유 모델 weight (mlteam rw 공유)
LIBS_DIR="/data/libs"                # 공유 라이브러리 (read-only 마운트)
# ⭐ 컨테이너 sshd 호스트 키(신원)를 이미지 밖 호스트에 영속화 → 이미지 재빌드/컨테이너
#    재발급에도 키 불변(클라이언트 known_hosts 안 깨짐). 컨테이너별 하위 디렉터리에 최초 1회 발급.
HOSTKEYS_DIR="/data/42dev/hostkeys"
MLTEAM_GROUP="mlteam"                # 개발자 공용 기본 그룹 (primary group)
MLTEAM_GID="2000"                    # 고정 GID
# 공유 네트워크 기본 미연결(격리). 공유 AI서비스(scene/fg/trace) HTTP 소비가 필요할 때만
# EGRESS_NETWORK=<piascope net> 로 명시 연결(읽기전용 외부 의존 예외).
EGRESS_NETWORK="${EGRESS_NETWORK:-}"
DEVNET="${DEVNET:-devnet}"           # 격리 네트워크(egress 방화벽 · scripts/devnet_firewall.sh). bridge=격리 약화
SSH_PORT="${SSH_PORT:-}"              # 컨테이너 sshd 호스트 포트(생략 시 자동 배정)
SSH_PORT_RANGE_LOW=2200
SSH_PORT_RANGE_HIGH=2299
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

# ---- 1. 계정 생성 (기본 그룹 = mlteam · 호스트 셸 nologin) ----
# 호스트 로그인 차단 → 접속은 오직 컨테이너 sshd 로만(호스트 docker 에 손 못 댐).
if id "$USERNAME" &>/dev/null; then
    echo "[skip] 계정 $USERNAME 이미 존재"
    usermod -g "$MLTEAM_GROUP" -s /usr/sbin/nologin "$USERNAME"
else
    useradd -m -g "$MLTEAM_GROUP" -s /usr/sbin/nologin "$USERNAME"
    passwd -l "$USERNAME"
    echo "[ok] 계정 생성: $USERNAME (기본 그룹=$MLTEAM_GROUP · 호스트 nologin)"
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

# ---- 2. docker 그룹 '제거' (호스트 daemon 오염 경로 차단) ----
gpasswd -d "$USERNAME" docker 2>/dev/null && echo "[ok] docker 그룹에서 제거" || echo "[ok] docker 그룹 비소속(정상)"

# ---- 공유 디렉터리 정렬 ----
mkdir -p "$WEIGHTS_DIR" "$LIBS_DIR"
chgrp "$MLTEAM_GROUP" "$WEIGHTS_DIR" "$LIBS_DIR"
chmod 2775 "$WEIGHTS_DIR" "$LIBS_DIR"
echo "[ok] 공유 디렉터리 정렬: $WEIGHTS_DIR, $LIBS_DIR (그룹=$MLTEAM_GROUP)"

# ---- 3. base 이미지 보장 + 개인 이미지 빌드 ----
if ! docker image inspect pia/pf-base &>/dev/null; then
    echo "[..] pia/pf-base 없음 — 최초 1회 빌드"
    "$(dirname "${BASH_SOURCE[0]}")/build_pf_base.sh"
fi

IMAGE="pia/pf-${USERNAME}"
docker build -t "$IMAGE" \
    --build-arg USERNAME="$USERNAME" \
    --build-arg UID="$DEV_UID" \
    -f "$BASE_IMAGE_DIR/Dockerfile.pf" \
    "$BASE_IMAGE_DIR"
echo "[ok] 이미지 빌드: $IMAGE (FROM pia/pf-base · GPU/torch 없음)"

# ---- 4. 컨테이너 실행 (GPU 없음) ----
CONTAINER="pf-${USERNAME}"
KEYDIR="$HOSTKEYS_DIR/$CONTAINER"   # 컨테이너 sshd 호스트 키(신원) 영속 저장 — 재빌드/재발급 불변
if docker inspect "$CONTAINER" &>/dev/null; then
    echo "[skip] 컨테이너 $CONTAINER 이미 존재 — 재발급하려면 먼저:" >&2
    echo "       docker rm -f $CONTAINER" >&2
else
    install -d -o "$USERNAME" -g "$MLTEAM_GROUP" "$HOME_DIR/work"

    # ---- 컨테이너 sshd 호스트 포트 배정 ----
    if [[ -z "$SSH_PORT" ]]; then
        USED_PORTS="$(docker ps -q | xargs -r docker inspect \
            --format '{{range $p,$c := .NetworkSettings.Ports}}{{range $c}}{{.HostPort}} {{end}}{{end}}' 2>/dev/null || true)"
        for p in $(seq "$SSH_PORT_RANGE_LOW" "$SSH_PORT_RANGE_HIGH"); do
            if ! grep -qw "$p" <<<"$USED_PORTS" && ! ss -ltn 2>/dev/null | grep -q ":$p "; then
                SSH_PORT="$p"; break
            fi
        done
    fi
    if [[ -z "$SSH_PORT" ]]; then
        echo "ERROR: 빈 SSH 포트를 못 찾음(${SSH_PORT_RANGE_LOW}-${SSH_PORT_RANGE_HIGH}). SSH_PORT=<port> 로 지정." >&2
        exit 1
    fi

    # ---- 격리 네트워크 보장 ----
    if [[ "$DEVNET" != "bridge" ]] && ! docker network inspect "$DEVNET" &>/dev/null; then
        echo "[warn] '$DEVNET' 네트워크가 없습니다 — 먼저: sudo ./scripts/devnet_firewall.sh up" >&2
        echo "       (격리 약화 상태로 강행하려면 DEVNET=bridge 로 재실행)" >&2
        exit 1
    fi

    DATASET_MOUNT=()
    [[ -d "$DATASETS_DIR" ]] && DATASET_MOUNT=(-v "$DATASETS_DIR":/datasets:ro)

    # ---- 컨테이너 sshd 호스트 키: 최초 1회 발급 후 영구 고정 ----
    # 키를 이미지가 아니라 호스트($KEYDIR)에 두므로 이미지 재빌드·컨테이너 재발급에도
    # 신원(호스트 키)이 그대로다. 예전 base 이미지의 `ssh-keygen -A` 는 재빌드마다 새 키를
    # 굽어 클라이언트 known_hosts 를 깼다(REMOTE HOST IDENTIFICATION HAS CHANGED).
    if [[ ! -f "$KEYDIR/ssh_host_ed25519_key" ]]; then
        install -d -m 700 "$KEYDIR"
        ssh-keygen -q -t ed25519 -f "$KEYDIR/ssh_host_ed25519_key" -N '' -C "$CONTAINER"
        ssh-keygen -q -t rsa -b 4096 -f "$KEYDIR/ssh_host_rsa_key" -N '' -C "$CONTAINER"
        ssh-keygen -q -t ecdsa -b 521 -f "$KEYDIR/ssh_host_ecdsa_key" -N '' -C "$CONTAINER"
        chmod 600 "$KEYDIR"/ssh_host_*_key
        chmod 644 "$KEYDIR"/ssh_host_*_key.pub
        echo "[ok] 컨테이너 호스트 키 발급(최초 1회): $KEYDIR"
    else
        echo "[keep] 기존 호스트 키 재사용(불변): $KEYDIR"
    fi

    docker run -d --name "$CONTAINER" \
        --restart unless-stopped \
        --cpus "$CPUS" --memory "$MEMORY" \
        --group-add "$MLTEAM_GID" \
        --label "owner=${USERNAME}" \
        --label "role=platform" \
        --network "$DEVNET" \
        -p "${SSH_PORT}:22" \
        -v "$KEYDIR":/etc/ssh/keys:ro \
        -v "$HOME_DIR":"/home/${USERNAME}" \
        -v "$WEIGHTS_DIR":/weights \
        -v "$LIBS_DIR":/libs:ro \
        "${DATASET_MOUNT[@]}" \
        -w "/home/${USERNAME}/work" \
        "$IMAGE"
    echo "[ok] 컨테이너 실행: $CONTAINER (GPU 없음 · CPU=${CPUS} · MEM=${MEMORY} · sshd 포트=${SSH_PORT})"
fi

# ---- 4-bis. (선택) 공유 AI서비스 HTTP 소비용 egress — 기본은 '연결 안 함'(격리) ----
# 플랫폼은 scene/fg/trace 를 HTTP 로 '읽기 소비'하므로 이 연결이 정당한 경우가 많다.
# 필요하면 EGRESS_NETWORK 로 명시 연결(서비스명 DNS + .env.dev URL 재사용).
# ⚠️ gateway 개발용으로 상태를 쓰는 PG/Redis 는 공유 대신 컨테이너 안 devstores 로.
if [[ -n "$EGRESS_NETWORK" ]]; then
    if docker network inspect "$EGRESS_NETWORK" &>/dev/null; then
        docker network connect "$EGRESS_NETWORK" "$CONTAINER" 2>/dev/null || true
        echo "[ok] egress 네트워크 연결(공유 AI서비스 HTTP 소비): $EGRESS_NETWORK"
    else
        echo "[warn] EGRESS_NETWORK=$EGRESS_NETWORK 없음 — 연결 생략"
    fi
else
    echo "[ok] 공유 네트워크 미연결(격리). 필요 시 EGRESS_NETWORK=<net> 로 재발급."
fi

# ---- 5. venv PATH snippet (호스트 ~/.bashrc — 컨테이너 안에서만 발동) ----
# pf 는 conda 없음 — 이미지가 /opt/venv 에 python+node 를 두고 ENV PATH 로 노출한다.
# login 셸(bash -l)이 PATH 를 재설정하는 경우 대비해 홈 ~/.bashrc 에도 guarded 추가.
SNIPPET_MARK="# >>> 42-dev-env venv >>>"
if ! grep -qF "$SNIPPET_MARK" "$HOME_DIR/.bashrc" 2>/dev/null; then
    cat >> "$HOME_DIR/.bashrc" <<'EOF'

# >>> 42-dev-env venv >>>
# 컨테이너 안(/opt/venv 존재)에서만 venv 를 PATH 앞에 (python/uvicorn/node)
if [ -d /opt/venv/bin ]; then
    export PATH=/opt/venv/bin:$PATH
fi
# <<< 42-dev-env venv <<<
EOF
    chown "$USERNAME:$MLTEAM_GROUP" "$HOME_DIR/.bashrc"
    echo "[ok] ~/.bashrc 에 venv PATH snippet 추가"
fi

HOSTKEY_FP="(발급 정보 없음)"
[[ -f "$KEYDIR/ssh_host_ed25519_key.pub" ]] && HOSTKEY_FP="$(ssh-keygen -lf "$KEYDIR/ssh_host_ed25519_key.pub")"

cat <<EOF

=== 플랫폼 발급 완료: $USERNAME ===
호스트 키 지문 (개발자에게 전달 — 첫 접속 시 known_hosts 대조용, 재발급해도 불변):
  ${HOSTKEY_FP}
접속 안내 (개발자에게 전달) — ⭐ 호스트가 아니라 '컨테이너'로 직접 접속:
  ssh -p ${SSH_PORT} ${USERNAME}@<42서버주소>     # 바로 컨테이너 안 셸(/opt/venv: python+node)
  VS Code: Remote-SSH 로 <42서버주소>:${SSH_PORT} 를 '원격 호스트'로 추가해 접속
  (호스트 docker·docker exec 불필요 — 호스트 로그인은 막혀 있음)

구성: GPU 없음 · CPU=${CPUS} · MEM=${MEMORY} · 기본그룹=${MLTEAM_GROUP} · sshd포트=${SSH_PORT} · net=${DEVNET}(사설망·호스트 차단) · egress=${EGRESS_NETWORK:-(없음)}
마운트: 홈=${HOME_DIR} · weights=/weights(rw) · libs=/libs(ro) · datasets=/datasets(ro)

개발 흐름 (컨테이너 안):
  git clone <repo>; cd TRACE_SSAVE-AI-MVP
  pip install -e .                                   # light (torch 없음) — gateway
  uvicorn gateway.api.main:app --host 0.0.0.0 --port 3105 --reload
  cd ui/apps/scope && npm install && npm run dev -- --port 3405
  # gateway 개발용 PG/Redis 는 컨테이너 안에서:  devstores up  (127.0.0.1:5432 / :6379)
  # 공유 AI서비스(scene/fg/trace) 를 HTTP 로 소비하려면 EGRESS_NETWORK 로 재발급 후
  #   서비스명 DNS + 배포 .env.dev 의 SSAVE_*_URL·TRACE_API_URL·INTERNAL_SERVICE_SECRET 재사용.
EOF
