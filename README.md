# 42 서버 개발 환경 (dev containers)

42 서버에 AI 개발자별 도커 컨테이너를 발급하고 VS Code Dev Containers 로 접속하는
환경의 관리 도구. **서비스 리포(TRACE_SSAVE-AI-MVP)와 분리된 인프라 툴링**이다.

## 구조

두 종류의 개발 컨테이너가 있다 (역할별 접두사로 구분):

| 역할 | 접두사 | 이미지 base | 특징 | 발급 스크립트 |
|---|---|---|---|---|
| **AI(ML)** | `ml-<user>` | `pia/ml-base` | GPU + CUDA + torch + 모델 wheel | `provision_ml.sh` |
| **플랫폼(BE/FE)** | `pf-<user>` | `pia/pf-base` | **GPU/torch 없음** · python + **node** · 서비스 네트워크 연결 | `provision_pf.sh` |

```
docker/
  Dockerfile.ml-base    # pia/ml-base: nvidia/cuda 12.4 + Miniforge + torch (AI, 무거움)
  Dockerfile.ml         # pia/ml-<user>: FROM pia/ml-base + 계정 (~1초)
  environment.ml.yml    # AI conda env: torch cu124, opencv, ultralytics 등
  Dockerfile.pf-base    # pia/pf-base: python:3.12-slim + node (플랫폼, GPU/torch/conda 없음)
  Dockerfile.pf         # pia/pf-<user>: FROM pia/pf-base + 계정 (~1초)
  requirements.pf.txt   # 플랫폼 pip 의존성: fastapi/uvicorn/httpx (conda 없음 · venv)
scripts/
  build_ml_base.sh      # pia/ml-base 빌드 (AI · 최초 1회 / environment.ml.yml 변경 시)
  build_pf_base.sh      # pia/pf-base 빌드 (플랫폼 · 최초 1회 / requirements.pf.txt 변경 시)
  provision_ml.sh       # AI(ml-) 온보딩: 계정 + GPU 컨테이너 (base 없으면 자동 빌드)
  provision_pf.sh       # 플랫폼(pf-) 온보딩: 계정 + GPU없는 컨테이너 + 서비스망 연결
  deprovision.sh        # 오프보딩: ml-/pf-/dev- 컨테이너·이미지 제거 + 계정 잠금
  dev_stores.sh         # 개발자용: 개인 PG/Redis(쓰기 격리) up/down/info
compose/
  dev-stores.yml         # 개인용 postgres + redis (dev_stores.sh 가 실행)
docs/
  REQUEST-ACCESS.md      # 신규 개발자용: SSH 키 발급 + 환경 신청서
  ONBOARDING.md          # 개발자용: 발급 후 접속·VS Code·공용 서버 수칙
  gpu-allocation.md      # GPU 4장 용도별 분할 정책 (단일 원천)
  shared-infra-rules.md  # ⭐ 공용 인프라(Milvus/PG/ES/Redis…) 쓰기 격리 규칙
  platform-dev.md        # 플랫폼(BE/FE) 개발 가이드 (AI와 무엇이 다른가)
```

**AI vs 플랫폼 — 왜 이미지가 다른가**: AI 개발자는 모델을 GPU 에서 직접 돌리므로
torch/CUDA/GPU 가 필수다. 플랫폼(gateway/FE)은 모델을 안 돌리고 **AI 서비스를 HTTP 로
호출**할 뿐이라 GPU·torch 가 불필요하고, 대신 FE 용 **Node.js** 가 필요하다. 그래서
플랫폼은 CUDA 없는 경량 base(`pia/pf-base`) + GPU 미할당으로 발급한다(놀리는 GPU 점유
방지). 상세는 [`docs/platform-dev.md`](docs/platform-dev.md).

3층 구조: **admin(sudo) = 발급·관리 → 개발자 Unix 계정 = SSH 진입점 → 컨테이너 = 실제 작업 환경**

팀 합의 (2026-08-14):
- 환경 관리자는 **conda** (Miniforge — Anaconda 리포 상용 라이선스 이슈 회피).
  기본 env `dev` 제공, 개발자가 자기 env 추가 자유 (`/opt/conda` 본인 소유).
