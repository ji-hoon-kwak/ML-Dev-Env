#!/usr/bin/env bash
# 42 서버 AI(ML) 개발자 온보딩: 계정 생성 + 개인 ml 컨테이너 발급.
#   ⭐ 컨테이너 접두사 = ml-  (GPU·torch 있는 AI 개발용). 플랫폼(BE/FE)은 provision_pf.sh(pf-).
#
# 사용법 (42 서버에서 admin/sudo 로 실행):
#   sudo ./provision_ml.sh <username> <pubkey-file> [gpu-devices]
#   예: sudo ./provision_ml.sh dhkim keys/dhkim.pub          # GPU 전체 공유 (기본)
#       sudo ./provision_ml.sh dhkim keys/dhkim.pub 2,3      # 특정 GPU 만
#   옵션(env): SSH_PORT=2205 (컨테이너 sshd 호스트 포트 고정 · 생략 시 2200~2299 자동)
#             EGRESS_NETWORK=<net> (읽기전용 공유 의존이 필요할 때만 명시 연결 · 기본 없음)
#
# 하는 일 (⭐ 격리 접속 모델 — 검토 결론 반영):
#   1. Unix 계정 생성 (호스트 셸 nologin · SSH 키 인증만)
#   2. ❌ docker 그룹 '추가하지 않음' (있으면 제거) — 호스트 daemon 오염 경로 차단
#   3. 개발자 UID 로 이미지 빌드 (pia/ml-<user>, base=pia/ml-base · sshd 내장)
#   4. GPU·리소스 제한 컨테이너 ml-<user> 실행 + 컨테이너 sshd 를 호스트 포트로 노출
#      (홈 + weights + datasets 마운트 · 공유 네트워크엔 기본 미연결)
#   5. 개발자는 'ssh -p <port> <user>@42' 로 컨테이너에 '직접' 접속 (호스트 docker 불필요)
#   6. 테스트 인프라(PG/Redis)는 컨테이너 안에서 `devstores up` — 공유 인프라 안 씀
set -euo pipefail

# ---- 팀 공통 설정 (필요 시 수정) ----
BASE_IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../docker" && pwd)"
DATASETS_DIR="/data/datasets"        # 공유 데이터셋 (read-only 마운트)
WEIGHTS_DIR="/data/weights"          # 공유 모델 weight (mlteam rw 공유)
FACE_LICENSE_SRC="/data/libs/qfe_home/data.conf"                     # Suprema 활성화 단일 원본(mlteam 공유). gpuadmin 이 share_license.sh export 로 여기에 심는다. gpuadmin 홈(0750)에 직접 물리면 권한·재활성화에 취약하므로 공유 경로를 단일 원천으로 둔다.
FACE_LICENSE_REL=".local/share/data/bconf/data.conf"                 # 컨테이너 $HOME 기준 — SDK가 읽는 위치
# ⭐ 얼굴 SDK 소비자(trace-worker·dev 파이프라인)는 라이선스 파일이 아니라 QFE HTTP wrapper URL 만
#    필요하다 (ADR-023 · identity.yaml: endpoint=${SUPREMA_ENDPOINT}). QFE 는 노드락이라 컨테이너 안
#    직접 초기화가 안 되고, 42 로컬 호스트에서 qfe_http_server 를 하나 띄운 뒤 그 주소를 여기 넣으면
#    모든 dev 컨테이너가 같은 라이선스를 HTTP 로 공유한다. 42 서버 기본값을 여기 박아둔다 —
#    이 스크립트는 42 전용 프로비저너라 원칙4(URL 하드코딩 금지)의 실무 예외로 둔다(top-of-file 상수).
#    필요 시 `SUPREMA_ENDPOINT_URL=... sudo -E ./provision_ml.sh ...` 로 오버라이드, 빈 문자열이면
#    주입 생략(identity off — 추적은 계속). 아래 docker run 이 --add-host 로 host.docker.internal 매핑.
#    배경·실행순서 = docs/suprema-license-sharing.md §실행계획.
SUPREMA_ENDPOINT_URL="${SUPREMA_ENDPOINT_URL:-http://host.docker.internal:18080}"
LIBS_DIR="/data/libs"                # 공유 AI 라이브러리 (QFE 등 · read-only 마운트, admin 관리)
MLTEAM_GROUP="mlteam"                # 개발자 공용 기본 그룹 (primary group)
MLTEAM_GID="2000"                    # 고정 GID — 호스트·컨테이너·bind-mount 가 같은 번호를 공유
# ⭐ 공유 네트워크엔 기본적으로 연결하지 않는다 (격리). 읽기전용 공유 의존(예: 공유
#    Milvus 조회)이 실제로 필요할 때만 admin 이 EGRESS_NETWORK=<piascope net> 로 명시 연결.
#    ⚠️ 이 연결은 '읽기전용을 기계로 강제'하지 못한다 — 상태를 쓰는 의존(Redis/PG)은
#       공유로 가지 말고 컨테이너 안 devstores 로 띄운다(docs/shared-infra-rules.md).
EGRESS_NETWORK="${EGRESS_NETWORK:-}"
# ⭐ 개발 컨테이너 기본 네트워크 = devnet (egress 방화벽 대상 · scripts/devnet_firewall.sh).
#    사설망·호스트 차단 + 인터넷 허용. 방화벽 없이 만들려면 DEVNET=bridge 로 지정(격리 약화).
DEVNET="${DEVNET:-devnet}"
# 컨테이너 sshd 를 노출할 호스트 포트(생략 시 아래 범위에서 자동 배정)
SSH_PORT="${SSH_PORT:-}"
SSH_PORT_RANGE_LOW=2200
SSH_PORT_RANGE_HIGH=2299
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

