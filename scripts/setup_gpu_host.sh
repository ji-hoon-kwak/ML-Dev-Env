#!/usr/bin/env bash
# GPU 호스트 위생 셋업 (idempotent · 안전 — docker 재시작/daemon.json 편집은 안 한다).
#
# 하는 일:
#   1) nvidia-container-toolkit 버전 점검(≥1.14.6 권장 — 그 미만은 create-dev-char-symlinks 가
#      드라이버 550+ 에서 'missing required device major nvidia-frontend' 로 실패)
#   2) /dev/char 심링크 생성 + 재부팅 영속(udev) — runc 의 device 요구사항 충족(부분 위생)
#   3) Docker cgroup 드라이버 점검 — 'systemd' 면 daemon-reload 가 GPU 접근을 스트립하는
#      근본 버그에 노출된다. 이 스크립트는 '경고+안내'만 하고, 실제 전환(daemon.json +
#      docker 재시작 = 배포 스택 잠깐 다운)은 의도적으로 자동화하지 않는다.
#
# 배경·전체 진단·해결(cgroupfs 전환/CDI): docs/gpu-nvml-troubleshooting.md
#
# 사용법 (호스트, root):  sudo ./scripts/setup_gpu_host.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: sudo 로 실행하세요." >&2
    exit 1
fi

# ---- 1) toolkit 버전 ----
if ! command -v nvidia-ctk >/dev/null 2>&1; then
    echo "ERROR: nvidia-ctk 없음 — nvidia-container-toolkit 설치 필요." >&2
    exit 1
fi
VER="$(nvidia-ctk --version 2>/dev/null | awk '/version/{print $NF}' | head -1)"
echo "[info] nvidia-container-toolkit: ${VER:-unknown}"
echo "       (≥1.14.6 권장 — 미만이면 아래 심링크 생성이 실패할 수 있음: sudo apt-get install -y nvidia-container-toolkit)"

# ---- 2) /dev/char 심링크 + udev 영속 ----
echo "[..] /dev/char 심링크 생성"
nvidia-ctk system create-dev-char-symlinks --create-all

UDEV_RULE="/lib/udev/rules.d/71-nvidia-dev-char.rules"
if [[ ! -f "$UDEV_RULE" ]]; then
    tee "$UDEV_RULE" >/dev/null <<'EOF'
ACTION=="add", DEVPATH=="/bus/pci/drivers/nvidia", RUN+="/usr/bin/nvidia-ctk system create-dev-char-symlinks --create-all"
EOF
    echo "[ok] udev 규칙 설치(재부팅 영속): $UDEV_RULE"
else
    echo "[keep] udev 규칙 이미 존재: $UDEV_RULE"
fi

# ---- 3) Docker cgroup 드라이버 점검 ----
DRIVER="$(docker info 2>/dev/null | awk -F': ' '/Cgroup Driver/{print $2}' | tr -d ' ')"
echo "[info] Docker cgroup driver: ${DRIVER:-unknown}"
if [[ "$DRIVER" == "systemd" ]]; then
    cat >&2 <<'EOF'

⚠️  Docker cgroup driver 가 'systemd' 입니다.
    이 상태에서는 `systemctl daemon-reload` 가 실행 중 컨테이너의 GPU device 접근을 스트립해
    "Failed to initialize NVML: Unknown Error" 가 반복 발생합니다(심링크만으론 부족).

    근본 해결(둘 중 하나 — docs/gpu-nvml-troubleshooting.md 참조):
      (A) cgroupfs 로 전환:  daemon.json 에 {"exec-opts":["native.cgroupdriver=cgroupfs"]}
          + `systemctl restart docker`  (⚠️ 모든 docker 컨테이너 잠깐 재시작 = 배포 스택 다운)
      (B) CDI 사용:  systemd 유지 · provision 을 --device nvidia.com/gpu=all 로 변경

    ※ 스택 다운을 감수할 수 있으면 (A) 가 가장 간단·확실. 자동화하지 않은 이유 = 스택 재시작이
       의도적 결정이어야 하기 때문.
EOF
elif [[ "$DRIVER" == "cgroupfs" ]]; then
    echo "[ok] cgroupfs — daemon-reload 로 인한 GPU 접근 스트립 문제 없음."
fi

echo "[done] GPU 호스트 위생 셋업 완료."
