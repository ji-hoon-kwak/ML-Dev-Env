# 플랫폼(BE/FE) 개발 가이드

플랫폼 개발자(Gateway·FE)가 42 서버의 `pf-<user>` 컨테이너에서 개발하는 방법.
AI(ML) 개발자와 **무엇이 다른지**부터 정리한다.

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

## 개발 흐름 (컨테이너 안)

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
