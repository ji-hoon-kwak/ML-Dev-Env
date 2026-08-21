#!/usr/bin/env bash
# 개인용 PG/Redis(쓰기 격리) 관리 — 개발자가 42 호스트에서 직접 실행.
#   sudo 불필요(docker 그룹). piascope 서비스 네트워크는 자동 감지.
#
# 사용법:
#   ./dev_stores.sh up     [user]   # 개인 pg-<user>/redis-<user> 기동
#   ./dev_stores.sh info   [user]   # 접속 정보 출력
#   ./dev_stores.sh down   [user]   # 중지(데이터 볼륨 보존)
#   ./dev_stores.sh purge  [user]   # 중지 + 데이터 볼륨 삭제(되돌릴 수 없음)
#   user 생략 시 현재 로그인 계정.
set -euo pipefail

CMD="${1:-info}"
USER_NAME="${2:-$(id -un)}"
COMPOSE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/compose/dev-stores.yml"
PROJECT="dev-stores-${USER_NAME}"

# piascope 서비스 네트워크 자동 감지(dev 컨테이너가 붙어 있는 그 네트워크)
NET="${SERVICE_NETWORK:-$(docker inspect piascope-gateway \
    --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null \
    | grep -v '^$' | head -1 || true)}"
if [[ -z "$NET" ]]; then
    echo "ERROR: piascope 서비스 네트워크를 못 찾음. SERVICE_NETWORK=<네트워크명> 으로 지정하세요." >&2
    exit 1
fi

export DEV_USER="$USER_NAME" SERVICE_NETWORK="$NET"

case "$CMD" in
  up)
    docker compose -f "$COMPOSE" -p "$PROJECT" up -d
    echo "[ok] pg-${USER_NAME} · redis-${USER_NAME} 기동 (net=${NET})"
    echo "     컨테이너 안에서: PG=pg-${USER_NAME}:5432 (user=dev pw=dev db=dev) · Redis=redis-${USER_NAME}:6379"
    ;;
  down)
    docker compose -f "$COMPOSE" -p "$PROJECT" down
    echo "[ok] 중지(볼륨 pgdata-${USER_NAME} 보존)"
    ;;
  purge)
    docker compose -f "$COMPOSE" -p "$PROJECT" down -v
    echo "[ok] 중지 + 볼륨 삭제"
    ;;
  info)
    echo "network=${NET}"
    echo "컨테이너 안(ml-/pf-)에서: PG=pg-${USER_NAME}:5432 (user/pw/db=dev) · Redis=redis-${USER_NAME}:6379"
    echo "호스트 포트(GUI 등):"
    docker port "pg-${USER_NAME}" 2>/dev/null || echo "  (pg-${USER_NAME} 미기동 — 먼저 up)"
    docker port "redis-${USER_NAME}" 2>/dev/null || true
    ;;
  *)
    echo "usage: $0 <up|info|down|purge> [user]" >&2
    exit 1
    ;;
esac
