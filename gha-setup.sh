#!/bin/bash
# Oracle Cloud Shell 에서 1번만 실행: GitHub Actions 용 API 키를 만들어 내 계정에 등록하고, GitHub Secrets 에 넣을 값을 보여줌
set -e
D=~/gha; mkdir -p "$D"
USER_ID="${OCI_CS_USER_OCID:-}"
[ -z "$USER_ID" ] && USER_ID=$(oci iam user list -c "$OCI_TENANCY" --all --query "data[?contains(name,'khs1109k')].id | [0]" --raw-output)
[ -z "$USER_ID" ] || [ "$USER_ID" = "null" ] && { echo "사용자 OCID를 못 찾았어요 (콘솔 > My profile > OCID 복사 후 USER_ID=... bash gha-setup.sh)"; exit 1; }
[ -f "$D/key.pem" ] || { openssl genrsa -out "$D/key.pem" 2048 2>/dev/null; openssl rsa -pubout -in "$D/key.pem" -out "$D/pub.pem" 2>/dev/null; }
FP=$(oci iam user api-key upload --user-id "$USER_ID" --key-file "$D/pub.pem" --query 'data.fingerprint' --raw-output 2>/dev/null || true)
[ -z "$FP" ] && FP=$(openssl rsa -pubin -in "$D/pub.pem" -outform DER 2>/dev/null | openssl md5 -c | awk '{print $2}')
[ -f ~/.ssh/id_rsa.pub ] || ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa >/dev/null
cat <<MSG

==== GitHub 저장소 > Settings > Secrets and variables > Actions > New repository secret ====
(아래 값은 이 화면에만 보여요. 채팅에는 붙여넣지 마세요)

OCI_USER        = $USER_ID
OCI_TENANCY     = $OCI_TENANCY
OCI_FINGERPRINT = $FP
SSH_PUB         = $(cat ~/.ssh/id_rsa.pub)

OCI_KEY  = 아래 줄부터 END 줄까지 전부
$(cat "$D/key.pem")

※ 새 A1 서버 접속용 열쇠: Menu > Download 로 ~/.ssh/id_rsa 를 PC에 꼭 받아 두세요 (이번처럼 잃어버리면 접속 못 해요)
MSG