# ---- 0. mlteam 공용 그룹 보장 (없으면 고정 GID 로 생성) ----
if ! getent group "$MLTEAM_GROUP" >/dev/null; then
    groupadd -g "$MLTEAM_GID" "$MLTEAM_GROUP"
    echo "[ok] 그룹 생성: $MLTEAM_GROUP (gid=$MLTEAM_GID)"
else
    MLTEAM_GID="$(getent group "$MLTEAM_GROUP" | cut -d: -f3)"   # 이미 있으면 그 GID 사용
fi

# ---- 1. 계정 생성 (기본 그룹 = mlteam · 호스트 셸 nologin) ----
# ⭐ 호스트 셸 = /usr/sbin/nologin: 개발자는 호스트에 로그인하지 못한다. 접속은 오직
#    컨테이너 sshd(아래 노출 포트)로만 → 호스트 docker/데몬에 손댈 방법이 없다.
#    (authorized_keys 는 홈에 있어 컨테이너 sshd 가 읽지만, 호스트 sshd 는 nologin 으로 거절)
if id "$USERNAME" &>/dev/null; then
    echo "[skip] 계정 $USERNAME 이미 존재"
    usermod -g "$MLTEAM_GROUP" -s /usr/sbin/nologin "$USERNAME"   # mlteam + 호스트 nologin(멱등)
else
    useradd -m -g "$MLTEAM_GROUP" -s /usr/sbin/nologin "$USERNAME"
    passwd -l "$USERNAME"   # 비밀번호 로그인 차단 (키 인증만)
    echo "[ok] 계정 생성: $USERNAME (기본 그룹=$MLTEAM_GROUP · 호스트 nologin)"
fi

HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
DEV_UID="$(id -u "$USERNAME")"
DEV_GID="$(id -g "$USERNAME")"   # = mlteam GID (기본 그룹이 mlteam 이므로)

