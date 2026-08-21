# 공용 인프라 사용 규칙 (42 서버)

42 서버는 **PIA Scope 데모/검증 스택(`piascope-*`) + 전원 dev 컨테이너**가 한 호스트에
공존한다. 이 인프라(Milvus·PG·ES·Redis·MediaMTX·MLflow)는 **공유 자원**이며, 데모/M3
검증에 그대로 쓰인다. 아래 규칙은 `ml-`·`pf-` 컨테이너 **전원**에 적용된다.

## 0. 대원칙 — "읽기는 자유, 쓰기는 격리"

- 공유 인프라의 **상태(데이터)를 오염시키지 않는다.** 조회·검색(읽기)은 공유해도 되지만,
  **insert/update/drop/migration(쓰기)은 반드시 본인 격리 네임스페이스**에서.
- `piascope-*` 컨테이너·볼륨은 건드리지 않는다 (stop/rm/restart/prune 금지).

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
  개발은 컨테이너 안에서.
- 새 포트 개방은 admin 포트 대장 확인 후. 데모 점유: gateway 3100 · UI 3401 ·
  ssave 3101/3102 · trace-api 3001 · PG 3120 · Redis 3130 · ES 3140 · Milvus 3110/3111 ·
  MediaMTX 316x · MLflow 3150 · Prometheus 3170.

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
