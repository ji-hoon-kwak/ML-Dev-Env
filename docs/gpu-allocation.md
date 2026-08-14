# 42 서버 GPU 할당 정책

42 서버의 GPU **4장**을 용도별로 고정 분할한다. 이 문서가 할당의 단일 원천(source of truth)이다.

## 분할 (목표 상태)

| GPU | 용도 | 누가 쓰나 | 격리 방법 |
|:---:|------|-----------|-----------|
| **0** | **개발자 공유** | 전 개발자 dev 컨테이너 (공유) | dev 컨테이너를 `--gpus '"device=0"'` 로 발급 |
| **1** | **서비스** | PIA Scope dev 스택 (`piascope-*`, 특히 trace-worker) | 서비스 compose 를 GPU 1 에 pin |
| **2, 3** | **학습 전용** | 학습 잡 (수동 실행) | 학습 컨테이너를 `--gpus '"device=2,3"'` 로 실행. dev·서비스 컨테이너에는 **노출 금지** |

- 물리 GPU 번호(0~3)와 용도 매핑은 `nvidia-smi -L` 로 실물 확인 후 확정할 것.
  (서비스가 이미 특정 GPU 를 쓰고 있으면 그 번호를 1번 슬롯으로 잡는 게 재기동을 줄인다.)
- **개발자 공유 = GPU 0 한 장**을 여럿이 나눠 쓴다. 큰 학습은 개발 GPU 가 아니라
  학습 전용(2,3)에서 돌린다 — 개발 GPU 를 학습으로 오래 점유하지 않는다.

## 왜 이렇게 나누나

- **서비스 보호**: `piascope-trace-worker` 등 상시 서비스가 개발자 학습 잡의
  VRAM 경합으로 CUDA OOM 나면 데모·M3 검증이 깨진다. 서비스 GPU 를 물리적으로 분리한다.
- **학습 격리**: 학습은 GPU 를 통째로 오래 점유하므로 개발/서비스와 섞지 않는다.
- **개발 편의**: 일상 개발(디버깅·소규모 추론)은 공유 1장으로 충분하다.

## 적용 방법

격리는 반드시 **컨테이너 레벨**(`--gpus device=N`)에서 강제한다. 컨테이너 안
`CUDA_VISIBLE_DEVICES` 는 합의일 뿐 강제가 아니다.

**개발자 컨테이너 (GPU 0 로 재발급):**
```bash
sudo docker rm -f dev-<계정명>
sudo ./scripts/provision_dev.sh <계정명> keys/<계정명>.pub 0
# 홈은 bind-mount 라 코드·설정 보존. conda 추가 env·apt 설치만 재구성 필요.
```

**서비스 스택 (GPU 1 로 pin):** 서비스 리포(TRACE_SSAVE-AI-MVP)의 docker-compose 에서
GPU 를 쓰는 서비스(trace-worker 등)에 device 를 고정한다. 예:
```yaml
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ["1"]
              capabilities: [gpu]
```
⚠️ 이건 **서비스 리포 변경**이라 배포 담당이 별도 PR 로 처리한다 (이 리포 밖).

**학습 잡 (GPU 2,3):**
```bash
docker run --rm --gpus '"device=2,3"' \
  -v /data/weights:/weights -v /data/datasets:/datasets:ro \
  <학습이미지> python train.py ...
```

## 확인 명령

```bash
nvidia-smi -L                                    # 물리 GPU 목록
nvidia-smi                                       # 현재 어느 GPU 를 누가 점유 중인가
# 컨테이너별 GPU 할당 확인:
docker inspect dev-dhkim --format \
  '{{range .HostConfig.DeviceRequests}}gpu={{.DeviceIDs}}{{end}}'
```

## 현재 상태 / 전환 메모

- **현행**: dev 컨테이너가 `--gpus all` 로 발급돼 있어 4장 전부 접근 가능 = 위 정책과 불일치.
  전환하려면 각 dev 컨테이너를 `device=0` 으로 재발급해야 한다(위 명령). 재발급은 홈을
  건드리지 않으니 해당 개발자에게 예고 후 진행.
- **M3 검증 기간(2026-08-19 ~ 08-28)**: 서비스 GPU(1) 분리를 이 기간 전에 반드시 적용.
  완성 판정이 `piascope-*` 스택으로 이뤄지므로 개발 학습 잡의 VRAM 경합을 이때는 허용하지 않는다.
- 경합·대기가 커지면 다음 단계는 학습 GPU(2,3) 앞에 잡 스케줄러(Slurm/Ray) 도입
  (README "다음 단계" 로드맵 참조).

## 개발자 대상 규칙 (요약 — 상세는 ONBOARDING.md §4)

- 자기 몫 GPU(개발=0)만 쓴다. 서비스(1)·학습(2,3) GPU 를 dev 컨테이너에서 건드리지 않는다.
- 1시간 이상 GPU 점유 학습은 `#piaspace-dev` 에 선언 후 **학습 전용 GPU** 에서.
