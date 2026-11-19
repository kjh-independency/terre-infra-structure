# S3 백업 버킷과 GitHub OIDC 역할 만들기 (AWS CloudShell에서 실행)
# 자리표시자: <BUCKET>, <GITHUB_OIDC_SUB>
#   <GITHUB_OIDC_SUB> 는 GitHub가 보내는 실제 sub 값. 계정·저장소 고유 번호가 붙은 형식일 수 있으니
#   첫 실행 실패 시 CloudTrail의 AssumeRoleWithWebIdentity 기록에서 실제 값을 확인해 넣는다.
set -euo pipefail
B=<BUCKET>; R=ap-northeast-2; RN=lab-backup-gha
SUB='<GITHUB_OIDC_SUB>'
ACC=$(aws sts get-caller-identity --query Account --output text)

# 1) 버킷: 서울, 퍼블릭 차단, 기본 암호화(SSE-S3), 버전 관리
aws s3api create-bucket --bucket $B --region $R --create-bucket-configuration LocationConstraint=$R
aws s3api put-public-access-block --bucket $B --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket $B --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-versioning --bucket $B --versioning-configuration Status=Enabled

# 2) 수명 주기: 7일 뒤 삭제, 이전 버전 1일 뒤 삭제, 덜 올라간 조각 1일 뒤 삭제
aws s3api put-bucket-lifecycle-configuration --bucket $B --lifecycle-configuration '{"Rules":[{"ID":"lab-db-7d","Status":"Enabled","Filter":{"Prefix":"lab-db/"},"Expiration":{"Days":7},"NoncurrentVersionExpiration":{"NoncurrentDays":1},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}'

# 3) HTTPS 가 아닌 접근은 모두 거부
aws s3api put-bucket-policy --bucket $B --policy '{"Version":"2012-10-17","Statement":[{"Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::'$B'","arn:aws:s3:::'$B'/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}'

# 4) GitHub OIDC 공급자(없을 때만)
P=arn:aws:iam::$ACC:oidc-provider/token.actions.githubusercontent.com
aws iam get-open-id-connect-provider --open-id-connect-provider-arn $P >/dev/null 2>&1 || aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com

# 5) 역할: 이 저장소 main 브랜치 워크플로만 받을 수 있고, 권한은 lab-db/ 에 올리기만(읽기·지우기 없음)
aws iam create-role --role-name $RN --max-session-duration 3600 --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"'$P'"},"Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringEquals":{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com","token.actions.githubusercontent.com:sub":"'$SUB'"}}}]}' --query Role.Arn --output text
aws iam put-role-policy --role-name $RN --policy-name put-lab-db-only --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::'$B'/lab-db/*"}]}'
echo DONE