- **weights 는 전 계정 공유**: 호스트 `/data/weights` → 컨테이너 `/weights` (rw).
- **공유 AI 라이브러리**: 호스트 `/data/libs` → 컨테이너 `/libs` (**read-only**, admin 관리).
  개인 홈에 둔 공유 자산(예: QFE)은 여기로 옮긴다 — 홈에서 공유하면 안 된다(§ 아래).
- **GPU 는 일단 전체 공유** (`--gpus all` 기본). 분리가 필요해지면 발급 시
  `gpu-devices` 인자로 제한 가능 — 재발급(`docker rm -f ml-<user>` 후 재실행)만 하면 됨.
- 접속은 비밀번호 없이 **SSH 공개키만** (계정 비밀번호는 잠금 상태).

## 온보딩 (admin이 42 서버에서)

```bash
# AI(ML) 개발자 — GPU 컨테이너 ml-<user>
sudo ./scripts/provision_ml.sh dhkim keys/dhkim.pub        # GPU 전체 공유 (기본)
sudo ./scripts/provision_ml.sh mkim  keys/mkim.pub  2,3    # 특정 GPU 만

# 플랫폼(BE/FE) 개발자 — GPU 없는 컨테이너 pf-<user> (+ 서비스 네트워크 연결)
sudo ./scripts/provision_pf.sh jihoon keys/jihoon.pub
```

개발자 접속 동선:

```
ssh dhkim@<42서버>  →  docker exec -it ml-dhkim bash   (conda dev env 자동 활성화)
VS Code: Remote-SSH 접속 → "Dev Containers: Attach to Running Container" → ml-dhkim
```

## GPU 운영 정책

GPU 4장을 **개발 공유(0) · 서비스(1) · 학습 전용(2,3)** 으로 분할한다.
할당의 단일 원천은 👉 [`docs/gpu-allocation.md`](docs/gpu-allocation.md).

- 격리는 **컨테이너 레벨**(`--gpus device=N`)에서 강제. 컨테이너 안
  `CUDA_VISIBLE_DEVICES` 는 합의일 뿐 강제가 아니다.
- ⚠️ 현행 dev 컨테이너는 `--gpus all` 로 발급돼 있어 정책과 불일치 — `device=0`
  으로 재발급 필요 (gpu-allocation.md "전환 메모"). M3 검증 전 서비스 GPU 분리 필수.

## 이미지 관련 메모

- 베이스는 `nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04` (Docker Hub 공개 이미지).
  서버 드라이버가 지원하는 CUDA 버전 확인: `nvidia-smi` 우상단 "CUDA Version" ≥ 12.4.
  낮으면 `Dockerfile.ml-base` 의 태그와 `environment.ml.yml` 의 `cu124` 를 함께 내릴 것.
- conda 활성화: 홈이 호스트 볼륨으로 덮여서 이미지에 구운 `~/.bashrc` 는 무효.
  provision 스크립트가 **호스트 ~/.bashrc 에 guarded snippet** 을 넣는다
  (`/opt/conda` 존재할 때만 발동 → 호스트 셸에는 영향 없음).
- 컨테이너 자체 레이어에 conda env 를 굽는 대신 개발자가 추가로 만드는 env 는
  `/opt/conda/envs/` (컨테이너 레이어)에 생긴다 — **컨테이너를 rm 하면 사라진다.**
  오래 쓸 env 는 `conda env export > ~/work/envs/<name>.yml` 로 홈에 백업할 것.

### 2단 이미지 (개발자별 발급이 항상 빠른 이유)

이미지를 둘로 나눈다:
- **`pia/ml-base`** — 무거운 부분(apt·miniforge·conda). `build_ml_base.sh` 로 **1회** 빌드.
- **`pia/ml-<user>`** — `FROM pia/ml-base` + 계정 한 개. 발급마다 **~1초**.

per-user 빌드가 실재하는 이미지(`pia/ml-base`)에 의존하므로, **build cache 상태와
무관하게** 항상 빠르다 (레이어 캐시에만 의존하던 예전 방식은 `docker builder prune`
한 번이면 다음 발급이 다시 수 분이었다).

