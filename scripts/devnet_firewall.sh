#!/usr/bin/env bash
# devnet_firewall — 개발 컨테이너 전용 네트워크 + egress 방화벽 (admin/host).
#
# 목표: 개발 컨테이너가 '호스트·사설망(piascope 인프라·다른 컨테이너·사내 LAN)'에
#   도달하지 못하게 하되, '인터넷'(pip/apt/npm/git/conda)은 허용한다.
#   → dev 데이터 오염 경로(호스트 공개포트로 raw IP 도달)를 원천 차단하면서 개발은 유지.
#
# 구성:
#   1) docker network 'devnet'(172.31.0.0/16, 컨테이너 간 통신 icc=false) 생성
#   2) iptables:
#        DOCKER-USER : devnet → 10/8·172.16/12·192.168/16·169.254/16  DROP  (내부·타 컨테이너·LAN)
#        INPUT       : devnet → 호스트 자신  DROP (단 ESTABLISHED·허용포트 예외)
#      나머지(공인 IP=인터넷)는 통과.
#
# ⚠️ 이 서버엔 데모 스택(piascope-*)도 돈다. 규칙은 devnet 서브넷(172.31/16)에만 스코프되어
#    piascope 컨테이너(172.18/172.19 등)엔 영향 없다. 그래도 첫 적용은 root 세션을 열어둔 채
#    ml-jihoon 하나로만 테스트하고, 이상 시 즉시 `down` 으로 롤백할 것.
#
# 사용법 (root):
#   sudo ./devnet_firewall.sh up            # 네트워크+규칙 설치 (멱등)
#   sudo ./devnet_firewall.sh status        # 현재 상태
#   sudo ./devnet_firewall.sh down          # 규칙 제거 (네트워크는 보존)
#   sudo ./devnet_firewall.sh down --net     # 규칙 제거 + 네트워크까지 제거(연결 컨테이너 없을 때)
#
#   옵션(env):
#     DEVNET_SUBNET=172.31.0.0/16            # 전용 서브넷
#     ALLOW_HOST_PORTS="18080"               # 호스트로 허용할 예외 포트(QFE/Suprema 등, 공백구분)
set -euo pipefail

DEVNET="${DEVNET:-devnet}"
SUBNET="${DEVNET_SUBNET:-172.31.0.0/16}"
# 기본으로 QFE/Suprema(18080)를 연다 — ml 컨테이너의 표준 의존이라 "그냥 되게".
# 필요 없으면 ALLOW_HOST_PORTS="" 로 비우면 됨.
ALLOW_HOST_PORTS="${ALLOW_HOST_PORTS:-18080}"
PRIVATE_RANGES=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16)
CMD="${1:-status}"

if [[ $EUID -ne 0 ]]; then echo "ERROR: sudo 로 실행하세요." >&2; exit 1; fi

ensure_net() {
    if docker network inspect "$DEVNET" &>/dev/null; then
        echo "[skip] docker network '$DEVNET' 이미 존재"
    else
        docker network create \
            --driver bridge \
            --subnet "$SUBNET" \
            --opt com.docker.network.bridge.enable_icc=false \
            --opt com.docker.network.bridge.name=br-devnet \
            "$DEVNET" >/dev/null
        echo "[ok] docker network 생성: $DEVNET ($SUBNET · icc=false)"
    fi
}

# 멱등 insert: 규칙이 없을 때만 넣는다
ins() {  # ins <chain> <rule...>
    local chain="$1"; shift
    iptables -C "$chain" "$@" 2>/dev/null || iptables -I "$chain" "$@"
}
del() {  # del <chain> <rule...>  (있으면 지움)
    local chain="$1"; shift
    while iptables -C "$chain" "$@" 2>/dev/null; do iptables -D "$chain" "$@"; done
}

