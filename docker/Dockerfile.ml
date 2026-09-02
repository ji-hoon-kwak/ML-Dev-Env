# pia/ml-<user> — AI(ML) 개발자별 얇은 이미지.
#
# pia/ml-base(무거운 conda) 위에 계정 한 개만 얹는다 → 빌드 ~1초.
# provision_ml.sh 가 개발자별 UID 를 넣어 빌드한다:
#   docker build -t pia/ml-<user> \
#     --build-arg USERNAME=<user> --build-arg UID=<uid> \
#     -f docker/Dockerfile.ml docker/
#
# ⚠️ pia/ml-base 가 먼저 존재해야 한다 (scripts/build_ml_base.sh · provision 이 자동 확인).

FROM pia/ml-base

# primary group = mlteam (base 에서 생성) → /home·/weights bind-mount 소유권이 호스트와 일치.
# 컨테이너 안 sudo 는 유지: 이 컨테이너는 개발자의 격리 샌드박스다(호스트엔 못 닿는다).
ARG USERNAME=dev
ARG UID=1000
RUN useradd -m -u "${UID}" -g mlteam -s /bin/bash "${USERNAME}" \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-"${USERNAME}" \
    && chmod 440 /etc/sudoers.d/90-"${USERNAME}"

# ⚠️ USER 전환/CMD 재정의 없음: pid1 은 base 의 sshd(root)여야 한다. 개발자는 컨테이너
#    sshd 로 로그인하면 자기 계정 셸(bash)로 떨어진다(sshd 가 인증 후 권한 강하).
WORKDIR /workspace
