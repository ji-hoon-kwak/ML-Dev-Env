# Suprema 얼굴 SDK — dev 환경 공유 (조사 기록 + 현재 결론)

> 대상: 42 서버 dev 컨테이너들이 Suprema 얼굴 인식을 **동일하게** 쓰게 만드는 방법.
> 최초 2026-08-19 (jh.kwak). ⚠️ **2026-08-20 대폭 개정** — 초기 전제("모든 컨테이너에
> data.conf 마운트")가 SDK 설계와 어긋남을 확인, 방향을 **HTTP 엔드포인트 공유**로 정정.
> 근거 = 레포 `TRACE_SSAVE-AI-MVP` 의 `scripts/face/qfe_http_server/README.md` ·
> `infra/configs/identity.yaml` · `piapf/face/suprema_adapter.py` · ADR-023.

---

## ⭐ 현재 결론 (TL;DR)

- **Suprema QFaceEngine 은 노드락된 in-process C++ 라이브러리로, 라이선스된 머신에서만 돈다.**
  임의 컨테이너/호스트에서 초기화 불가. → **컨테이너 안에서 InitSDK 직접 호출은 노드락으로 실패한다**
  (minkyung 이 본 `InitSDK -5` = 라이선스 계열 에러의 정체).
- 설계상 SDK 는 **라이선스 호스트에서 `qfe_http_server` 프로세스 하나**로 뜨고(loopback
  127.0.0.1:18080), **나머지 전부는 HTTP 클라이언트**다. TRACE identity·SSAVE 얼굴 필터는
  SDK 를 직접 안 돌리고 **`SUPREMA_ENDPOINT` 환경변수만** 본다(`identity.yaml`).
- **라이선스가 인스턴스 4개로 제한**된다(`--instances`, `/health` 가 실제 생성 수 보고).
  → 10명에게 각자 SDK 를 줄 수 **없다**. 공유가 선택이 아니라 사실상 강제.
- **∴ dev 컨테이너가 필요한 건 라이선스 파일(data.conf)이 아니라 `SUPREMA_ENDPOINT`(서버 URL)다.**
  data.conf 마운트는 **일반 개발 용도로는 잘못된 계층**이다(노드락 때문에 마운트해도 in-container
  InitSDK 는 통과 안 함). provision_dev.sh 의 data.conf 마운트는 **엔드포인트 주입으로 대체 예정**
  (아래 §5, 검증 후).

---

## 1. 조사로 확정된 파일 상태 (2026-08-19~20)

| 위치 | 소유/권한 | 크기 | md5 | 정체 |
|---|---|---|---|---|
| (옛) `/data/libs/qfe_home/data.conf` 초기 | — | 4360B | `3f38dc13` | minkyung `qfe_setup --check` 가 만든 **빈 스켈레톤**(활성화 없음) |
| `/data/libs/qfe_home/data.conf` 현재 | `root:mlteam` 0640 | 15240B | `6a6e4f92` | gpuadmin 활성화본이 여기 복사됨(공유 원본 후보) |
| gpuadmin 홈 `~/.local/.../data.conf` | uid1000:mlteam rw | 15240B | `6a6e4f92` | gpuadmin 활성화본(원본) |
| minkyung 컨테이너 `~/.local/.../data.conf` | minkyung:mlteam rw | 15240B | `4f82a316` | **minkyung 의 별개 활성화본**(gpuadmin 것과 내용 다름) |
| dev-jihoon 마운트 | `docker inspect` → `/home/gpuadmin/.local/.../data.conf → :ro` | | | **구버전 스크립트**로 만든 컨테이너(소스가 gpuadmin 홈, `/data/libs` 아님) |

**해석**:
- 활성화본이 **최소 2개**(gpuadmin `6a6e4f92`, minkyung `4f82a316`) — 내용이 서로 다름 →
  Suprema 활성화가 **인스턴스/시트마다 고유**함을 시사. "복사 한 방으로 전원 공유"가 안 되는 이유.
- 컨테이너 SDK 경로는 **심볼릭 링크가 아니라 실제 파일**(minkyung 은 자기 활성화본, jihoon 은 구
  스크립트의 :ro 마운트). 초반 "symlink" 는 이후 실파일로 바뀐 상태.
- **마운트 배관 자체는 정상 작동**함을 dev-jihoon 에서 확인(`docker inspect` 로 `:ro` 확인). 문제는
  배관이 아니라 "무엇을/어디서 초기화하느냐".

---

## 2. 왜 "자기 홈 심볼릭 링크"도 "컨테이너별 data.conf 마운트"도 정답이 아닌가

- **홈 symlink**: 각 컨테이너는 그 유저 홈만 bind 하므로, minkyung 홈의 링크는 minkyung 컨테이너
  에서만 보인다 → 사람마다 수동, 확장 불가.
- **data.conf 마운트(초기 접근)**: 배관은 되지만 **노드락**이 막는다. 컨테이너는 라이선스 머신
  정체성이 아니라, 진짜 활성화 내용을 넣어도 in-container InitSDK 가 `-5` 로 거부될 수 있다.
  게다가 **4-인스턴스 제한**이라 컨테이너마다 SDK 를 띄우는 모델 자체가 라이선스 위반.

---

## 3. 올바른 아키텍처 (레포 설계 = ADR-023)

```
[라이선스 호스트 = 42, gpuadmin 활성화]
   qfe_http_server  (C 프로그램, scripts/face/qfe_http_server/qfe_http_server.c)
     · source /data/libs/qfe_license/env.sh   ← 런타임 라이선스 로딩(진짜 활성화 지점)
     · QFE_ROOT=/data/libs/QFE_v1.1.3          ← SDK/모델/헤더/라이선스 설치처(레포 밖)
     · --db /data/libs/facedb/face_database.db
     · bind 127.0.0.1:18080 (기본, loopback 전용 — OPS-012)
     · 라우트 /health /identify /detect /enroll(기본 off)
        ▲ HTTP
        │  SUPREMA_ENDPOINT=http://<host>:18080
   [dev 컨테이너들 = HTTP 클라이언트]
     identity.yaml: identity.suprema.endpoint: ${SUPREMA_ENDPOINT}
     piapf/face/suprema_adapter.py 가 이 URL 로 이미지 전송 (SDK 직접 링크 안 함)
```

- **"활성화 확인"의 진짜 명령** = `qfe_setup` 이 아니라 **서버 `/health`**:
  `curl -s 127.0.0.1:18080/health` → `{"status":"ok","sdk":"1.1.3","max_instance":4,...}` 면 InitSDK 통과.
- 어댑터는 import-linter 로 격리됨(`ssave`/`trace` 가 직접 import 금지, ADR-023) — 벤더 교체는
  이 한 파일 + 엔드포인트만.

---

## 4. 남은 미검증 / 결정 사항

1. **42 가 라이선스 호스트가 맞는지** — gpuadmin 활성화가 42 에 있으니 유력하나 확인 필요.
2. **`/data/libs/qfe_license/env.sh` · `/data/libs/QFE_v1.1.3` 존재 여부**, 이미 18080 에 서버가
   떠 있는지.
3. ⚠️ **네트워크 토폴로지 결정 (보안 — TICKET-OPS-012)**: 서버는 일부러 **loopback 전용**이다
   ("인증 없는 생체 매처를 네트워크에 열지 말 것"). dev 컨테이너는 별도 netns 라 호스트 127.0.0.1 에
   못 붙는다. 셋 중 택1:
   - 서버를 호스트에 띄우고 컨테이너를 `--network host` (또는 브리지 게이트웨이 IP) — OPS-012 검토.
   - 서버를 컨테이너로 띄워 dev 컨테이너와 같은 도커 네트워크에 두기.
   - (인증 붙이기 전엔 네트워크로 넓히지 않는다 — README "What is deliberately NOT here").

### 검증 명령 (42 에서)

```bash
ls -la /data/libs/qfe_license/env.sh /data/libs/QFE_v1.1.3 2>&1
curl -s 127.0.0.1:18080/health 2>&1 || echo "서버 미기동"
# 미기동이면 1회 기동:
cd <repo>/scripts/face/qfe_http_server && ./build.sh
source /data/libs/qfe_license/env.sh
./qfe_http_server --db /data/libs/facedb/face_database.db &
curl -s 127.0.0.1:18080/health
```

---

## 5. provision_dev.sh 처리 방침

- **현재 상태**: `FACE_LICENSE_SRC=/data/libs/qfe_home/data.conf` 를 컨테이너 SDK 경로에 `:ro`
  마운트 + `--group-add MLTEAM_GID`. (2026-08-19 작업.)
- **개정 예정(위 검증 후)**: data.conf 마운트를 **제거/보류**하고, 대신 컨테이너에
  **`SUPREMA_ENDPOINT` 주입**(예: `docker run -e SUPREMA_ENDPOINT=http://<host>:18080` 또는
  `~/.bashrc`/`.env` 경유)으로 바꾼다. dev 컨테이너는 라이선스 파일이 필요 없다.
- **예외**: 얼굴팀이 `qfe_http_server`(C) 자체를 개발/빌드하는 경우엔 QFE_ROOT + env.sh + 노드락이
  필요하나, 이는 **라이선스 호스트에서** 하는 작업이고 4-인스턴스 한도를 공유한다 — 컨테이너 대량
  배포 대상이 아니다.

> ⏳ 급한 개발 단계라 지금은 minkyung 개인 활성화로 굴러가는 상태를 유지. 위 §4 검증이 끝나면
> §5 개정과 함께 이 문서의 "현재 결론"을 확정한다.

---

## 6. ⭐ 우리 선에서 진행하는 실행 계획 (담당자 부재 · 정보만으로 가능)

전제: 42 가 라이선스 호스트(gpuadmin 활성화가 여기 있음). **유일한 미검증 가정 = "42 bare-metal
에서 라이선스가 검증되는가"인데, 이는 아래 Phase 1 로 비파괴적으로 즉시 확인된다**(실패해도 아무것도
안 바뀜). 그래서 담당자 없이도 안전하게 진행 가능.

