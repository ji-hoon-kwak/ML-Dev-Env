#!/usr/bin/env bash
# 옛 baked 호스트 키를 영속 저장소로 '수확(harvest)'해, 새 방식 재-provision 을
# 무중단(zero-touch)으로 만든다 — 개발자가 known_hosts 를 만질 필요가 없다.
#
# 왜 필요한가:
#   예전 base 이미지는 sshd 호스트 키를 이미지에 구웠다(`ssh-keygen -A`). 그 시절 컨테이너에
#   접속했던 개발자는 그 키를 자기 맥 ~/.ssh/known_hosts 에 캐시해 두었다. 컨테이너를 '새 방식'
#   (호스트 키를 /data/42dev/hostkeys/<컨테이너> 에 영속화 후 :ro 마운트)으로 재-provision 할 때
#   provision 이 '새 키'를 생성하면, 그 개발자는 전원 한 번씩
#     "REMOTE HOST IDENTIFICATION HAS CHANGED"
#   를 겪고 각자 known_hosts 를 지워야 한다.
#
#   이 스크립트는 재-provision 전에, '지금 그 컨테이너가 쓰고 있는 바로 그 키'를 영속 저장소로
#   복사해 둔다. 그러면 이후 provision 은 `[keep] 기존 호스트 키 재사용` 경로를 타 같은 키를
#   그대로 마운트한다 → 클라이언트 입장에선 키가 안 바뀐 것 → 아무도 에러를 안 본다.
#
# 사용법 (42 서버, sudo):
#   sudo ./scripts/migrate_hostkeys.sh [컨테이너 ...]
#   - 인자 없으면 이름이 pf-* / ml-* 인 개발자 컨테이너 전체를 대상으로 한다.
#   - 이미 영속 키가 있는 컨테이너(= 이미 마이그레이션됨)는 건너뛴다 → 재실행 안전(idempotent).
#
# 실행 순서 (컨테이너별):
#   1) 이 스크립트로 키 수확  →  2) docker rm -f <컨테이너>  →  3) provision_{pf,ml}.sh 재발급
#   (2·3 은 기존 절차 그대로. 3 에서 provision 이 수확한 키를 재사용한다.)
set -euo pipefail

# provision_{pf,ml}.sh 의 HOSTKEYS_DIR 과 반드시 동일해야 한다.
HOSTKEYS_DIR="/data/42dev/hostkeys"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: sudo 로 실행하세요." >&2
    exit 1
fi

# 대상 컨테이너 목록
if [[ $# -gt 0 ]]; then
    CONTAINERS=("$@")
else
    mapfile -t CONTAINERS < <(docker ps -a --format '{{.Names}}' | grep -E '^(pf|ml)-' || true)
fi

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    echo "[info] 대상 컨테이너 없음 (pf-* / ml-*)."
    exit 0
fi

MLTEAM_GID="$(getent group mlteam | cut -d: -f3 2>/dev/null || echo 2000)"

seeded=0 skipped=0 failed=0
for C in "${CONTAINERS[@]}"; do
    DEST="$HOSTKEYS_DIR/$C"

    if [[ -f "$DEST/ssh_host_ed25519_key" ]]; then
        echo "[skip] $C — 영속 키가 이미 있음(마이그레이션 완료): $DEST"
        skipped=$((skipped+1)); continue
    fi
    if ! docker inspect "$C" &>/dev/null; then
        echo "[warn] $C — 컨테이너가 없음, 건너뜀"
        failed=$((failed+1)); continue
    fi

    install -d -m 700 "$DEST"
    got=0
    for T in ed25519 rsa ecdsa; do
        if docker cp "$C:/etc/ssh/ssh_host_${T}_key"     "$DEST/ssh_host_${T}_key"     2>/dev/null \
        && docker cp "$C:/etc/ssh/ssh_host_${T}_key.pub" "$DEST/ssh_host_${T}_key.pub" 2>/dev/null; then
            got=$((got+1))
        else
            echo "[warn] $C — ssh_host_${T}_key 복사 실패(그 타입이 없을 수 있음)"
        fi
    done

    if [[ $got -eq 0 ]]; then
        echo "[fail] $C — 어떤 호스트 키도 못 가져옴. 컨테이너가 /etc/ssh/ssh_host_* 를 안 쓰는 구조일 수 있다." >&2
        rmdir "$DEST" 2>/dev/null || true
        failed=$((failed+1)); continue
    fi

    chmod 600 "$DEST"/ssh_host_*_key      2>/dev/null || true
    chmod 644 "$DEST"/ssh_host_*_key.pub  2>/dev/null || true
    chown -R "root:${MLTEAM_GID}" "$DEST"

    echo "[ok] $C — 기존 호스트 키 수확 완료: $DEST"
    [[ -f "$DEST/ssh_host_ed25519_key.pub" ]] && \
        echo "     지문: $(ssh-keygen -lf "$DEST/ssh_host_ed25519_key.pub")"
    seeded=$((seeded+1))
done

echo
echo "=== 요약: 수확 ${seeded} · 건너뜀 ${skipped} · 실패 ${failed} ==="
cat <<'EOF'
다음 단계: 각 컨테이너를 재-provision 하면 provision 이 '[keep] 기존 호스트 키 재사용'
로그를 내며 위에서 수확한 키를 그대로 마운트한다 → 개발자 known_hosts 무수정, 에러 0.
  docker rm -f <컨테이너>
  SSH_PORT=<포트> sudo -E ./scripts/provision_pf.sh <user> <pubkey>   # 또는 provision_ml.sh
EOF
