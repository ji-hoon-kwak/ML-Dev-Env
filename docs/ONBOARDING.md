# 42 서버 개발 컨테이너 접속 가이드 (개발자용)

> 아직 계정 발급 전이라면 먼저 [`REQUEST-ACCESS.md`](REQUEST-ACCESS.md) (SSH 키 발급 + 신청서).
> 이 문서는 **발급 완료 후 접속**을 다룬다.

발급이 완료되면 아래 3가지를 전달받는다: **계정명** · **서버 주소** · (본인이 제출한 SSH 키).

## 1. 최초 1회 설정

로컬 `~/.ssh/config` 에 추가:

```
Host gpu42
    HostName <42서버주소>
    User <본인계정>            # 예: dhkim
    IdentityFile ~/.ssh/id_ed25519
```

접속 확인:

```bash
ssh gpu42
docker exec -it dev-<본인계정> bash   # 프롬프트에 (dev) 가 붙으면 정상
python -c "import torch; print(torch.cuda.is_available())"   # True 확인
```

## 2. VS Code 로 개발하기

1. 로컬 VS Code 에 확장 설치: **Remote - SSH**, **Dev Containers**
2. `Cmd+Shift+P` → `Remote-SSH: Connect to Host` → `gpu42`
3. 열린 원격 창에서 `Cmd+Shift+P` → `Dev Containers: Attach to Running Container` → `dev-<본인계정>`
4. 폴더 열기: `/home/<본인계정>/work`

이후에는 VS Code 좌하단 초록 버튼 → Recent 에서 바로 재접속된다.

## 3. 컨테이너 안 환경

| 경로 | 내용 |
|---|---|
| `/home/<계정>` | 호스트 홈과 동일 (영속 — 컨테이너가 재발급돼도 유지) |
| `/home/<계정>/work` | 작업 디렉터리 (여기서 작업) |
| `/weights` | 공유 모델 weight (전 계정 읽기/쓰기) |
| `/datasets` | 공유 데이터셋 (읽기 전용) |
| conda | 기본 env `dev` 자동 활성화 · `conda create` 로 자기 env 추가 자유 |

- GPU: 현재 **전체 공유** (`nvidia-smi` 로 다 보임). 사용 규칙은 아래 §4.
- 추가로 만든 conda env 는 컨테이너 재발급 시 사라진다 → 오래 쓸 env 는
  `conda env export -n <이름> > ~/work/envs/<이름>.yml` 로 홈에 백업.
- git 설정(`~/.gitconfig`)·SSH 키는 홈에 있으므로 컨테이너 안에서 그대로 동작.

## 4. ⚠️ 공용 서버 수칙 (필독)

이 서버는 **PIA Scope dev 배포 스택이 같이 떠 있는 공용 서버**다
(`piascope-*` 컨테이너 = gateway·UI·검색 서비스·DB·Milvus 등 — 데모/검증에 사용 중).

1. **`piascope-*` 컨테이너를 절대 건드리지 않는다** — stop/rm/restart 금지.
   서비스 스택 조작은 배포 담당만 한다.
2. **`docker system prune` / `docker volume prune` 금지** — 서비스 데이터
   볼륨이 날아갈 수 있다. 정리는 admin 에게 요청.
3. **GPU 사용 선언**: 1시간 이상 GPU 를 점유하는 학습/실험은 `#piaspace-dev` 에
   "GPU n번, ~몇시까지" 선언 후 사용. `CUDA_VISIBLE_DEVICES=n` 으로 본인이
   선언한 GPU 만 쓴다. trace-worker 등 서비스가 쓰는 GPU 는 공지된 것 확인.
4. **포트 개방 금지**: 새로 포트를 열어야 하면(-p, 서버 실행 등) admin 과
   포트 대장 확인 후. 3100~3401·8001~8002 는 서비스 스택이 사용 중.
5. **대용량 파일은 홈이 아니라 `/datasets`(admin 요청)·`/weights` 로** —
   디스크가 차면 Elasticsearch/PostgreSQL 이 먼저 죽는다.
6. 서버 리포(TRACE_SSAVE-AI-MVP)의 `docker compose` 를 **호스트에서 직접
   실행하지 않는다** — 배포된 스택과 포트가 충돌한다. 개발은 컨테이너 안에서.

## 문제 발생 시

- 컨테이너가 죽어 있음: `ssh gpu42` 후 `docker start dev-<계정>` (재부팅 후 자동 시작이 안 됐을 때)
- 그 외: admin(@jhkwak) 에게. 컨테이너 재발급은 홈 데이터를 건드리지 않는다.