### Phase 1 — 라이선스가 42 에서 검증되는지 확인 (지금, 비파괴)

```bash
# 설치물 존재 확인 — ls 는 "wrapper 를 돌리는 데 필요한 3개가 실제로 그 경로에 있나"를 보는 것:
#   /data/libs/qfe_license/env.sh          ← 런타임 라이선스 환경(source 대상). 없으면 라이선스 못 읽음
#   /data/libs/QFE_v1.1.3                  ← SDK/모델/헤더 설치처(QFE_ROOT). 없으면 build.sh 실패
#   /data/libs/facedb/face_database.db     ← 갤러리 DB(--db 인자). 없으면 서버 기동 거부(README "must exist")
# 셋 다 존재하면 Phase 1 진행 가능. 하나라도 없으면 그게 첫 blocker(담당자/설치 필요).
ls -la /data/libs/qfe_license/env.sh /data/libs/QFE_v1.1.3 /data/libs/facedb/face_database.db 2>&1

# bare-metal(gpuadmin)에서 wrapper 기동 — 기본 loopback:18080
cd <repo>/scripts/face/qfe_http_server && ./build.sh     # QFE_ROOT=/data/libs/QFE_v1.1.3 기본
source /data/libs/qfe_license/env.sh                     # ← 런타임 라이선스 로딩(필수)
./qfe_http_server --db /data/libs/facedb/face_database.db &

# 활성화 판정 = /health
curl -s 127.0.0.1:18080/health
#   {"status":"ok","sdk":"1.1.3","max_instance":4,...}  → 라이선스 OK · InitSDK 통과 ✅
#   기동 실패/에러코드(-5,-60..)                          → 라이선스/노드락 문제 → §4 로
```

