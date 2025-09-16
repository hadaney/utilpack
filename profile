alias gpo='git push origin $(git branch --show-current)'

# HTTPS 방식으로 연결시 git 인증정보 파일로 캐시하기
git config --global credential.helper store