# 홈(=워크스페이스) 그룹을 mlteam 으로 + setgid: 이후 생성 파일이 mlteam 그룹을 상속
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
# 예전엔 여기서 docker 그룹을 '추가'했다 — 그게 개발자를 호스트 root 등가로 만들어
# piascope-jordan-* 같은 호스트 레벨 병렬 스택을 띄울 수 있게 한 근본 원인이었다.
# 이제는 오히려 제거한다(멱등). 개발자는 컨테이너 안 sudo 로만 권한을 갖는다.
gpasswd -d "$USERNAME" docker 2>/dev/null && echo "[ok] docker 그룹에서 제거" || echo "[ok] docker 그룹 비소속(정상)"

# ---- 공유 weights 디렉터리 (mlteam rw 공유) ----
mkdir -p "$WEIGHTS_DIR"
chgrp "$MLTEAM_GROUP" "$WEIGHTS_DIR"
chmod 2775 "$WEIGHTS_DIR"    # rwxrwsr-x — mlteam rw + setgid(새 파일도 mlteam 소유)
echo "[ok] 공유 weights 디렉터리 정렬: $WEIGHTS_DIR (그룹=$MLTEAM_GROUP)"

# ---- Suprema 얼굴 SDK 라이선스: mlteam 읽기 허용 (모든 dev 컨테이너 공통) ----
if [[ -f "$FACE_LICENSE_SRC" ]]; then
    chgrp "$MLTEAM_GROUP" "$FACE_LICENSE_SRC" 2>/dev/null || true
    chmod g+r "$FACE_LICENSE_SRC"     # 그룹 읽기만(world-read 금지 — 라이선스 키 보호)
    echo "[ok] Suprema 라이선스 mlteam 읽기 허용: $FACE_LICENSE_SRC"
else
    echo "[warn] Suprema 라이선스 없음: $FACE_LICENSE_SRC — 얼굴 SDK 마운트 생략"
fi

# ---- 공유 라이브러리 디렉터리 (admin 관리 · 컨테이너엔 read-only 마운트) ----
mkdir -p "$LIBS_DIR"
chgrp "$MLTEAM_GROUP" "$LIBS_DIR"
chmod 2775 "$LIBS_DIR"       # 호스트: admin/mlteam 이 관리. 컨테이너: :ro 로 읽기 전용
echo "[ok] 공유 라이브러리 디렉터리 정렬: $LIBS_DIR (그룹=$MLTEAM_GROUP)"

# ---- 3. base 이미지 보장 + 개인 이미지 빌드 ----
# pia/ml-base(무거운 conda)가 없으면 최초 1회 빌드. 이후 개발자별 이미지는
# 그 위에 useradd 한 줄만 얹으므로 ~1초에 끝난다(build cache 유무와 무관).
if ! docker image inspect pia/ml-base &>/dev/null; then
    echo "[..] pia/ml-base 없음 — 최초 1회 빌드"
    "$(dirname "${BASH_SOURCE[0]}")/build_ml_base.sh"
fi

IMAGE="pia/ml-${USERNAME}"
docker build -t "$IMAGE" \
    --build-arg USERNAME="$USERNAME" \
    --build-arg UID="$DEV_UID" \
    -f "$BASE_IMAGE_DIR/Dockerfile.ml" \
    "$BASE_IMAGE_DIR"
echo "[ok] 이미지 빌드: $IMAGE (FROM pia/ml-base)"

# ---- 4. 컨테이너 실행 ----
CONTAINER="ml-${USERNAME}"
if [[ "$GPU_DEVICES" == "all" ]]; then
    GPU_FLAG=(--gpus all)
else
    GPU_FLAG=(--gpus "\"device=${GPU_DEVICES}\"")
fi

if docker inspect "$CONTAINER" &>/dev/null; then
    echo "[skip] 컨테이너 $CONTAINER 이미 존재 — 재발급하려면 먼저:" >&2
    echo "       docker rm -f $CONTAINER" >&2
