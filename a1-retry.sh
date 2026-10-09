#!/bin/bash
# 오라클 A1(ARM 4코어/24GB 무료) 자동 재시도 생성 스크립트 — Oracle Cloud Shell 에서 실행
# 값은 전부 자동으로 찾음 (직접 export 할 필요 없음). 이미 A1이 있으면 생성 안 함.
OCPU=${OCPU:-4}; MEM=${MEM:-24}; WAIT=${WAIT:-60}; NAME=${NAME:-a1-openclaw}; MAX_ROUNDS=${MAX_ROUNDS:-0}  # 0=무한, GitHub Actions 는 3
LOG=~/a1-retry.log
say(){ echo "[$(date '+%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

T="${OCI_TENANCY:-$(oci iam compartment list --all --compartment-id-in-subtree false --query 'data[0]."compartment-id"' --raw-output 2>/dev/null)}"
C="${COMPARTMENT_ID:-$T}"
[ -z "$C" ] && { say "테넌시 ID를 못 찾았어요. Oracle Cloud Shell 에서 실행했는지 확인하세요."; exit 1; }
say "구획: ${C:0:30}..."

# 이미 A1 인스턴스가 있으면 중단
HAVE=$(oci compute instance list -c "$C" --all --query "data[?shape=='VM.Standard.A1.Flex' && \"lifecycle-state\"!='TERMINATED'] | length(@)" --raw-output 2>/dev/null)
[ "${HAVE:-0}" -gt 0 ] && { say "이미 A1 인스턴스가 ${HAVE}개 있어요. 생성 안 함."; exit 0; }

# 가용 도메인 전부
mapfile -t ADS < <(oci iam availability-domain list -c "$C" --query 'data[].name' --raw-output | tr -d '[]", ' | grep -v '^$')
[ ${#ADS[@]} -eq 0 ] && { say "가용 도메인을 못 찾았어요"; exit 1; }
say "가용 도메인: ${ADS[*]}"

# 서브넷 (공용 서브넷 우선)
SUB="${SUBNET_ID:-$(oci network subnet list -c "$C" --all --query "data[?\"prohibit-public-ip-on-vnic\"==\`false\`] | [0].id" --raw-output 2>/dev/null)}"
[ -z "$SUB" ] || [ "$SUB" = "null" ] && SUB=$(oci network subnet list -c "$C" --all --query 'data[0].id' --raw-output 2>/dev/null)
if [ -z "$SUB" ] || [ "$SUB" = "null" ]; then say "서브넷이 없어요. 콘솔 > 네트워킹 > VCN 마법사로 '인터넷 연결 VCN'을 먼저 만드세요."; exit 1; fi
say "서브넷: ${SUB:0:40}..."

# A1(aarch64)용 우분투 최신 이미지
IMG="${IMAGE_ID:-$(oci compute image list -c "$C" --operating-system "Canonical Ubuntu" --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC --query 'data[0].id' --raw-output 2>/dev/null)}"
[ -z "$IMG" ] || [ "$IMG" = "null" ] && { say "A1용 우분투 이미지를 못 찾았어요"; exit 1; }
say "이미지: $(oci compute image get --image-id "$IMG" --query 'data."display-name"' --raw-output)"

# SSH 키 (없으면 만듦)
[ -f ~/.ssh/id_rsa.pub ] || ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa >/dev/null
# 형식 오류(CannotParseRequest) 방지: JSON 은 파일로 넘김
echo "{\"ocpus\": $OCPU, \"memoryInGBs\": $MEM}" > ~/a1-shape.json

n=0; r=0
while true; do
  for AD in "${ADS[@]}"; do
    n=$((n+1))
    OUT=$(oci compute instance launch -c "$C" --availability-domain "$AD" --display-name "$NAME" \
      --shape VM.Standard.A1.Flex --shape-config file://$HOME/a1-shape.json \
      --image-id "$IMG" --subnet-id "$SUB" --assign-public-ip true \
      --boot-volume-size-in-gbs 100 --ssh-authorized-keys-file ~/.ssh/id_rsa.pub 2>&1)
    if echo "$OUT" | grep -q '"lifecycle-state"'; then
      say "✅ 생성 성공! ($AD, ${n}번째 시도)"; echo "$OUT" | grep -E '"id"|"lifecycle-state"' | head -3 | tee -a "$LOG"
      say "몇 분 뒤 콘솔 > 인스턴스에서 공인 IP 확인 → ssh -i ~/.ssh/id_rsa ubuntu@IP"
      if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d chat_id="$TG_CHAT" --data-urlencode text="✅ 오라클 A1 서버 생성 성공 ($AD, ${n}번째 시도). 콘솔에서 공인 IP 확인하고 GitHub Actions 워크플로는 꺼줘." >/dev/null; fi
      exit 0
    fi
    MSG=$(echo "$OUT" | grep -oE '"(code|message)": "[^"]*"' | tr '\n' ' ')
    case "$OUT" in
      *"Out of host capacity"*|*"OutOfHostCapacity"*|*"TooManyRequests"*|*"InternalError"*) say "${n}번째: 자리 없음 ($AD) — 계속 시도";;
      *"LimitExceeded"*|*"QuotaExceeded"*) say "❌ 한도 초과: 무료 A1 합계는 4코어/24GB. OCPU/MEM 을 줄이거나 기존 A1을 정리하세요. $MSG"; exit 1;;
      *) say "❌ 다른 오류라 멈춤 ($AD): ${MSG:-$(echo "$OUT" | tail -3)}"; exit 1;;
    esac
  done
  r=$((r+1)); if [ "$MAX_ROUNDS" -gt 0 ] && [ "$r" -ge "$MAX_ROUNDS" ]; then say "이번 실행은 ${r}바퀴로 끝 (다음 예약 실행에서 계속)"; exit 0; fi
  sleep "$WAIT"
done