rules_up() {
    # --- FORWARD 경로(컨테이너→타 컨테이너/LAN/인터넷) : DOCKER-USER ---
    # 사설망 목적지는 DROP, 공인망은 통과(=인터넷 허용).
    for r in "${PRIVATE_RANGES[@]}"; do
        ins DOCKER-USER -s "$SUBNET" -d "$r" -j DROP
    done
    # ⭐ 허용 포트(QFE/Suprema 18080 등)는 사설망 DROP 위로 예외. 컨테이너→호스트
    #    게이트웨이:포트가 라우팅상 FORWARD 로 잡히는 환경에서도 뚫리도록 INPUT 뿐
    #    아니라 여기(FORWARD)에도 예외를 둔다 — 둘 다 있으면 경로와 무관하게 통과.
    for p in $ALLOW_HOST_PORTS; do
        ins DOCKER-USER -s "$SUBNET" -p tcp --dport "$p" -j RETURN
    done
    # ⭐ established/related 는 항상 통과(맨 위) — inbound SSH(2200) 응답이 LAN(10.x)로
    #    돌아갈 때 위 DROP 에 걸리지 않게. NEW 연결만 위 규칙으로 막는다.
    ins DOCKER-USER -s "$SUBNET" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

    # --- 호스트 자신으로 가는 경로(컨테이너→172.31.0.1/호스트포트) : INPUT ---
    # DROP 을 넣되, 되돌아오는 established 와 허용 포트는 예외.
    ins INPUT -s "$SUBNET" -j DROP
    for p in $ALLOW_HOST_PORTS; do
        ins INPUT -s "$SUBNET" -p tcp --dport "$p" -j ACCEPT   # DROP 위로 삽입됨(-I)
    done
    # established 리턴은 항상 통과(맨 위)
    ins INPUT -s "$SUBNET" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    echo "[ok] iptables 규칙 설치 (devnet=$SUBNET · 허용포트=[${ALLOW_HOST_PORTS:-none}] · 인터넷 허용)"
}

rules_down() {
    del DOCKER-USER -s "$SUBNET" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    for p in $ALLOW_HOST_PORTS; do del DOCKER-USER -s "$SUBNET" -p tcp --dport "$p" -j RETURN; done
    for r in "${PRIVATE_RANGES[@]}"; do del DOCKER-USER -s "$SUBNET" -d "$r" -j DROP; done
    del INPUT -s "$SUBNET" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    for p in $ALLOW_HOST_PORTS; do del INPUT -s "$SUBNET" -p tcp --dport "$p" -j ACCEPT; done
    del INPUT -s "$SUBNET" -j DROP
    echo "[ok] iptables 규칙 제거 (devnet=$SUBNET)"
}

case "$CMD" in
  up)
    ensure_net
    rules_up
    cat <<EOF
[i] 개발 컨테이너는 --network $DEVNET 로 발급하면 이 격리를 받는다(provision_*.sh 반영됨).
[i] ⚠️ 재부팅하면 iptables 규칙은 사라진다 → 영속화:
      sudo netfilter-persistent save     # (iptables-persistent 설치 시)
      또는 부팅 훅에서 'devnet_firewall.sh up' 재실행.
[i] 검증(컨테이너 안):
      curl -m3 https://pypi.org        → 성공(인터넷 O)
      curl -m3 http://172.17.0.1:3120  → 실패/timeout(호스트·공유인프라 X)
EOF
    ;;
  down)
    rules_down
    if [[ "${2:-}" == "--net" ]]; then
        docker network rm "$DEVNET" 2>/dev/null && echo "[ok] network 제거: $DEVNET" \
            || echo "[warn] network 제거 실패(연결된 컨테이너가 있으면 먼저 재발급/중지)"
    fi
    ;;
  status)
    echo "== docker network '$DEVNET' =="
    docker network inspect "$DEVNET" --format 'subnet={{range .IPAM.Config}}{{.Subnet}}{{end}} icc={{index .Options "com.docker.network.bridge.enable_icc"}}' 2>/dev/null || echo "(없음)"
    echo "== iptables DOCKER-USER (devnet) =="
    iptables -S DOCKER-USER | grep -F "$SUBNET" || echo "(규칙 없음)"
    echo "== iptables INPUT (devnet) =="
    iptables -S INPUT | grep -F "$SUBNET" || echo "(규칙 없음)"
    ;;
  *) echo "usage: sudo $0 <up|down [--net]|status>" >&2; exit 1 ;;
esac
