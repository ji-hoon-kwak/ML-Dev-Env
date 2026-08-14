# 42 서버 개발환경 신청 가이드 (신규 합류자용)

처음 합류한 개발자가 **42 GPU 서버의 개인 개발 컨테이너를 신청**하는 절차.
SSH 키 발급 → 신청서 제출 → (admin 발급) → 접속 순서다. 전체 5분이면 신청까지 끝난다.

> 발급이 끝나면 접속·VS Code 설정은 [`ONBOARDING.md`](ONBOARDING.md) 를 따른다.
> 이 문서는 **신청까지**만 다룬다.

---

## 1단계 — SSH 키 발급 (본인 로컬 PC에서)

이미 키가 있으면(아래 확인) 건너뛴다. 없으면 새로 만든다.

**기존 키 확인:**

```bash
ls ~/.ssh/id_ed25519.pub   # 파일이 있으면 이미 키가 있는 것
```

**새로 발급 (macOS / Linux):**

```bash
ssh-keygen -t ed25519 -C "본인이메일@pia.space"
# 저장 위치: 그냥 Enter (기본 ~/.ssh/id_ed25519)
# passphrase: 입력 권장 (엔터로 비워도 되지만, 분실 시 보호 위해 설정 권장)
```

**Windows** 는 PowerShell 에서 동일하게 `ssh-keygen -t ed25519 -C "..."` 실행
(키는 `C:\Users\<이름>\.ssh\id_ed25519.pub` 에 생성).

**공개키 내용 복사** — 신청서에 붙여넣을 것:

```bash
cat ~/.ssh/id_ed25519.pub        # macOS/Linux
# macOS 는 클립보드로 바로:  pbcopy < ~/.ssh/id_ed25519.pub
```

출력은 `ssh-ed25519 AAAAC3Nza... 본인이메일@pia.space` 한 줄이다. **이 한 줄 전체**를 제출한다.

> 🔴 **`.pub` 로 끝나는 공개키만 제출한다.** 확장자 없는 `id_ed25519`(개인키)는
> 비밀번호와 같다 — 누구에게도, 어디에도 보내지 않는다. Slack/메일로도 금지.

---

## 2단계 — 신청서 제출

아래 양식을 채워 **admin(@jhkwak)** 에게 DM 또는 `#piaspace-dev` 로 보낸다.

```
[42 서버 개발환경 신청]
- 이름:                        (예: 김동현)
- 희망 계정명:                 (예: dhkim  — 아래 규칙 참조)
- 이메일:                      (예: dh.kim@pia.space)
- SSH 공개키(.pub 한 줄):      ssh-ed25519 AAAAC3Nza... dh.kim@pia.space
- 주 사용 목적:                (예: SSAVE 검색 모델 학습 / TRACE 추적 개발 / 기타)
- GPU 필요 수준:               (일상 개발만 / 주기적 학습 있음)
```

**희망 계정명 규칙:**
- 영문 소문자·숫자만, 공백/특수문자 없이.
- 사내 관례 = **이름 이니셜 + 성** (예: 김동현 → `dhkim`, 곽지훈 → `jhkwak`).
- 이미 쓰는 계정명과 겹치면 admin 이 대안을 제안한다.

---

## 3단계 — 발급 대기 (admin 작업, 보통 몇 분)

admin 이 `provision_dev.sh` 로 다음을 자동 생성한다:
- Unix 계정(비밀번호 없이 SSH 키 인증만) + docker 그룹
- 개인 개발 컨테이너 `dev-<계정명>` (conda `dev` 환경 · GPU · `/weights`·`/datasets` 마운트)

발급이 끝나면 admin 이 **서버 주소 + 할당된 GPU** 를 알려준다.

---

## 4단계 — 접속

접속·VS Code Remote-SSH·Dev Containers 설정, 공용 서버 수칙은 모두
👉 **[`ONBOARDING.md`](ONBOARDING.md)** 에 있다.

첫 접속 요약만:
```bash
ssh <계정명>@<서버주소>
docker exec -it dev-<계정명> bash     # (dev) conda 환경 자동 활성화
```

> ⚠️ 첫 Remote-SSH 접속은 VS Code 확장(Python·Jupyter)을 새로 설치하느라
> **몇 분** 걸린다. 멈춘 게 아니니 기다린다. 두 번째부터는 즉시 붙는다.

---

## 자주 묻는 것

- **키를 잃어버렸어요** → 새로 `ssh-keygen` 하고 새 `.pub` 을 admin 에게 보내 교체 요청.
- **컨테이너가 죽어 있어요** → `ssh` 접속 후 `docker start dev-<계정명>`. 안 되면 admin.
- **내 코드는 어디에 두나요** → 홈(`/home/<계정명>`) 아래면 어디든 컨테이너 재발급에도
  안전하다. 단 **git 으로 사내 원격에 자주 push** 하는 게 진짜 백업이다 (`ONBOARDING.md` §3).
