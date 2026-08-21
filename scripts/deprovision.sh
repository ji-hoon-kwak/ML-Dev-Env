#!/usr/bin/env bash
# 42 서버 개발자 오프보딩: 컨테이너·이미지 제거 + 계정 잠금.
#
# 사용법: sudo ./deprovision.sh <username> [--delete-account]
#   기본: 컨테이너/이미지 삭제 + SSH 키 제거 + 계정 잠금 (홈은 보존)
#   --delete-account: 계정까지 삭제 (홈은 /data/archive/ 로 이동)
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: sudo 로 실행하세요." >&2
    exit 1
fi
if [[ $# -lt 1 ]]; then
    echo "usage: sudo $0 <username> [--delete-account]" >&2
    exit 1
fi

USERNAME="$1"
DELETE_ACCOUNT="${2:-}"

if ! id "$USERNAME" &>/dev/null; then
    echo "ERROR: 계정 없음: $USERNAME" >&2
    exit 1
fi
HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"

# 접두사(ml-=AI · pf-=플랫폼 · dev-=레거시) 무엇이든 존재하는 컨테이너/이미지 제거
for PREFIX in ml pf dev; do
    CONTAINER="${PREFIX}-${USERNAME}"
    IMAGE="pia/${PREFIX}-${USERNAME}"
    docker rm -f "$CONTAINER" 2>/dev/null && echo "[ok] 컨테이너 제거: $CONTAINER" || true
    docker rmi "$IMAGE" 2>/dev/null && echo "[ok] 이미지 제거: $IMAGE" || true
done

# SSH 접근 차단
if [[ -f "$HOME_DIR/.ssh/authorized_keys" ]]; then
    : > "$HOME_DIR/.ssh/authorized_keys"
    echo "[ok] authorized_keys 비움"
fi
usermod -L -s /usr/sbin/nologin "$USERNAME"
gpasswd -d "$USERNAME" docker 2>/dev/null || true
echo "[ok] 계정 잠금 + docker 그룹 제거"

if [[ "$DELETE_ACCOUNT" == "--delete-account" ]]; then
    ARCHIVE="/data/archive/${USERNAME}-$(date +%Y%m%d)"
    mkdir -p /data/archive
    mv "$HOME_DIR" "$ARCHIVE"
    userdel "$USERNAME"
    echo "[ok] 계정 삭제 · 홈 보관: $ARCHIVE"
fi