운영:
```bash
# 최초 1회 (또는 environment.ml.yml 변경 시) — 무거운 conda 설치, 수 분
sudo ./scripts/build_ml_base.sh

# 이후 개발자 발급 — pia/ml-base 위에 useradd 만, ~1초
sudo ./scripts/provision_ml.sh <user> keys/<user>.pub 0
#   (pia/ml-base 가 없으면 provision 이 build_ml_base.sh 를 자동 호출한다)
```
- `environment.ml.yml` 변경 → `build_ml_base.sh` 재실행. 이후 발급되는 컨테이너에 반영된다
  (기존 컨테이너는 재발급해야 새 base 를 받는다).
- ⚠️ `docker image prune -a` 는 컨테이너가 직접 쓰지 않는 `pia/ml-base` 태그를 지울 수
  있다. 지워져도 다음 발급 때 자동 재빌드되지만(레이어 캐시 있으면 빠름), 되도록 남길 것.
- 개발자는 자기 컨테이너 안에서 `pip install`·`conda install` 가능(conda 트리가
  mlteam group-writable). copy-on-write 라 다른 개발자 컨테이너엔 영향 없다.

## 서비스 스택 공존 (42 = dev 배포 서버 겸용)

같은 호스트에 PIA Scope dev 스택(`piascope-*` 12개 컨테이너: gateway 3100 ·
scope UI 3401 · ssave 8001/8002 · PG 3120 · Redis 3130 · ES 3140 · MLflow 3150 ·
MediaMTX 316x · Prometheus 3170 · Milvus 3110/3111)이 상시 기동 중이다.

- ⭐ **공용 인프라 규칙**: [`docs/shared-infra-rules.md`](docs/shared-infra-rules.md) —
  "읽기는 자유, 쓰기는 `dev_<user>` 격리". 인덱싱/마이그레이션이 데모 Milvus/PG 를
  오염시키지 않게 강제하는 규칙(전 컨테이너 적용).
- 개발자 수칙은 [`docs/ONBOARDING.md`](docs/ONBOARDING.md) §4 — piascope-* 조작 금지 ·
  prune 금지 · GPU 사용 선언 · 포트 개방 금지 · 호스트에서 compose 직접 실행 금지.
- **리소스 상한 합계 관리**: `provision_ml.sh` 의 CPUS/MEMORY 기본값 × 인원수가
  호스트 용량을 넘지 않게 조정할 것 (넘으면 OOM killer 가 ES/Milvus 를 먼저 잡는다).
- **디스크**: conda env·이미지·실험 산출물이 쌓이면 ES 가 read-only 로 전환된다
  (watermark 85/90/95%). `df -h` 주기 확인 + 정리는 admin 만
  (`docker image prune` 은 필터와 함께, `--volumes` 절대 금지).
- **M3 검증 기간(8/19~8/28)**: 완성 판정에 이 스택이 쓰이므로 GPU 를 실제로 분리
  운영하는 걸 권장 — 서비스용 GPU 를 정하고 dev 컨테이너를 `gpu-devices` 인자로
  재발급.

## 공유 자산은 홈이 아니라 공용 경로에 (`/data/*`)

개인 홈(admin 포함)에 둔 자산은 다른 개발자·컨테이너가 접근할 수 없다 — 홈은 권한이
막혀 있고 남의 홈은 컨테이너에 마운트되지 않는다. 공유해야 할 자산은 `/data/` 아래
공용 경로로 옮기고 컨테이너에 마운트한다:

| 호스트 | 컨테이너 | 성격 | 소유/권한 |
|---|---|---|---|
| `/data/weights` | `/weights` | 모델 weight (전원 rw) | `root:mlteam` 2775 |
| `/data/libs` | `/libs` (**ro**) | AI 라이브러리(QFE 등, admin 관리) | `root:mlteam` 2775, 컨테이너선 :ro |
| `/data/datasets` | `/datasets` (ro) | 데이터셋 | 읽기 전용 |

**예: admin 홈의 `QFE_v1.1.3` 를 공유로 이관** (admin 이 1회):
```bash
sudo mkdir -p /data/libs
sudo mv ~/QFE_v1.1.3 /data/libs/
sudo chown -R root:mlteam /data/libs/QFE_v1.1.3
sudo chmod -R g+rX /data/libs/QFE_v1.1.3        # mlteam 읽기+디렉터리 진입
# 기존 컨테이너는 재발급해야 /libs 마운트가 붙는다(마운트는 실행 중 추가 불가):
#   sudo docker rm -f ml-<user> && sudo ./scripts/provision_ml.sh <user> keys/<user>.pub <gpu>
```
개발자는 컨테이너 안에서 `/libs/QFE_v1.1.3` 로 접근(읽기 전용). import 는 PYTHONPATH
또는 자기 env 에 `pip install -e` (상세: `docs/ONBOARDING.md` §3).