⚠️ `--enable-enroll` 은 절대 켜지 말 것(갤러리 쓰기). identify/detect 만 필요. 빈 갤러리면 모두
`unauthorized` 로 뜨는 건 정상(README) — 라이선스 판정과 별개.

### Phase 2 — 컨테이너가 도달하게 (네트워크 · OPS-012 결정)

wrapper 기본은 loopback 이라 컨테이너(별도 netns)가 못 붙는다. **두 소비자군이 서로 다른 네트워크**에
있다 — dev 컨테이너(provision)는 **default bridge(docker0)**, trace-worker 는 **compose 프로젝트
네트워크**. 그래서 특정 게이트웨이 IP 하나(172.17.0.1)로는 둘 다 못 덮는다. **`host.docker.internal`
+ host-gateway** 로 통일하는 게 정답이다:

```bash
# 호스트의 모든 브리지에서 들리도록 0.0.0.0 바인드 (default·compose 네트워크 모두 도달)
source /data/libs/qfe_license/env.sh
./qfe_http_server --bind 0.0.0.0 --db /data/libs/facedb/face_database.db &
```
그리고 컨테이너는 `http://host.docker.internal:18080` 으로 붙는다(각 컨테이너가 `--add-host
host.docker.internal:host-gateway` 로 자기 네트워크의 호스트 IP 를 얻음). provision_dev.sh 는
`SUPREMA_ENDPOINT_URL` 설정 시 이 `--add-host` 를 자동으로 넣는다.

