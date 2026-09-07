# GPU 트러블슈팅: "Failed to initialize NVML: Unknown Error"

> 컨테이너 안에서 `nvidia-smi` 가 `Failed to initialize NVML: Unknown Error` 로 죽을 때.
> 호스트 `gpusystem` 에서 2026-09-07 실제로 진단·해결한 사례를 그대로 박아둔 런북.

## 증상
```
$ nvidia-smi
Failed to initialize NVML: Unknown Error
```
- 컨테이너 안(특히 오래 떠 있던 컨테이너)에서만 실패. **호스트 `nvidia-smi` 는 정상**.
- 재시작하면 잠깐 되다가 **반복적으로 다시 깨진다.**
- "특정 유저만" 걸리는 것처럼 보인다(= 그 순간 GPU 컨텍스트를 쓰려던/떠 있던 컨테이너만).

## ⭐ 먼저 두 갈래를 가른다 (원인이 둘 있다)

### 갈래 A — 시스템 RAM 고갈 (일과성)
```bash
free -h                                              # available 이 바닥이면 호스트 RAM 고갈
dmesg | grep -iE 'NVRM|Out of memory|oom-kill' | tail
```
- dmesg 에 `NVRM: ... Out of memory [NV_ERR_NO_MEMORY] ... system_mem.c` 가 보이면 **호스트 RAM(시스템 메모리) 할당 실패**다(VRAM 아님). NVML 초기화는 드라이버가 host RAM 을 잡아야 하는데 그게 없어 실패한 것.
- **원인**: `--memory` cgroup 상한 합계(dev 컨테이너 N×64g + 서비스 스택)가 물리 RAM을 초과하는 oversubscription + **swap 0** → 순간 스파이크에 완충이 없어 하드 실패.
- **복구**: RAM 회수(범인 프로세스 종료) 또는 컨테이너 재시작.
- **예방**: swap 추가(예: 32Gi, `vm.swappiness=10`) · 인당 `--memory` 하향 · 호스트 `MemAvailable` 경보(Prometheus `node_exporter`).

### 갈래 B — systemd cgroup 드라이버가 GPU device 접근을 스트립 (반복성) ⭐ 이번 근본원인
호스트 RAM 이 멀쩡한데(위 A 무해) `nvidia-smi` 가 반복적으로 죽으면 이쪽이다.
```bash
docker info | grep -i 'Cgroup Driver'                # 'systemd' 면 범인
sudo systemctl daemon-reload && docker exec <컨테이너> nvidia-smi   # 이 한 줄로 바로 깨지면 확정
```
- **원인**: Docker 가 **systemd** cgroup 드라이버로 컨테이너 device cgroup 을 관리하는데, `systemctl daemon-reload`(패키지 설치·서비스 변경이 수시로 유발)가 나면 systemd 가 device 허용 목록을 다시 써서 **주입됐던 `/dev/nvidia*` 접근을 걷어낸다.** 게다가 hierarchy 가 오염돼 **새로 만든 컨테이너까지** 접근을 못 받는다.
- runc 는 `/dev/char/*` 심링크를 요구하는데 NVIDIA 드라이버가 자동 생성하지 않는 것도 관련(아래 "부분 위생" 참조).

## ⭐ 해결 (갈래 B) — Docker cgroup 드라이버를 cgroupfs 로

systemd 를 device cgroup 관리에서 빼면 daemon-reload 가 GPU 를 못 건드린다. **이 호스트에 적용해 검증 완료.**

```bash
sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak      # 롤백용
# exec-opts 안전 병합 (기존 nvidia 런타임 키 보존)
command -v jq >/dev/null || sudo apt-get install -y jq
sudo jq '. + {"exec-opts": ["native.cgroupdriver=cgroupfs"]}' /etc/docker/daemon.json \
  | sudo tee /etc/docker/daemon.json.new >/dev/null
sudo mv /etc/docker/daemon.json.new /etc/docker/daemon.json
sudo systemctl restart docker                                    # ⚠️ 아래 주의

# 검증 — 둘 다 정상 출력이어야 한다
docker info | grep -i 'Cgroup Driver'                            # → cgroupfs
docker exec <컨테이너> nvidia-smi
sudo systemctl daemon-reload && docker exec <컨테이너> nvidia-smi
```

⚠️ **주의**
- `systemctl restart docker` 는 **모든 docker 컨테이너(배포 `piascope-*` 스택 포함)를 잠깐 재시작**시킨다(`--restart` 로 자동 복귀). 타이밍 잡고 실행할 것.
- 이 설정은 **dockerd 에만** 적용된다 — k8s 의 containerd 는 별도 config 라 영향 없음.
- 컨테이너 **재생성 불필요** — docker 재시작이 전 컨테이너를 cgroupfs 로 다시 띄운다.
- 롤백: `sudo mv /etc/docker/daemon.json.bak /etc/docker/daemon.json && sudo systemctl restart docker`.

## 이번에 "부분 위생"이었지만 단독으론 부족했던 것들
아래는 필요한 위생이라 **그대로 두지만**, 이 호스트에선 이것만으론 daemon-reload 를 못 막았다(드라이버가 systemd 인 한). belt-and-suspenders 로 유지.
- `nvidia-container-toolkit` 업그레이드(1.13.5 → 1.20.0). *구버전은 `nvidia-ctk system create-dev-char-symlinks` 가 `missing required device major nvidia-frontend` 로 실패 — 드라이버 550+ 는 `/proc/devices` 이름이 `nvidia-frontend`→`nvidia` 로 바뀌었고 toolkit ≥1.14.6 이 이를 인식.*
- `/dev/char` 심링크 생성 + 재부팅 영속(udev):
  ```bash
  sudo nvidia-ctk system create-dev-char-symlinks --create-all
  sudo tee /lib/udev/rules.d/71-nvidia-dev-char.rules >/dev/null <<'EOF'
  ACTION=="add", DEVPATH=="/bus/pci/drivers/nvidia", RUN+="/usr/bin/nvidia-ctk system create-dev-char-symlinks --create-all"
  EOF
  ```
- **복구는 `docker restart` 가 아니라 `rm` + 재생성** 이어야 한다(NVIDIA 공식 문구: 컨테이너를 삭제 후 다시 만들어야 접근 회복). 단, 위 cgroupfs 전환 후에는 이마저 불필요.

## 대안 (systemd 드라이버 유지가 필요할 때): CDI
스택 다운·드라이버 변경을 피해야 하면 CDI 로. `provision_*.sh` 의 GPU 요청을 바꿔야 한다.
```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
# Docker CDI feature 활성(버전에 따라 daemon.json "features":{"cdi":true} + docker 재시작)
# provision: --gpus all  →  --device nvidia.com/gpu=all
```
toolkit 1.20 이 이미 `nvidia-cdi-refresh.service`(드라이버 변경 시 CDI 스펙 자동 갱신)를 설치해 둔다.

## 참고
- 이 호스트 GPU: RTX A5000 ×4 · Driver 580.82.07(Open Kernel Module) · CUDA 13.0 · Docker cgroup driver = **cgroupfs**(2026-09-07 전환).
- 상위: [`gpu-allocation.md`](gpu-allocation.md) · [`shared-infra-rules.md`](shared-infra-rules.md).
- 근거: NVIDIA Container Toolkit Troubleshooting(`native.cgroupdriver=cgroupfs`) · NOTICE issue #48 · issue #251(frontend major) · issue #1227(daemon-reload).
