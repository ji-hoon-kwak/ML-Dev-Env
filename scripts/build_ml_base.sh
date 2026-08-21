#!/usr/bin/env bash
# pia/ml-base 빌드 — AI(ML) 공용 베이스 이미지(cuda+torch, 무거움).
#
# 언제 실행하나:
#   - 최초 1회 (AI 개발자 첫 발급 전). provision_ml.sh 가 없으면 자동 호출한다.
#   - docker/environment.ml.yml 을 바꿨을 때 (공통 패키지 추가/변경).
#
# 사용법: sudo ./build_ml_base.sh
set -euo pipefail

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../docker" && pwd)"
MLTEAM_GROUP="mlteam"
MLTEAM_GID_DEFAULT="2000"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: sudo 로 실행하세요." >&2
    exit 1
fi

# 호스트 mlteam GID 에 맞춘다(있으면 그 값, 없으면 기본값으로 그룹 생성).
if getent group "$MLTEAM_GROUP" >/dev/null; then
    MLTEAM_GID="$(getent group "$MLTEAM_GROUP" | cut -d: -f3)"
else
    MLTEAM_GID="$MLTEAM_GID_DEFAULT"
    groupadd -g "$MLTEAM_GID" "$MLTEAM_GROUP"
    echo "[ok] 호스트 그룹 생성: $MLTEAM_GROUP (gid=$MLTEAM_GID)"
fi

echo "[..] pia/ml-base 빌드 (conda + torch 설치 — 최초 수 분)"
docker build -t pia/ml-base \
    --build-arg MLTEAM_GID="$MLTEAM_GID" \
    -f "$DOCKER_DIR/Dockerfile.ml-base" \
    "$DOCKER_DIR"
echo "[ok] pia/ml-base 빌드 완료 (mlteam gid=$MLTEAM_GID)"
