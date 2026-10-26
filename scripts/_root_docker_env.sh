#!/usr/bin/env bash
# 이 리포의 **root 실행** 스크립트가 공통으로 읽는 docker 클라이언트 환경.
#
# 사용법 — 각 스크립트의 `EUID -ne 0` 체크 바로 뒤에서:
#     # shellcheck source=_root_docker_env.sh
#     source "$(dirname "${BASH_SOURCE[0]}")/_root_docker_env.sh"
#
# ⭐ 왜 필요한가 — root 실행이 '호출자의' ~/.docker 를 오염시킨다.
#
#   Ubuntu sudo 는 HOME 을 보존한다(always_set_home 꺼짐). 그래서
#   `sudo ./provision_ml.sh ...` 안에서 그냥 `docker build` 를 부르면, docker 는
#   HOME=/home/<admin> 을 보고 **/home/<admin>/.docker/ 아래에 root 소유 파일**을 만든다.
#   docker 신버전은 빌드마다 `~/.docker/buildx/activity/<builder>` 를 갱신하므로, 그 뒤로
#   같은 admin 계정의 **non-root** `docker build` 가 전부 이렇게 죽는다:
#
#       ERROR: open /home/<admin>/.docker/buildx/activity/default: permission denied
#
#   실제 사건 (2026-10-26 · 42 서버):
#     02:37  sudo env LIBS_RW=1 SSH_PORT=2201 ./scripts/provision_ml.sh minkyung keys/minkyung.pub
#            → /home/gpuadmin/.docker/buildx/activity/default 가 root:root 로 생성
#     05:54  piaspace-scope 의 scripts/deploy/redeploy.sh --apply --only trace-worker
#            (non-root 레인) 이 base-gpu 빌드 첫 줄에서 permission denied 로 전사
#   ※ docker CLI 를 29.x 로 올리기 전에는 activity/ 경로 자체가 없어 같은 혼용이
#     **무증상**이었다. 업그레이드가 잠재 결함을 드러낸 것이지 원인은 이 혼용이다.
#
# ⭐ 처방 — 레인마다 docker 클라이언트 상태를 분리한다 (= `sudo -H` 와 같은 상태).
#
#   42 는 root 레인(이 리포의 프로비저닝)과 non-root 레인(piaspace-scope 서비스 배포)이
#   **구조적으로 공존**하는 호스트다. 이 스크립트들의 root 는 정당하다 — useradd · ssh 키
#   설치 · nologin · 컨테이너 sshd 는 root 없이 안 된다. 그러니 "레인을 하나로 통일" 이
#   아니라 "레인별 상태 분리" 가 답이다. root 레인은 root 의 설정 디렉터리를 쓴다.
#
#   ℹ️ 이미지·빌드 캐시는 **daemon 쪽**이라 DOCKER_CONFIG 와 무관하다. 즉 pia/ml-base
#      재사용·발급 속도에 영향이 없다. 분리되는 것은 **클라이언트 상태**뿐이다
#      (buildx 메타데이터 · 컨텍스트 · 레지스트리 로그인).
#   ⚠️ 레지스트리 로그인은 설정 디렉터리마다 따로다. 비공개 레지스트리를 쓰게 되면
#      `sudo docker login ...` 을 한 번 해서 root 쪽 config.json 을 만들어야 한다.
#      (현재 base 이미지는 Docker Hub 공개 이미지라 해당 없음.)

# root 의 홈을 passwd 에서 해석한다(관례상 /root, 아닌 호스트도 있다).
_ROOT_HOME="$(getent passwd 0 2>/dev/null | cut -d: -f6 || true)"
[[ -n "$_ROOT_HOME" ]] || _ROOT_HOME="/root"

# 운영자가 명시적으로 지정했으면 존중한다.
export DOCKER_CONFIG="${DOCKER_CONFIG:-$_ROOT_HOME/.docker}"
if [[ ! -d "$DOCKER_CONFIG" ]]; then
    mkdir -p "$DOCKER_CONFIG"
    chmod 700 "$DOCKER_CONFIG"   # config.json 에 레지스트리 자격증명이 들어갈 수 있다
fi

# 이미 오염된 호스트를 조용히 넘어가지 않는다 — 고치는 한 줄을 알려준다.
# ⚠️ 자동 chown 은 하지 않는다. 남의 홈을 말없이 바꾸는 것은 이 스크립트의 일이 아니고,
#    "스크립트가 알아서 고쳐 준다" 는 기대가 바로 sudo 혼용을 다시 부른다.
_warn_if_caller_docker_poisoned() {
    local caller_home
    [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] || return 0
    caller_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
    [[ -n "$caller_home" && -d "$caller_home/.docker" ]] || return 0
    if find "$caller_home/.docker" ! -user "$SUDO_USER" -print -quit 2>/dev/null | grep -q .; then
        echo "[warn] $caller_home/.docker 에 $SUDO_USER 소유가 아닌 파일이 있습니다 (과거 root 실행의 잔재)." >&2
        echo "[warn]   그 계정의 non-root 'docker build' 가 permission denied 로 실패합니다. 복구:" >&2
        echo "[warn]     sudo chown -R $SUDO_USER: $caller_home/.docker" >&2
    fi
}
_warn_if_caller_docker_poisoned
