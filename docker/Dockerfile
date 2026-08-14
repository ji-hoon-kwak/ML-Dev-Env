# 42 서버 개발자별 dev 컨테이너 베이스 이미지.
#
# 빌드는 provision_dev.sh 가 개발자별 UID/GID 를 넣어 수행한다:
#   docker build -t pia/dev-<user> \
#     --build-arg USERNAME=<user> --build-arg UID=<uid> --build-arg GID=<gid> \
#     docker/
#
# 환경 관리자는 conda (팀 합의 2026-08-14). Anaconda 본사 리포지토리의
# 상용 라이선스 이슈를 피하기 위해 Miniforge(conda-forge 기본)를 쓴다.

FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

# --- OS 패키지 ---
# libgl1/libglib2.0-0: opencv-python 이 headless 서버에서 import 되려면 필요
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo git wget curl ca-certificates openssh-client \
        libgl1 libglib2.0-0 tmux htop vim \
    && rm -rf /var/lib/apt/lists/*

# --- Miniforge (conda) ---
RUN wget -qO /tmp/miniforge.sh \
        "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh" \
    && bash /tmp/miniforge.sh -b -p /opt/conda \
    && rm /tmp/miniforge.sh

# --- 개발자 계정 (호스트 UID/GID 와 일치시켜 볼륨 파일 소유권을 맞춘다) ---
# GID/GROUPNAME 은 provision_dev.sh 가 호스트 mlteam 그룹(기본 gid=2000)을 넘긴다.
# 컨테이너 primary group = mlteam GID → /home·/weights bind-mount 소유권이 호스트와 일치.
ARG USERNAME=dev
ARG UID=1000
ARG GID=2000
ARG GROUPNAME=mlteam
RUN groupadd -g "${GID}" "${GROUPNAME}" \
    && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash "${USERNAME}" \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-"${USERNAME}" \
    && chmod 440 /etc/sudoers.d/90-"${USERNAME}" \
    # 개발자가 conda env 를 자유롭게 만들 수 있도록 conda 를 본인 소유로
    && chown -R "${UID}:${GID}" /opt/conda \
    && mkdir -p /workspace && chown "${UID}:${GID}" /workspace

USER ${USERNAME}

# --- 기본 conda env (dev) ---
# ⚠️ 홈은 호스트 볼륨으로 덮이므로 conda init 을 이미지의 ~/.bashrc 에 구워도
#    소용없다. 활성화는 (a) 아래 PATH 기본값 + (b) provision_dev.sh 가 호스트
#    ~/.bashrc 에 넣어주는 guarded snippet 으로 해결한다.
COPY --chown=${UID}:${GID} environment.yml /opt/project/environment.yml
RUN /opt/conda/bin/conda env create -f /opt/project/environment.yml \
    && /opt/conda/bin/conda clean -afy

ENV PATH=/opt/conda/envs/dev/bin:/opt/conda/bin:$PATH

WORKDIR /workspace
CMD ["sleep", "infinity"]