⚠️ **OPS-012 (반드시)**: `0.0.0.0` 바인드는 **인증 없는 생체 매처를 LAN 에도 노출**한다. **호스트
방화벽으로 18080 을 docker 서브넷에만 허용**하고 외부는 차단할 것:
```bash
# docker 브리지 서브넷만 허용(예시 — 실제 서브넷은 `docker network inspect` 로 확인), 그 외 18080 거부
sudo iptables -I DOCKER-USER -p tcp --dport 18080 ! -s 172.16.0.0/12 -j DROP
# (ufw 사용 시: 172.16.0.0/12 만 allow, 그 외 deny)
```
방화벽을 못 넣는 상황이면 0.0.0.0 대신 **compose 네트워크 게이트웨이로만 바인드**(아래 Phase 3 에서
`docker network inspect <net>` 로 gateway 확인). **이 노출 결정은 담당자 복귀 시 재확인 항목.**

### Phase 3 — 소비자에 `SUPREMA_ENDPOINT` 주입 (라이선스 파일 아님)

**dev 컨테이너** (provision_dev.sh — 우리가 소유, 바로 적용 가능):
```bash
SUPREMA_ENDPOINT_URL="http://host.docker.internal:18080" \
  sudo -E ./scripts/provision_dev.sh <user> keys/<user>.pub
```
`SUPREMA_ENDPOINT_URL` 이 세팅되면 스크립트가 `--add-host host.docker.internal:host-gateway`
+ `-e SUPREMA_ENDPOINT=...` 를 자동 주입한다. 기존 컨테이너는 재발급해야 반영.

**trace-worker** (회사 레포 `docker-compose.server.yml` — ⚠️ 우리가 직접 못 고침, **PR 필요**):
아래 2줄을 trace-worker 서비스에 추가하는 PR 을 올린다.
```yaml
  trace-worker:
    # ...
    extra_hosts:
      - "host.docker.internal:host-gateway"     # 호스트의 wrapper 도달용
    environment:
      # ... 기존 REDIS_HOST 등 ...
      SUPREMA_ENDPOINT: "${SUPREMA_ENDPOINT:-}"  # identity.yaml 의 ${SUPREMA_ENDPOINT} 를 채움
```
그리고 `.env.dev` 에:
```
SUPREMA_ENDPOINT=http://host.docker.internal:18080
```
> trace-worker 는 이미 `./infra/configs:/app/infra/configs:ro` 로 identity.yaml 을 마운트·읽고
> (`scripts/trace/utils/live.py:137` → `build_identity_resolver`), 어댑터가 `${SUPREMA_ENDPOINT}`
> 를 **컨테이너 env 에서** 확장한다. 즉 **위 env 한 줄이면 끝** — 라이선스 파일/마운트 불필요.
> 미설정이면 resolver 가 `None` → identity OFF(추적은 계속, 크래시 아님).

재기동 후 확인:
```bash
docker compose --env-file .env.dev --profile app --profile ai --profile trace \
  -f docker-compose.yml -f docker-compose.server.yml up -d trace-worker
docker logs piascope-trace-worker 2>&1 | grep -iE "identity|SUPREMA|QFE|resolver|T2"
# identity resolver 가 붙으면 성공. "T2 off" / endpoint 관련 경고면 env 확인.
docker exec piascope-trace-worker sh -lc 'echo $SUPREMA_ENDPOINT; curl -s $SUPREMA_ENDPOINT/health'
```

### Phase 4 — 상시 기동 (systemd, 재부팅 생존)

`/etc/systemd/system/qfe-http.service` (gpuadmin 소유 라이선스로 실행):

```ini
[Unit]
Description=Suprema QFE HTTP wrapper (node-locked, licensed host only)
After=network-online.target docker.service

[Service]
User=gpuadmin
# env.sh 를 소싱한 셸로 실행 (라이선스 런타임 로딩)
ExecStart=/bin/bash -lc 'source /data/libs/qfe_license/env.sh && exec /data/libs/qfe_http_server/qfe_http_server --bind 172.17.0.1 --db /data/libs/facedb/face_database.db'
Restart=on-failure
# SIGTERM 로 깨끗이 종료(인스턴스/갤러리/모델 해제 — README)
KillSignal=SIGTERM
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload && sudo systemctl enable --now qfe-http
curl -s 172.17.0.1:18080/health
```
(빌드 산출물 `qfe_http_server` 를 `/data/libs/qfe_http_server/` 로 배치하거나 ExecStart 경로 조정.)

### 이 계획으로 두 조건 충족

- **minkyung 개발**: 자기 컨테이너 `SUPREMA_ENDPOINT` 를 이 공유 wrapper 로 돌리면 개인 활성화·시트
  소모 없이 동일하게 사용(선택). 기존 개인 활성화 유지도 무방하나 시트 하나를 점유함.
- **시연(42)**: trace-worker 가 같은 wrapper 를 봄 → 시연 서버에서 Suprema 사용 가능. **4-인스턴스
  한도를 한 wrapper 가 관리** → 시트 경합 없음.

