#!/usr/bin/env bash
# pia/pf-base 빌드 — 플랫폼(BE/FE) 공용 베이스 이미지 (python + node, GPU/torch 없음).
#
# 언제 실행하나:
#   - 최초 1회 (플랫폼 개발자 첫 발급 전). provision_pf.sh 가 없으면 자동 호출한다.
#   - docker/environment.pf.yml 을 바꿨을 때.
#
# 사용법: sudo ./build_pf_base.sh
set -euo pipefail

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../docker" && pwd)"
MLTEAM_GROUP="mlteam"
MLTEAM_GID_DEFAULT="2000"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: sudo 로 실행하세요." >&2
    exit 1
fi

if getent group "$MLTEAM_GROUP" >/dev/null; then
    MLTEAM_GID="$(getent group "$MLTEAM_GROUP" | cut -d: -f3)"
else
    MLTEAM_GID="$MLTEAM_GID_DEFAULT"
    groupadd -g "$MLTEAM_GID" "$MLTEAM_GROUP"
    echo "[ok] 호스트 그룹 생성: $MLTEAM_GROUP (gid=$MLTEAM_GID)"
fi

echo "[..] pia/pf-base 빌드 (conda + node 설치 — 최초 수 분)"
docker build -t pia/pf-base \
    --build-arg MLTEAM_GID="$MLTEAM_GID" \
    -f "$DOCKER_DIR/Dockerfile.pf-base" \
    "$DOCKER_DIR"
echo "[ok] pia/pf-base 빌드 완료 (mlteam gid=$MLTEAM_GID)"
