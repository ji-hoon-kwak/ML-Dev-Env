# 42 서버 개발 환경 (dev containers)

42 서버에 AI 개발자별 도커 컨테이너를 발급하고 VS Code Dev Containers 로 접속하는
환경의 관리 도구. **서비스 리포(TRACE_SSAVE-AI-MVP)와 분리된 인프라 툴링**이다.

## 구조

```
docker/
  Dockerfile        # 개발자별 이미지 (company/ai-dev:1.0 + uv 환경 + 개인 계정)
  pyproject.toml    # 공통 Python 의존성 (torch cu124 인덱스 포함)
scripts/
  provision_dev.sh    # 온보딩: 계정 생성 + 컨테이너 발급
  deprovision_dev.sh  # 오프보딩: 컨테이너 제거 + 계정 잠금
```

3층 구조: **admin(sudo) = 발급·관리 → 개발자 Unix 계정 = SSH 진입점 → 컨테이너 = 실제 작업 환경**

## 온보딩 (admin이 42 서버에서)

```bash
# 개발자에게 SSH 공개키를 받아서:
sudo ./scripts/provision_dev.sh jhkwak ./keys/jhkwak.pub 0     # GPU 0번 할당
sudo ./scripts/provision_dev.sh mkim   ./keys/mkim.pub   2,3   # GPU 2,3번 할당
```

개발자 접속 동선:

```
ssh jhkwak@<42서버>  →  docker exec -it dev-jhkwak bash
VS Code: Remote-SSH 접속 → "Dev Containers: Attach to Running Container" → dev-jhkwak
```

## GPU 할당 대장

| GPU | 용도 | 할당 | 비고 |
|-----|------|------|------|
| 0   | 개발 |      |      |
| 1   | 개발 |      |      |
| ... |      |      |      |
| 6,7 | **학습 전용** | (컨테이너에 노출 금지) | 학습 잡 실행 시에만 `docker run --rm --gpus '"device=6,7"' ...` |

- 격리는 **컨테이너 레벨**(`--gpus device=N`)에서 강제한다. 컨테이너 안
  `CUDA_VISIBLE_DEVICES` 는 합의일 뿐 강제가 아니다.
- 학습 전용 GPU 는 어떤 개발 컨테이너에도 노출하지 않는다.

## 첫 이미지 빌드 전 확인

1. `company/ai-dev:1.0` 이 Ubuntu 계열 + CUDA 런타임인지, uv 내장 여부 확인
   (내장이면 Dockerfile 의 `COPY --from=ghcr.io/astral-sh/uv` 줄 삭제).
2. 서버 CUDA 버전에 맞게 `docker/pyproject.toml` 의 `cu124` 인덱스 조정.
3. 최초 빌드 후 컨테이너 안 `/opt/project/uv.lock` 을 꺼내 `docker/` 에 커밋
   → 이후 빌드 재현성 확보:
   ```bash
   docker cp dev-<user>:/opt/project/uv.lock docker/uv.lock
   ```

## 보안 메모 (합의된 트레이드오프)

- **docker 그룹 = 호스트 root 등가.** 개발자 전원이 서로의 컨테이너·호스트에
  접근 가능하다. 10인 신뢰 팀 전제의 절충이며, 격리가 필요해지면
  rootless docker 또는 admin 발급 전용(sudoers 로 `docker exec` 만 허용)으로 전환.
- 계정은 비밀번호 잠금 + SSH 키 인증만. 오프보딩 = `deprovision_dev.sh`.
- 42 서버가 사내망 전용이 아니라면 SSH 포트 공개 대신 VPN/Tailscale 경유 권장.

## 라이선스 메모

- `ultralytics` 는 **AGPL-3.0** — 서비스 리포 CLAUDE.md §10 기준 Enterprise
  License / Roboflow sub-license 전제. 개발 환경 포함은 문제없으나 배포물에
  섞일 때 조건 확인.

## 다음 단계 (합의된 로드맵)

1. ✅ 계정 분리 + 개발자별 컨테이너 + VS Code attach (이 리포)
2. `.devcontainer/devcontainer.json` 을 서비스 리포에 추가해 attach 후 확장/설정 자동화
3. GPU 풀 분리 운영 (개발용 정적 할당 / 학습 전용) + DCGM-exporter 모니터링
4. 학습 잡 대기가 병목이 되면 스케줄러(Slurm/Ray) 도입 검토
