# 42 서버 개발 컨테이너 접속 가이드 (개발자용)

> 아직 계정 발급 전이라면 먼저 [`REQUEST-ACCESS.md`](REQUEST-ACCESS.md) (SSH 키 발급 + 신청서).
> 이 문서는 **발급 완료 후 접속**을 다룬다.

발급이 완료되면 아래 4가지를 전달받는다: **계정명** · **서버 주소** · **컨테이너 sshd 포트**(2200~2299) · (본인이 제출한 SSH 키).

> ⭐ **접속 모델(2026-08-28 변경)**: 이제 호스트가 아니라 **본인 컨테이너에 SSH 로 직접**
> 붙는다. `ssh` 한 번이면 컨테이너 안 셸이다 — 예전의 `docker exec` 단계는 없다(개발자에겐
> 호스트 docker 권한이 없다). 그래서 config 에 **`Port <배정포트>`** 한 줄이 추가된다.

> 📍 `<DEV_SERVER_IP>` = 42 dev 서버 IP (사설망 · 외부 접근 불가). 실제 값은 발급 시 admin 이 안내한다.

## 1. 최초 1회 설정

로컬 `~/.ssh/config` 에 **아래 블록을 그대로** 추가한다 (계정명·포트만 치환).
⚠️ 별칭은 `gpu42` 로 통일할 것 — 제각각 지으면 서로 돕기 어렵고 오타로 접속이 깨진다.

```
Host gpu42
    HostName <DEV_SERVER_IP>
    User <본인계정>            # 예: user1  (반드시 본인 계정)
    Port <배정포트>            # ⭐ 발급 시 받은 컨테이너 sshd 포트 (예: 2205)
    IdentityFile ~/.ssh/id_ed25519
```

- **HostName 은 발급 시 받은 42 dev 서버 IP** — `<DEV_SERVER_IP>` 자리에 실제 값을 넣는다(사설망 IP).
- **Port 를 빠뜨리면** 호스트(22)로 붙어 `nologin` 으로 즉시 끊긴다 → 반드시 배정포트를 넣는다.
- macOS 에서 키에 passphrase 가 있으면 매번 안 묻게 keychain 에 한 번 등록:
  ```bash
  ssh-add --apple-use-keychain ~/.ssh/id_ed25519
  ```

접속 확인 (한 번에 컨테이너 안):

```bash
ssh gpu42                                                    # 바로 컨테이너 셸 (dev env 활성)
python -c "import torch; print(torch.cuda.is_available())"   # (ml) True 확인
```

## 2. VS Code 로 개발하기

1. 로컬 VS Code 에 확장 설치: **Remote - SSH**
2. `Cmd+Shift+P` → `Remote-SSH: Connect to Host` → `gpu42`
   (컨테이너에 '원격 호스트'로 바로 붙는다 — Dev Containers Attach 단계 없음)
3. 폴더 열기: `/home/<본인계정>/work`

이후에는 VS Code 좌하단 초록 버튼 → Recent 에서 바로 재접속된다.

## 3. 컨테이너 안 환경

| 경로 | 내용 |
|---|---|
| `/home/<계정>` | 호스트 홈과 동일 (영속 — 컨테이너가 재발급돼도 유지) |
| `/home/<계정>/work` | 작업 디렉터리 (여기서 작업) |
| `/weights` | 공유 모델 weight (전 계정 읽기/쓰기) |
| `/libs` | 공유 AI 라이브러리 (QFE 등 · **읽기 전용** · admin 관리) |
| `/datasets` | 공유 데이터셋 (읽기 전용) |
| conda | 기본 env `dev` 자동 활성화 · `conda create` 로 자기 env 추가 자유 |

- GPU: 현재 **전체 공유** (`nvidia-smi` 로 다 보임). 사용 규칙은 아래 §4.
- 추가로 만든 conda env 는 컨테이너 재발급 시 사라진다 → 오래 쓸 env 는
  `conda env export -n <이름> > ~/work/envs/<이름>.yml` 로 홈에 백업.
- git 설정(`~/.gitconfig`)·SSH 키는 홈에 있으므로 컨테이너 안에서 그대로 동작.
- `/libs` 공유 라이브러리(예: `/libs/QFE_v1.1.3`)는 읽기 전용이다. import 하려면
  `export PYTHONPATH=/libs/QFE_v1.1.3:$PYTHONPATH` 또는 자기 conda env 에
  `pip install -e /libs/QFE_v1.1.3` (editable 설치가 소스에 쓰기를 요구해 실패하면
  `~/work` 로 복사해서 설치). 공유본 수정이 필요하면 admin 에게.

## 4. ⚠️ 공용 서버 수칙 (필독)

이 서버는 **PIA Scope dev 배포 스택이 같이 떠 있는 공용 서버**다
(`piascope-*` 컨테이너 = gateway·UI·검색 서비스·DB·Milvus 등 — 데모/검증에 사용 중).

> ⭐ 인프라 규칙은 [`shared-infra-rules.md`](shared-infra-rules.md) 를 먼저 읽는다 — 핵심은
> "**상태를 쓰는 의존(PG·Redis)은 내 컨테이너 안 `devstores` 로, 공유는 읽기전용**".
> 인덱싱/마이그레이션이 데모 데이터를 오염시키면 완성 판정이 깨진다.

> 개인 테스트 저장소는 컨테이너 안에서: `devstores up` → `127.0.0.1:5432`(pg)·`127.0.0.1:6379`(redis).

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

### 접속이 안 됨 (비밀번호를 묻거나 permission denied)

거의 항상 **본인 맥의 `~/.ssh/config` 문제**다 (계정은 비밀번호가 잠겨 있어 비번
프롬프트가 뜨면 무조건 실패한다 = 키 인증이 안 먹은 것). 서버가 아니라 **접속하는
쪽**을 먼저 의심한다.

