#!/usr/bin/env bash
# ⛔ DEPRECATED — 이 스크립트는 더 이상 쓰지 않는다.
#
# 예전에는 개인 PG/Redis 를 '호스트 레벨 sibling 컨테이너'로 띄우고 공유 piascope
# 네트워크에 붙였다 → 그게 바로 우리가 없애려는 '호스트 인프라 꼬임'의 축소판이었다
# (docker ps 오염 · 호스트 포트 점유 · 공유망 결합). 게다가 새 격리 모델에서는
# 개발자에게 docker 그룹이 없어서 이 스크립트 자체가 동작하지 않는다.
#
# ✅ 대체: 개인 테스트 인프라는 '컨테이너 안'에서 로컬 프로세스로 띄운다.
#     (컨테이너에 ssh 로 접속한 뒤)
#       devstores up      # 127.0.0.1:6379(redis) · 127.0.0.1:5432(pg, db=dev)
#       devstores info | status | down | reset
#
# 배경: docs/shared-infra-rules.md (상태 생산 의존 = 컨테이너 안 · 공유는 읽기전용 예외)
echo "⛔ dev_stores.sh 는 폐지됐습니다. 컨테이너 안에서 'devstores up' 을 쓰세요." >&2
echo "   (호스트 레벨 개인 스토어는 인프라 꼬임의 원인이라 제거됨 — shared-infra-rules.md)" >&2
exit 1
