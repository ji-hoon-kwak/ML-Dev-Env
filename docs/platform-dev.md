# 플랫폼(BE/FE) 개발 가이드

플랫폼 개발자(Gateway·FE)의 개발 방법. AI(ML) 개발자와 **무엇이 다른지**부터 정리한다.

> ⭐ **PF 기본 워크플로우 = 로컬(맥) 우선 + SSH 터널** (§로컬 우선 워크플로우).
> `pf-` 컨테이너는 필수가 아니라 **비상구**다(Linux 재현·심층 디버깅용).
> ML 은 GPU 때문에 컨테이너가 필수지만, PF 는 로컬이 Conductor 등 생산성 도구를
> 그대로 쓸 수 있어 우선이다.

## AI(ML) vs 플랫폼(PF) — 근본 차이

| | AI(ML) 개발자 | 플랫폼(PF) 개발자 |
|---|---|---|
| 하는 일 | 모델을 **GPU에 올려** 추론/학습 (검출·추적·임베딩·인덱싱·검색) | HTTP 라우팅·인증·집계(Gateway), 화면(FE) |
| 모델 | 직접 로드 | **직접 안 함** — AI 서비스를 HTTP 호출 |
| 필요 | GPU·CUDA·torch·모델 wheel | Python(FastAPI) + **Node(Next.js)**. GPU·torch **불필요** |
| 컨테이너 | `ml-<user>` (GPU 할당) | `pf-<user>` (**GPU 없음**) |
| 이미지 | `pia/ml-base` (cuda+torch) | `pia/pf-base` (경량, node) |

핵심: 플랫폼 코드는 모델을 절대 로드하지 않고 `http://…ssave-scene:8001` 같은 URL로
AI 서비스를 부른다(원칙 3, Pluggable Models 경계 바깥). **GPU는 AI 서비스 쪽에만** 있다.

## 인프라 모델 — "내 컨테이너 안"이 아니라 "옆에서 공유"

인프라(postgres·redis·milvus·ES·mediamtx)는 dev 컨테이너 **안에서 띄우지 않는다**.
별도 컨테이너(이미 뜬 `piascope-*` 스택)로 돌고, 내 코드가 **네트워크로 접근**한다.

- **공유(무겁고 읽기 위주)**: Milvus·ES·MediaMTX·MLflow, 그리고 AI 서비스(scene/fg/trace).
- **개인(내가 쓰기·마이그레이션)**: 필요 시 Postgres·Redis 를 개인용으로(가벼움).
- **내가 고치는 것만 실행**: gateway 또는 FE, dev 전용 포트로.

`provision_pf.sh` 는 `pf-` 컨테이너를 piascope **서비스 네트워크에 자동 연결**하므로,
배포 스택과 똑같이 **서비스명**(`postgres:5432`·`piascope-ssave-scene:8001`…)으로 접근할 수 있다
→ 배포 `.env.dev` 를 거의 그대로 재사용.

## ⭐ 로컬 우선 워크플로우 (PF 기본)

코드·에이전트(Conductor)·실행 전부 **맥 로컬**. 42 의 인프라·AI 서비스만 SSH 터널로
로컬처럼 붙인다. scope(FE)·gateway 개발에 인프라가 발목 잡지 않게 하는 구성.

**1) `~/.ssh/config` 의 gpu42 블록에 터널 추가:**
```
Host gpu42
    HostName 10.128.30.42
    User <본인계정>
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
    ExitOnForwardFailure yes
    # --- PF 인프라 터널 (ssh 켜두면 전부 localhost 로 보임) ---
    LocalForward 3101 localhost:3101   # ssave-scene
    LocalForward 3102 localhost:3102   # ssave-fg
    LocalForward 3001 localhost:3001   # trace-api
    LocalForward 3110 localhost:3110   # milvus (읽기)
    LocalForward 3140 localhost:3140   # elasticsearch (읽기)
    LocalForward 3170 localhost:3170   # prometheus (GPU 서비스 상태 점검)
```
터널만 유지: `ssh -N gpu42` (셸 없이 포워딩만 · 끊기면 재실행).