> 미검증으로 남는 것: Phase 1 의 라이선스 통과 여부(테스트하면 즉시 판명) · Phase 2 의 네트워크 노출
> 정책(OPS-012, 담당자 복귀 시 재확인). 그 외는 우리 정보만으로 진행 가능.

---

## 7. ✅ 구축 완료 상태 (2026-08-20)

42 시연 서버에서 아래 구성으로 **trace-worker ↔ Suprema 얼굴 identity 연결 확인 완료.**

**최종 구성**
- **wrapper**: `qfe_http_server`(빌드본을 `/data/libs/qfe_http_server/qfe_http_server`로 배치),
  **systemd `qfe-http.service`**로 상시 기동(`enabled` = 재부팅 생존), **`--bind 0.0.0.0`**,
  `--db /data/libs/facedb/face_database.db`, `enroll=off`, 4 instance, `User=gpuadmin`.
  라이선스 로딩은 유닛 ExecStart의 `source /data/libs/qfe_license/env.sh`.
- **trace-worker**(compose): `SUPREMA_ENDPOINT=http://host.docker.internal:18080` +
  `extra_hosts: host.docker.internal:host-gateway`. 값은 `.env`(통합됨, `.env.dev` 아님)에서 주입.
- **dev 컨테이너**(provision_dev.sh): `SUPREMA_ENDPOINT_URL` 기본값이
  `http://host.docker.internal:18080` → 발급 시 `--add-host` + `-e`로 자동 주입.
- **방화벽(OPS-012)**: 18080을 loopback + docker 서브넷(172.16/12)만 허용, 그 외 DROP.

**검증(모두 통과)**
```bash
systemctl status qfe-http           # active (running), 단일 Main PID
sudo ss -ltnp | grep ':18080'       # 0.0.0.0:18080, PID == systemctl MainPID
curl -s 127.0.0.1:18080/health      # {"status":"ok","max_instance":4,"enrolled_users":10,...}
docker exec piascope-trace-worker python -c \
  "import urllib.request,os; print(urllib.request.urlopen(os.environ['SUPREMA_ENDPOINT']+'/health',timeout=3).read())"
# trace-worker 로그: builders.identity_resolver: T2 on ... identity=suprema camera_scope=['cam-1','cam-2','cam-3']
```

**교훈(harvest)**
- 얼굴 SDK는 **노드락 in-process** → 컨테이너 직접 InitSDK 불가(`-5`). 소비자는 **HTTP 엔드포인트**만
  필요(ADR-023). 초기의 "data.conf 마운트" 방향이 잘못된 계층이었다.
- systemd 재기동 시 **모델 로드에 ~7초** → `sleep 1` 직후 `ss`/`curl` 은 레이스로 refused. 최소 10초 대기 후 확인.
- 수동 프로세스가 포트를 잡고 있으면 systemd가 `bind: Address already in use`로 **재시작 루프**에 빠진다
  → 전환 시 수동 프로세스를 먼저 완전히 종료하고 포트를 비울 것.

### ⚠️ 재부팅 시 주의 — 방화벽 영속화 필수

systemd 서버는 재부팅에 살아나지만, **손으로 넣은 iptables 규칙은 사라진다** → 18080이 LAN에 노출됨(OPS-012 위반). 규칙 영속화:
```bash
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save     # /etc/iptables/rules.v4 에 저장 (18080 3줄 포함 확인)
```

### 남은 항목
- `provision_dev.sh` 최신본 rsync → dev 컨테이너는 재발급 시 자동으로 endpoint 주입.
- `.env`의 `INTERNAL_SERVICE_SECRET`가 placeholder(`asdf`)면 `openssl rand -hex 32`로 교체.
- 네트워크 노출 정책(0.0.0.0+방화벽)은 얼굴/인프라 담당 복귀 시 재확인.
- wrapper 바이너리 갱신 시: 재빌드 → `/data/libs/qfe_http_server/`에 재배치 → `systemctl restart qfe-http`.

---

## 관련 소스

- `scripts/face/qfe_http_server/README.md` · `qfe_http_server.c` · `build.sh`
- `infra/configs/identity.yaml` (`identity.suprema.endpoint: ${SUPREMA_ENDPOINT}`)
- `piapf/face/suprema_adapter.py` (`resolve_endpoint`, HTTP 클라이언트)
- ADR-023 (Suprema 어댑터 격리) · TICKET-OPS-012 (loopback/네트워크 노출)
- `42-dev-env/scripts/provision_dev.sh`
