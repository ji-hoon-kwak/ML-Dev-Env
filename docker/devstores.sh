#!/usr/bin/env bash
# devstores — 개발자 컨테이너 '안에서' 개인 테스트 인프라(PG/Redis)를 로컬 프로세스로 띄운다.
#
# ⭐ 왜 컨테이너 안 로컬 프로세스인가 (검토 결론):
#   - 상태를 '생산하는' 의존(Redis Streams·PG)은 공유 인프라에 물리면 안 된다.
#     내 테스트 이벤트가 데모/남의 것과 섞이고, at-least-once Redis 그룹에서
#     남의 메시지를 훔쳐 ACK 하며, FLUSHALL/truncate 로 리셋도 못 한다.
#   - 여기서 뜬 PG/Redis 는 이 컨테이너 안에서만 산다 → 호스트 `docker ps` 에
#     안 보이고, 호스트 포트를 안 먹고, 남과 안 섞이고, `reset` 으로 자유롭게 비운다.
#   - docker-in-docker/ sysbox 불필요 — 그냥 로컬 프로세스다(가장 단순·견고).
#
# 사용법 (컨테이너 안에서, 본인 계정으로 · root 아님):
#   devstores up       # redis + postgres 기동 (데이터 ~/.devstores 에 영속)
#   devstores info     # 접속 정보
#   devstores status   # 실행 여부
#   devstores down      # 중지 (데이터 보존)
#   devstores reset      # 중지 + 데이터 삭제(되돌릴 수 없음)
#
# 접속 (같은 컨테이너 안 애플리케이션 config):
#   Redis  = 127.0.0.1:6379
#   PG     = 127.0.0.1:5432  (db=dev · user=<본인 OS 계정> · 암호 없음, local trust)
set -euo pipefail

CMD="${1:-info}"
ROOT="${DEVSTORES_HOME:-$HOME/.devstores}"
PGDATA="$ROOT/pg"
REDISDIR="$ROOT/redis"
PGPORT="${DEVSTORES_PG_PORT:-5432}"
REDISPORT="${DEVSTORES_REDIS_PORT:-6379}"

if [[ "$(id -u)" == "0" ]]; then
    echo "ERROR: root 로 실행하지 마세요. 본인 계정(예: dev-user)으로 실행하세요." >&2
    echo "       (initdb/postgres 는 root 로 못 뜬다 — 컨테이너 안 본인 셸에서 실행)" >&2
    exit 1
fi

# postgres 바이너리 경로 자동 감지(ubuntu=14 / debian=15 등 버전 무관)
PG_BIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)"
have_pg()    { [[ -n "$PG_BIN" && -x "$PG_BIN/pg_ctl" ]]; }
have_redis() { command -v redis-server >/dev/null 2>&1; }

pg_running()    { have_pg && "$PG_BIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; }
redis_running() { have_redis && redis-cli -p "$REDISPORT" ping >/dev/null 2>&1; }

start_pg() {
    have_pg || { echo "[skip] postgresql 미설치 — base 이미지 재빌드 필요"; return; }
    if pg_running; then echo "[skip] postgres 이미 실행중"; return; fi
    if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
        mkdir -p "$PGDATA"
        "$PG_BIN/initdb" -D "$PGDATA" -U "$(id -un)" --auth=trust >/dev/null
        echo "[ok] initdb: $PGDATA (superuser=$(id -un))"
    fi
    "$PG_BIN/pg_ctl" -D "$PGDATA" -l "$PGDATA/pg.log" \
        -o "-p $PGPORT -k /tmp -c listen_addresses=127.0.0.1" start >/dev/null
    # db 'dev' 보장(멱등)
    "$PG_BIN/createdb" -h 127.0.0.1 -p "$PGPORT" dev 2>/dev/null || true
    echo "[ok] postgres up  → 127.0.0.1:$PGPORT (db=dev user=$(id -un) trust)"
}

start_redis() {
    have_redis || { echo "[skip] redis-server 미설치 — base 이미지 재빌드 필요"; return; }
    if redis_running; then echo "[skip] redis 이미 실행중"; return; fi
    mkdir -p "$REDISDIR"
    redis-server --daemonize yes --bind 127.0.0.1 --port "$REDISPORT" \
        --dir "$REDISDIR" --pidfile "$REDISDIR/redis.pid" \
        --logfile "$REDISDIR/redis.log" --save "" --appendonly no
    echo "[ok] redis up     → 127.0.0.1:$REDISPORT"
}

stop_pg() {
    pg_running && "$PG_BIN/pg_ctl" -D "$PGDATA" -m fast stop >/dev/null && echo "[ok] postgres 중지" || true
}
stop_redis() {
    redis_running && redis-cli -p "$REDISPORT" shutdown nosave 2>/dev/null && echo "[ok] redis 중지" || true
}

case "$CMD" in
  up)     start_redis; start_pg ;;
  down)   stop_redis; stop_pg ;;
  reset)
    stop_redis; stop_pg
    rm -rf "$PGDATA" "$REDISDIR"
    echo "[ok] 데이터 삭제: $ROOT (다음 up 에서 새로 생성)"
    ;;
  status)
    printf "redis    : %s\n" "$(redis_running && echo UP || echo down)"
    printf "postgres : %s\n" "$(pg_running && echo UP || echo down)"
    ;;
  info)
    cat <<EOF
데이터 루트: $ROOT   (컨테이너 안에서만 존재 · 호스트 docker ps 에 안 보임)
접속 (같은 컨테이너 안 애플리케이션 config):
  REDIS_URL      = redis://127.0.0.1:$REDISPORT/0
  POSTGRES(host) = 127.0.0.1  port=$PGPORT  db=dev  user=$(id -un)  (암호 없음 · local trust)
명령: devstores up | status | info | down | reset
EOF
    ;;
  *) echo "usage: devstores <up|down|reset|status|info>" >&2; exit 1 ;;
esac