else
    install -d -o "$USERNAME" -g "$MLTEAM_GROUP" "$HOME_DIR/work"

    # ---- 컨테이너 sshd 호스트 포트 배정 (직결 접속용) ----
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
        echo "[warn] '$DEVNET' 네트워크가 없습니다 — 먼저 egress 방화벽을 세우세요:" >&2
        echo "         sudo ./scripts/devnet_firewall.sh up" >&2
        echo "       (방화벽 없이 격리 약화 상태로 강행하려면 DEVNET=bridge 로 재실행)" >&2
        exit 1
    fi
    # 방화벽 규칙 존재 여부 경고(네트워크만 있고 iptables 미설치면 egress 안 막힘)
    if [[ "$DEVNET" != "bridge" ]] && ! iptables -S DOCKER-USER 2>/dev/null | grep -q "172.31"; then
        echo "[warn] devnet iptables 규칙이 안 보입니다 — 'devnet_firewall.sh up' 로 egress 차단 확인 권장." >&2
    fi

    DATASET_MOUNT=()
    if [[ -d "$DATASETS_DIR" ]]; then
        DATASET_MOUNT=(-v "$DATASETS_DIR":/datasets:ro)
    else
        echo "[warn] $DATASETS_DIR 없음 — 데이터셋 마운트 생략"
    fi

    # ---- Suprema 얼굴 SDK 라이선스: 활성화 원본을 컨테이너 $HOME 경로에 read-only 마운트 ----
    # SDK 는 실행 사용자의 $HOME/.local/share/data/bconf/data.conf 를 읽는다. 컨테이너 홈은
    # 호스트 홈 bind 이므로, 그 아래에 nested single-file bind 로 활성화 원본을 얹는다.
    # (모든 dev 가 gpuadmin 의 단일 원본을 :ro 로 공유 — 복사 없음.) target 부모 dir 을
    # 호스트 홈에 먼저 만들어 둔다(없으면 nested 마운트 실패).
    install -d -o "$USERNAME" -g "$MLTEAM_GROUP" "$HOME_DIR/$(dirname "$FACE_LICENSE_REL")"
    FACE_LICENSE_MOUNT=()
    if [[ -f "$FACE_LICENSE_SRC" ]]; then
        # ⚠️ HTTP 소비자엔 불필요(위 SUPREMA_ENDPOINT_URL 참조). qfe_http_server(C) 자체를
        #    빌드/디버그하는 얼굴팀 개발용으로만 의미 — 그마저 노드락은 별도.
        FACE_LICENSE_MOUNT=(-v "$FACE_LICENSE_SRC":"/home/${USERNAME}/${FACE_LICENSE_REL}":ro)
    else
        echo "[info] $FACE_LICENSE_SRC 없음 — 얼굴 SDK 라이선스 마운트 생략(HTTP 소비자엔 무관)"
    fi

    # 얼굴 identity 소비자용 엔드포인트 주입 — 정석 경로(ADR-023). 라이선스 파일 마운트보다 이게 우선.
    FACE_ENDPOINT_ENV=()
    if [[ -n "$SUPREMA_ENDPOINT_URL" ]]; then
        # --add-host: host.docker.internal 을 호스트 게이트웨이로 매핑 → 호스트에서 도는 wrapper 에
        # default-bridge 컨테이너가 도달(compose 네트워크의 trace-worker 와 동일한 접근 방식).
        FACE_ENDPOINT_ENV=(--add-host "host.docker.internal:host-gateway" -e "SUPREMA_ENDPOINT=${SUPREMA_ENDPOINT_URL}")
        echo "[ok] SUPREMA_ENDPOINT 주입: $SUPREMA_ENDPOINT_URL (host.docker.internal 매핑)"
    else
        echo "[info] SUPREMA_ENDPOINT_URL 미설정 — 엔드포인트 주입 생략(얼굴 identity off · 추적엔 무관)"
    fi

    docker run -d --name "$CONTAINER" \
        --restart unless-stopped \
        "${GPU_FLAG[@]}" \
        --cpus "$CPUS" --memory "$MEMORY" --shm-size "$SHM_SIZE" \
        --group-add "$MLTEAM_GID" \
        --label "owner=${USERNAME}" \
        --label "role=ml" \
        --network "$DEVNET" \
        -p "${SSH_PORT}:22" \
        -v "$HOME_DIR":"/home/${USERNAME}" \
        -v "$WEIGHTS_DIR":/weights \
        -v "$LIBS_DIR":/libs:ro \
        "${DATASET_MOUNT[@]}" \
        "${FACE_LICENSE_MOUNT[@]}" \
        "${FACE_ENDPOINT_ENV[@]}" \
        -w "/home/${USERNAME}/work" \
        "$IMAGE"
    echo "[ok] 컨테이너 실행: $CONTAINER (GPU=${GPU_DEVICES} · sshd 포트=${SSH_PORT})"