> ⚠️ 마운트는 **컨테이너 생성 시점에만** 추가된다. `/data/libs` 를 새로 만들었으면
> 기존 컨테이너들은 **재발급**해야 `/libs` 가 보인다(홈은 bind-mount 라 코드는 보존).

## 그룹·소유권 모델 (mlteam 기본)

신규 개발자 계정의 **기본 그룹(primary group) = `mlteam`** (고정 GID 2000).
`provision_ml.sh` 가 자동으로:
- 홈(=워크스페이스)을 `mlteam` 그룹 + setgid 로 → 생성 파일이 mlteam 그룹 상속.
- `/data/weights` 를 `root:mlteam` `2775` 로 → 팀원 모두 rw, 새 파일도 mlteam 유지.
- 컨테이너 primary group 을 같은 GID(2000)로 → `/home`·`/weights` bind-mount
  소유권이 호스트와 정확히 일치.

이유: 예전엔 계정마다 private 그룹이라 공유물이 사실상 admin(root) 소유로만 관리됐다.
mlteam 을 기본으로 두면 **admin 없이도 팀원끼리 워크스페이스·weight 를 공유·협업**할 수 있다.

⚠️ **오해 방지**: mlteam 은 *파일 공유* 그룹이다. **docker 그룹 = 호스트 root 등가**라는
사실은 그대로다 — mlteam 으로 바꿔도 권한이 줄지 않는다(권한 축소는 rootless docker 등
별도 작업, 아래 보안 절).

**기존 계정 정렬**: 스크립트를 다시 돌리면 기존 계정의 primary group 도 mlteam 으로
맞춰지지만, **이미 만들어둔 파일의 그룹은 그대로**다. 필요하면 한 번 마이그레이션:
```bash
sudo find /home/dhkim -not -group mlteam -exec chgrp mlteam {} +   # dhkim 예시
# dhkim 은 GPU/그룹 정렬을 위해 컨테이너 재발급 권장:
sudo docker rm -f ml-dhkim && sudo ./scripts/provision_ml.sh dhkim keys/dhkim.pub 0
```
공유 write 를 자주 한다면(같은 파일을 여러 명이 수정) 개발자 셸 `umask 002` 를 권장
(기본 022 는 그룹에 read 만 준다). 서로 다른 파일을 만드는 일반적 경우엔 불필요.

## 보안 메모 (합의된 트레이드오프)

- **docker 그룹 = 호스트 root 등가.** 개발자 전원이 서로의 컨테이너·호스트에
  접근 가능하다. 10인 신뢰 팀 전제의 절충이며, 격리가 필요해지면
  rootless docker 또는 admin 발급 전용(sudoers 로 `docker exec` 만 허용)으로 전환.
- 계정은 비밀번호 잠금 + SSH 키 인증만. 오프보딩 = `deprovision.sh`.
- 42 서버가 사내망 전용이 아니라면 SSH 포트 공개 대신 VPN/Tailscale 경유 권장.

## 라이선스 메모

- `ultralytics` 는 **AGPL-3.0** — 서비스 리포 CLAUDE.md §10 기준 Enterprise
  License / Roboflow sub-license 전제. 개발 환경 포함은 문제없으나 배포물에
  섞일 때 조건 확인.
- conda 는 Miniforge + conda-forge 채널만 사용 (Anaconda `defaults` 채널은
  상용 조직 유료 — 실수로 `-c defaults` 쓰지 않기).

## 다음 단계 (합의된 로드맵)

1. ✅ 계정 분리 + 개발자별 컨테이너 + VS Code attach (이 리포)
2. `.devcontainer/devcontainer.json` 을 서비스 리포에 추가해 attach 후 확장/설정 자동화
3. GPU 경합 발생 시 개발/학습 GPU 풀 분리 + DCGM-exporter 모니터링
4. 학습 잡 대기가 병목이 되면 스케줄러(Slurm/Ray) 도입 검토
