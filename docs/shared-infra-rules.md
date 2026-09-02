# 공용 인프라 사용 규칙 (42 서버)

42 서버는 **PIA Scope 데모/검증 스택(`piascope-*`) + 전원 dev 컨테이너**가 한 호스트에
공존한다. 이 인프라(Milvus·PG·ES·Redis·MediaMTX·MLflow)는 **공유 자원**이며, 데모/M3
검증에 그대로 쓰인다. 아래 규칙은 `ml-`·`pf-` 컨테이너 **전원**에 적용된다.

## 0. 대원칙 — "상태를 쓰는 의존은 내 컨테이너 안, 공유는 읽기전용 예외"

격리의 축은 **연산 비용이 아니라 상태·이벤트 소유권**이다. 기준은 하나:

> 내가 테스트하는 서비스가 그 인프라에 **쓰는가(produce/mutate)**, **읽기만 하는가**.

- **쓰는 의존(Redis Streams·PG·인덱싱 대상) → 반드시 내 컨테이너 안** (`devstores up`).
  공유에 물리면 내 테스트 이벤트가 데모/남의 것과 섞이고, at-least-once Redis 그룹에서
  남의 메시지를 훔쳐 ACK 하며, FLUSHALL/truncate 로 리셋도 못 한다(독립 라이프사이클 불가).
- **읽기전용·외부 소유 의존만 공유** (예: RTSP 입력 소스, 조회용 Milvus, 공유 AI서비스
  HTTP). 이 경우에만 `EGRESS_NETWORK` 로 공유망에 연결한다.
- `piascope-*` 컨테이너·볼륨은 건드리지 않는다 (stop/rm/restart/prune 금지).
- ⭐ **호스트에 개인 인프라를 sibling 컨테이너로 띄우지 않는다** — 그게 `piascope-jordan-*`
  같은 꼬임의 원인이었다. 개발자에겐 호스트 docker 권한이 없다(설계상 불가).
- ⭐ **네트워크로도 공유 인프라에 못 닿는다** — 개발 컨테이너는 `devnet` egress 방화벽으로
  사설망·호스트가 차단돼(인터넷만 허용), 공유 PG/Redis/Milvus 에 raw IP 로도 접근 불가
  (`scripts/devnet_firewall.sh`). 즉 "실수로 데모 데이터에 쓰기"가 구조적으로 막힌다.
  읽기전용 공유 의존이 정말 필요하면 `EGRESS_NETWORK` 로 명시 연결한 그 트래픽만 예외.

## 0-bis. 무엇을 내 컨테이너 안에, 무엇을 공유(읽기)로

| 분류 | 대상 | 방침 | 이유 |
|---|---|---|---|
| **컨테이너 안 (쓰기)** | **PostgreSQL · Redis** | `devstores up` — 컨테이너 안 로컬 프로세스 | 가볍다 · 쓰기/마이그레이션/리셋이 잦아 독립 라이프사이클 필수 |
| **읽기 공유 (선택 egress)** | **Milvus · Elasticsearch** | 대량 인덱싱이 없으면 공유 canonical 을 **읽기**로. 쓰면 컨테이너 안/개인 인스턴스 | 무겁고(수 GB) canonical 데이터 재인덱싱 비용 큼 — 조회만이면 공유가 이득 |
| **반드시 공유 (읽기)** | **MediaMTX+RTSP · GPU · AI서비스(scene/fg/trace) · Prometheus** (MLflow 권장) | 개인별로 포크 안 함 | RTSP=입력 소스가 공유 자원 · GPU=유한 하드웨어 · AI서비스=GPU+모델 메모리 · Prometheus=관측 싱글턴 |

**개인 PG/Redis 띄우기** — ⭐ 컨테이너 '안'에서 (ssh 로 컨테이너 접속 후):
```bash
devstores up          # 127.0.0.1:6379(redis) · 127.0.0.1:5432(pg, db=dev)
devstores info        # 접속 정보
devstores status      # 실행 여부
devstores down        # 중지(데이터 보존) · reset = 데이터까지 삭제
```
애플리케이션 config 를 `127.0.0.1:5432`·`127.0.0.1:6379` 로 가리키면 끝. 공유 Milvus/ES 는
읽기로 재사용하되(필요 시 `EGRESS_NETWORK` 연결), 쓰기는 컨테이너 안/`dev_<user>` 로.

## 1. 저장소별 규칙 (쓰기 격리 방법)

