# 42 서버 개발자별 dev 컨테이너 베이스 이미지.
#
# 빌드는 provision_dev.sh 가 개발자별 UID 를 넣어 수행한다:
#   docker build -t pia/dev-<user> \
#     --build-arg USERNAME=<user> --build-arg UID=<uid> --build-arg MLTEAM_GID=<gid> \
#     docker/
#
# 환경 관리자는 conda (팀 합의 2026-08-14). Anaconda 본사 리포지토리의
# 상용 라이선스 이슈를 피하기 위해 Miniforge(conda-forge 기본)를 쓴다.
#
# ⭐ 레이어 순서 규칙: "개발자와 무관한 무거운 작업(apt·miniforge·conda)"을 전부 위에,
#    "개발자별 작업(useradd)"을 맨 아래에 둔다. 그래야 두 번째 개발자부터 무거운
#    레이어가 캐시 히트되고 useradd 한 줄만 새로 돌아 빌드가 수 초에 끝난다.
#    (per-user ARG/RUN 을 위로 올리면 그 아래 conda 설치가 매번 캐시 무효화된다.)

FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

# --- OS 패키지 (개발자 무관 · 캐시) ---
# libgl1/libglib2.0-0: opencv-python 이 headless 서버에서 import 되려면 필요
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo git wget curl ca-certificates openssh-client \
        libgl1 libglib2.0-0 tmux htop vim \
    && rm -rf /var/lib/apt/lists/*

# --- Miniforge (conda) (개발자 무관 · 캐시) ---
RUN wget -qO /tmp/miniforge.sh \
        "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh" \
    && bash /tmp/miniforge.sh -b -p /opt/conda \
    && rm /tmp/miniforge.sh

# --- mlteam 그룹 + 기본 conda env (개발자 무관 · 캐시) ---
# MLTEAM_GID 는 고정값(기본 2000)이라 개발자가 바뀌어도 이 레이어는 캐시된다.
# conda 트리를 root:mlteam + group-writable 로 두면, mlteam 소속 개발자가 자기
# 컨테이너 안에서 pip/conda install 가능(copy-on-write 라 다른 개발자에겐 영향 없음).
ARG MLTEAM_GID=2000
COPY environment.yml /opt/project/environment.yml
RUN groupadd -g "${MLTEAM_GID}" mlteam \
    && /opt/conda/bin/conda env create -f /opt/project/environment.yml \
    && /opt/conda/bin/conda clean -afy \
    && chown -R root:"${MLTEAM_GID}" /opt/conda \
    && chmod -R g+w /opt/conda \
    && mkdir -p /workspace && chown root:"${MLTEAM_GID}" /workspace && chmod 2775 /workspace

# 홈은 호스트 볼륨으로 덮이므로 이미지의 ~/.bashrc conda init 은 무효.
# 활성화는 (a) 아래 PATH 기본값 + (b) provision_dev.sh 의 호스트 ~/.bashrc snippet.
ENV PATH=/opt/conda/envs/dev/bin:/opt/conda/bin:$PATH

# --- 개발자 계정 (맨 아래 · 개발자별로만 이 레이어가 재실행) ---
# primary group = mlteam GID → /home·/weights bind-mount 소유권이 호스트와 일치.
ARG USERNAME=dev
ARG UID=1000
RUN useradd -m -u "${UID}" -g "${MLTEAM_GID}" -s /bin/bash "${USERNAME}" \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-"${USERNAME}" \
    && chmod 440 /etc/sudoers.d/90-"${USERNAME}"

USER ${USERNAME}
WORKDIR /workspace
CMD ["sleep", "infinity"]