fi

# ---- 4-bis. (선택) 읽기전용 공유 의존 egress — 기본은 '연결 안 함'(격리) ----
# 예전엔 여기서 piascope 서비스 네트워크에 '자동 연결'했다 → 공유 PG/Redis/Milvus 에
# 쓰기 도달이 열렸고, 오직 산문 규칙만이 오염을 막았다. 이제는 기본 미연결.
# 공유 Milvus 조회 등 '읽기전용' 의존이 실제 필요할 때만 EGRESS_NETWORK 로 명시 연결한다.
# ⚠️ 상태를 쓰는 의존(Redis Streams·PG)은 여기로 가지 말고 컨테이너 안 devstores 로.
if [[ -n "$EGRESS_NETWORK" ]]; then
    if docker network inspect "$EGRESS_NETWORK" &>/dev/null; then
        docker network connect "$EGRESS_NETWORK" "$CONTAINER" 2>/dev/null || true
        echo "[ok] egress 네트워크 연결(읽기전용 용도): $EGRESS_NETWORK"
    else
        echo "[warn] EGRESS_NETWORK=$EGRESS_NETWORK 없음 — 연결 생략"
    fi
else
    echo "[ok] 공유 네트워크 미연결(격리). 테스트 인프라는 컨테이너 안 'devstores up' 사용."
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

=== 발급 완료: $USERNAME ===
접속 안내 (개발자에게 전달) — ⭐ 호스트가 아니라 '컨테이너'로 직접 접속:
  ssh -p ${SSH_PORT} ${USERNAME}@<42서버주소>     # 바로 컨테이너 안 셸(conda dev)
  VS Code: Remote-SSH 로 <42서버주소>:${SSH_PORT} 를 '원격 호스트'로 추가해 접속
  (호스트 docker 접근·docker exec 불필요 — 호스트엔 로그인 자체가 막혀 있음)

테스트 인프라(개인 PG/Redis)는 컨테이너 안에서:
  devstores up      # 127.0.0.1:6379(redis) · 127.0.0.1:5432(pg, db=dev) — 공유 인프라 안 씀

할당: GPU=${GPU_DEVICES} · CPU=${CPUS} · MEM=${MEMORY} · 기본그룹=${MLTEAM_GROUP} · sshd포트=${SSH_PORT} · net=${DEVNET}(사설망·호스트 차단/인터넷 허용) · egress=${EGRESS_NETWORK:-(없음)}
※ 얼굴 SDK(QFE) 쓰면 devnet 방화벽에 호스트 포트 허용 필요: ALLOW_HOST_PORTS="18080" sudo ./scripts/devnet_firewall.sh up
마운트: 홈=${HOME_DIR} · weights=/weights(mlteam rw) · libs=/libs(ro) · datasets=/datasets(ro) · face-license=~/${FACE_LICENSE_REL}(ro)
얼굴 SDK: SUPREMA_ENDPOINT=${SUPREMA_ENDPOINT_URL:-(미설정)} ← 42 호스트 qfe_http_server 주소(docs/suprema-license-sharing.md §실행계획)
※ README 의 GPU·포트 대장에 GPU=${GPU_DEVICES}, sshd=${SSH_PORT} 를 기록할 것.
EOF