**2) 로컬 gateway** — `.env` 에 터널 주소 + 배포 시크릿:
```
SSAVE_SCENE_URL=http://localhost:3101
SSAVE_FG_URL=http://localhost:3102
TRACE_API_URL=http://localhost:3001
INTERNAL_SERVICE_SECRET=<배포 .env.dev 와 동일값>   # fail-closed — 다르면 502/401
DATABASE_URL=postgresql://...@localhost:5432/...     # ⬇ 로컬 PG (아래 3)
```

**3) 쓰기 저장소(PG·Redis)는 맥 로컬 Docker 로** — 공유 데모 DB 오염 방지(쓰기 격리).
가벼우니 Docker Desktop 으로 `postgres:16-alpine`·`redis:7-alpine` 띄우면 끝.
Milvus/ES 는 로컬로 안 띄우고 터널 너머 공유를 **읽기만**.

**4) FE(scope) 는 CORS 를 원천 차단** — 브라우저가 cross-origin 을 직접 치지 않게,
**same-origin 프록시**를 경유시킨다 (CORS 는 브라우저→타 origin 직접 호출에서만 발생;
서버↔서버 호출엔 없음):
```js
// next.config.js (dev): 브라우저는 항상 localhost:3401 만 본다
async rewrites() {
  return [{ source: '/api/:path*', destination: 'http://localhost:3100/api/:path*' }];
}
```
gateway 를 로컬 3100 에 띄우든, 원격 gateway 를 `LocalForward 3100` 으로 당기든
rewrites 목적지는 동일하게 localhost — 어느 쪽이든 CORS 소멸.

**5) 실스택 검증** — 로컬에서 되면 증분 재배포 스크립트로 42 에 밀어넣고 smoke check.
환경을 옮겨 다니지 않는다(소스오브트루스 = 로컬 git 하나).

## 개발 흐름 (컨테이너 안 — 비상구 경로)

```bash
docker exec -it pf-<user> bash          # conda dev env 자동 활성화 (python + node)
git clone <repo>; cd TRACE_SSAVE-AI-MVP

# Gateway (light 설치 — torch 없음)
pip install -e .
uvicorn gateway.api.main:app --host 0.0.0.0 --port 3105 --reload

# FE
cd ui/apps/scope && npm install && npm run dev -- --port 3405
```

- 브라우저 확인은 **VS Code Remote-SSH 포트 포워딩**으로 자동(컨테이너에 `-p` 안 열어도 됨).
- 포트는 배포 스택과 겹치지 않게: gateway 3100·UI 3401·ssave 3101/3102·trace-api 3001 **회피**
  (예: gateway 3105, FE 3405).

## 인프라 연결값

**서비스 네트워크 연결 시(권장)** — 서비스명 사용, `.env.dev` 재사용:
`postgres:5432` · `redis:6379` · `elasticsearch:9200` · `milvus:19530` ·
`piascope-ssave-scene:8001` · `piascope-ssave-fg:8002` · `piascope-trace-api:8001`

**네트워크 미연결(호스트 IP+공개포트) 폴백**:
| 대상 | URL |
|---|---|
| Postgres | `10.128.30.42:3120` |
| Redis | `10.128.30.42:3130` |
| Elasticsearch | `10.128.30.42:3140` |
| Milvus | `10.128.30.42:3110` |
| ssave-scene | `http://10.128.30.42:3101` |
| ssave-fg | `http://10.128.30.42:3102` |
| trace-api | `http://10.128.30.42:3001` |

⚠️ **`INTERNAL_SERVICE_SECRET`** + `SSAVE_SCENE_URL`·`SSAVE_FG_URL`·`TRACE_API_URL` 은
배포 `.env.dev` 값을 재사용해야 gateway→scene/fg/trace 호출이 통과한다(fail-closed).

## ⚠️ M3 검증 기간(8/19~8/28) 안전장치

`piascope-*` 스택은 **완성 판정에 쓰이는 바로 그 스택**이다. 이 기간엔 플랫폼 개발이
**공유 PG/Milvus 에 쓰기 금지** — 개인 Postgres/Redis 로 격리하고, 공유는 읽기만.

## 발급 (admin)

```bash
sudo ./scripts/provision_pf.sh <user> keys/<user>.pub
# pia/pf-base 없으면 자동 빌드(최초 수 분). 이후 발급은 ~1초.
```
