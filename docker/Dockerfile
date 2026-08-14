# 42 서버 개발자별 dev 컨테이너 베이스 이미지.
#
# 빌드는 provision_dev.sh 가 개발자별 UID/GID 를 넣어 수행한다:
#   docker build -t pia/dev-<user> \
#     --build-arg USERNAME=<user> --build-arg UID=<uid> --build-arg GID=<gid> \
#     docker/
#
# 전제: company/ai-dev:1.0 은 Ubuntu 계열 + CUDA 런타임 포함.
#       (uv 가 이미 들어있다면 아래 COPY --from 줄은 지워도 된다)

FROM company/ai-dev:1.0

# --- uv (베이스 이미지에 없을 경우) ---
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# --- OS 패키지 ---
# libgl1/libglib2.0-0: opencv-python 이 headless 서버에서 import 되려면 필요
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo git openssh-client libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# --- 개발자 계정 (호스트 UID/GID 와 일치시켜 볼륨 파일 소유권을 맞춘다) ---
ARG USERNAME=dev
ARG UID=1000
ARG GID=1000
RUN groupadd -g "${GID}" "${USERNAME}" \
    && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash "${USERNAME}" \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-"${USERNAME}" \
    && chmod 440 /etc/sudoers.d/90-"${USERNAME}"

# --- Python 환경 ---
# venv 를 홈 밖(/opt/venv)에 두는 이유: 홈은 호스트 볼륨으로 덮이므로
# 홈 안에 venv 를 만들면 이미지에 구운 환경이 마운트에 가려진다.
ENV UV_PROJECT_ENVIRONMENT=/opt/venv \
    PATH=/opt/venv/bin:$PATH

RUN mkdir -p /opt/project /opt/venv /workspace \
    && chown -R "${UID}:${GID}" /opt/project /opt/venv /workspace

USER ${USERNAME}
WORKDIR /opt/project

# uv.lock 이 아직 없으면 uv sync 가 생성한다. 재현성을 위해
# 최초 빌드 후 생성된 lock 을 리포에 커밋해 둘 것 (README 참조).
COPY --chown=${UID}:${GID} pyproject.toml uv.lock* ./
RUN uv sync

WORKDIR /workspace
CMD ["sleep", "infinity"]