**자가진단 — config 를 통째로 무시하고 붙어본다** (배정포트를 `-p` 로 직접):
```bash
ssh -F /dev/null -p <배정포트> -i ~/.ssh/id_ed25519 <본인계정>@<DEV_SERVER_IP>
```
- **이게 되면** → 서버·계정·키는 정상. 범인은 100% 로컬 `~/.ssh/config` 별칭.
  §1 표준 블록으로 `Host gpu42` 를 다시 만들고 `ssh gpu42` 로 재시도.
- **이것도 안 되면** → 키/계정 문제. 아래 순서로 확인:
  ```bash
  ls -l ~/.ssh/id_ed25519                         # 없으면 키가 없는 것
  chmod 600 ~/.ssh/id_ed25519                      # 권한 640/644 면 SSH 가 키를 무시함
  ssh-keygen -lf ~/.ssh/id_ed25519.pub             # 이 지문을 admin 이 서버 등록분과 대조
  ```
  지문이 서버 등록분과 다르면 admin 에게 올바른 `.pub` 재등록 요청.

**흔한 config 함정** (`ssh -G gpu42` 로 최종값 확인):
- `hostname` 이 별칭과 같게 나옴 → `HostName` 줄 누락/오타.
- `user` 가 본인이 아님, `identityfile` 이 엉뚱함 → 위쪽 `Host *` 블록이 값을
  가로챈 것(먼저 매칭된 블록이 이김). 그 블록을 고치거나 gpu42 블록을 위로 옮긴다.

### `REMOTE HOST IDENTIFICATION HAS CHANGED!` (호스트 키 변경)

어제까지 되던 `ssh gpu42` 가 갑자기 아래처럼 뜨고 접속이 끊긴다:
```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
...
Offending ECDSA key in /Users/<본인>/.ssh/known_hosts:42
Host key verification failed.
```

**공격이 아니고, 서버가 키를 바꾼 것도 아니다 — 내 맥의 `known_hosts` 가 낡은 것이다.**

컨테이너 sshd 호스트 키(그 엔드포인트의 **신원**)는 provision 이 개발자별로 **최초 1회**
발급해 호스트(`/data/42dev/hostkeys/<컨테이너>/`)에 영속화하고, 컨테이너엔
`/etc/ssh/keys` 로 read-only 마운트한다. 이미지엔 키를 굽지 않는다. 따라서 **이미지를
재빌드하든 컨테이너를 몇 번을 재발급하든 호스트 키는 불변**이다 — 홈 데이터가 볼륨이라
보존되는 것과 같은 원리.

그럼 이 경고를 언제 보나? **경고는 서버 키가 아니라 내 맥이 예전에 캐시한 키를 기준으로**
한다. 실무에서 뜨는 경우는 사실상 둘뿐이다:
- **옛 방식(키를 이미지에 굽던 시절, `ssh-keygen -A`)으로 만든 컨테이너에 붙었던 이력이
  있는 경우 — 마이그레이션성 1회성.** 그땐 재빌드마다 키가 갈려 이 경고가 났다. 아래처럼
  옛 항목을 한 번 지우면 새 영속 키를 받고, **이후로는 재발급해도 다시 안 뜬다.**
- 내 `known_hosts` 의 그 `[IP]:포트` 자리에 **예전 다른 컨테이너/서비스**의 키가 남아 있고
  포트가 재사용된 경우. 역시 옛 줄을 지우면 끝.

**서버는 멀쩡하다는 근거**: 컨테이너 로그가 `Server listening on 0.0.0.0 port 22` 뒤에
`Connection closed by <client> [preauth]` 를 반복하면, 그건 sshd 가 죽은 게 아니라
**클라이언트가 키 불일치를 보고 인증 전에 스스로 끊는** 정상 로그다.

**해결 (내 맥에서만, 서버는 손대지 않음):** 옛 항목을 지우고 재접속한다.
```bash
# ⚠️ 비표준 포트는 known_hosts 에 [IP]:포트 형태로 저장된다 — 포트 없이 지우면 안 지워짐
ssh-keygen -R "[<DEV_SERVER_IP>]:<배정포트>"
ssh -p <배정포트> <본인계정>@<DEV_SERVER_IP>          # 새 지문 확인 후 yes
```
- `-R` 대상은 반드시 **에러가 알려준 그 줄**(`known_hosts:<번호>`)과 같은 키다.
  못 맞추겠으면 그 줄을 에디터로 직접 지워도 된다.
- **yes 하기 전에 지문 대조**(중간자 공격이 아님을 스스로 확인). admin 이 서버에서
  현재 키의 지문을 읽어 알려줄 수 있다:
  ```bash
  # (admin, 호스트에서) 그 컨테이너의 실제 호스트 키 지문
  docker exec <컨테이너> ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
  ```
  이 값이 재접속 때 뜨는 fingerprint 와 같으면 안심하고 yes.
- **VS Code Remote-SSH** 도 같은 증상("Host key verification failed")이며 해결도 동일 —
  맥의 `known_hosts` 에서 그 줄을 지우고 다시 접속하면 새 키를 받는다.

### 그 외

- 컨테이너가 죽어 있음(= `ssh gpu42` 자체가 안 됨): 컨테이너는 `--restart unless-stopped`
  로 자동 재시작된다. 그래도 안 뜨면 admin에게 요청(개발자는 호스트 docker 권한 없음).
- 첫 Remote-SSH 접속이 오래 걸림: VS Code 확장(Python·Jupyter) 최초 설치 중 —
  멈춘 게 아니니 기다린다. 두 번째부터는 즉시 붙는다.
- 그 외: admin 에게. 컨테이너 재발급은 홈 데이터를 건드리지 않는다.