| 인프라 | 읽기 | 쓰기(개발) | 격리 방법 |
|---|---|---|---|
| **Milvus** (벡터) | 공유 컬렉션 조회 OK | 데모 컬렉션 insert/drop **금지** | 본인 컬렉션 `dev_<user>_*` 생성해서 사용 · 또는 개인 Milvus |
| **PostgreSQL** | 공유 조회 OK | 데모 DB 쓰기·마이그레이션 **금지** | 본인 DB `dev_<user>` (`createdb`) · 또는 개인 PG |
| **Elasticsearch** | 공유 조회 OK | 데모 인덱스 쓰기 **금지** | 본인 인덱스 접두사 `dev-<user>-*` |
| **Redis Streams** | — | 데모 스트림 **consume/ACK 금지** | 본인 스트림 키 접두사 (at-least-once라 남의 메시지 ACK하면 데모가 굶는다) |
| **MediaMTX** (RTSP) | 데모 스트림 조회 OK | 데모 경로 덮어쓰기 **금지** | 본인 경로명 `dev_<user>/...` 선등록 |
| **MLflow** | 공유 OK | append-only라 공유 OK | 단 **본인 experiment 이름**으로 기록 |

> ⭐ 네임스페이스 접두사(컬렉션/DB/인덱스/스트림/RTSP 경로)는 `dev_<user>` 로 통일 권장.
> 쓰기가 본격적이면(스키마 변경·대량 인덱싱) 아예 **개인 인스턴스**를 띄운다(가벼운 PG/Redis).

## 2. GPU

- [`gpu-allocation.md`](gpu-allocation.md) 준수: 개발 공유(0) / 서비스(1) / 학습 전용(2,3).
- 1시간+ GPU 점유 학습은 `#piaspace-dev` 선언 후 **학습 전용 GPU**에서.
- `CUDA_VISIBLE_DEVICES`로 본인 몫만. 서비스 GPU(trace-worker 등)·타인 GPU 침범 금지.

## 3. 리소스 (호스트 공유)

- 대용량 파일은 홈이 아니라 `/datasets`(admin)·`/weights`. 디스크가 차면 ES가
  read-only(watermark 85%)로 전환돼 **데모 검색이 조용히 죽는다** — `df -h` 주기 확인.
- `docker system/volume/builder prune` **금지** (정리는 admin; build cache 보존).
- CPU/메모리 상한은 provision 기본값을 따른다(임의 상향 금지 — OOM이 ES/Milvus를 먼저 잡음).

## 4. 코드·포트

- 호스트에서 서비스 리포 `docker compose up` **직접 실행 금지** (배포 스택과 포트 충돌).
  개발은 컨테이너 안에서. ⭐ 이제 개발자에겐 호스트 docker 권한이 없어 **구조적으로 불가**하다
  (호스트 daemon 조작·sibling 컨테이너 발급 자체가 막힘 — 옛 `piascope-jordan-*` 재발 방지).
- 새 포트 개방은 admin 포트 대장 확인 후. 데모 점유: gateway 3100 · UI 3401 ·
  ssave 3101/3102 · trace-api 3001 · PG 3120 · Redis 3130 · ES 3140 · Milvus 3110/3111 ·
  MediaMTX 316x · MLflow 3150 · Prometheus 3170. **dev 컨테이너 sshd = 2200~2299**(개인별 1개).
- 개인 테스트 저장소(`devstores`)는 컨테이너 안 127.0.0.1 에만 바인드 → 호스트 포트를
  먹지 않는다(개인별 포트 배정 불필요).

## 5. 🔴 M3 검증 기간(2026-08-19 ~ 08-28) 강화

완성 판정에 `piascope-*` 스택이 쓰이므로 이 기간엔:
- 공유 상태 저장소(**Milvus·PG·ES**)에 **쓰기 전면 금지** — 전원 개인 격리 인스턴스/네임스페이스.
- 서비스 GPU(1) **물리 분리** 유지. 개발 학습 잡의 VRAM 경합으로 trace-worker OOM 금지.

## 6. 위반·사고 시

- 데모 데이터 오염 / 서비스 다운 징후 → **즉시 `#piaspace-dev` 공지 + admin(@jhkwak)**.
- 조작 이력이 필요하니 어떤 명령을 돌렸는지 함께 공유.

---

**요지**: 인프라는 공유하되 **내가 쓰는 데이터는 `dev_<user>` 로 격리**한다. 읽기는 자유,
쓰기는 격리 — 이 한 줄이 데모/검증과 개발을 한 호스트에서 공존시키는 핵심이다.
