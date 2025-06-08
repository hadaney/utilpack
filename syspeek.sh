#!/bin/bash
set -euo pipefail

function run_cmd() {
  echo -e "\n▶ 실행 명령어: $*"
  eval "$@"
}

function check_process_or_top_usage() {
  read -p "확인할 프로세스명을 입력하세요 (비워두면 상위 사용량 프로세스 출력): " pname
  if [[ -z "$pname" ]]; then
    echo "🧠 전체 리소스 상태"

    mem_info=$(free -m)
    top_info=$(top -bn1 | head -5)

    mem_used_mi=$(echo "$mem_info" | awk '/^Mem:/ {print $3}')
    mem_total_mi=$(echo "$mem_info" | awk '/^Mem:/ {print $2}')
    mem_used_gi=$(awk "BEGIN {printf \"%.1f\", $mem_used_mi/1024}")
    mem_total_gi=$(awk "BEGIN {printf \"%.1f\", $mem_total_mi/1024}")
    mem_percent=$(awk "BEGIN {printf \"%.1f\", $mem_used_mi/$mem_total_mi*100}")

    swap_used=$(echo "$mem_info" | awk '/^Swap:/ {print $3}')
    swap_total=$(echo "$mem_info" | awk '/^Swap:/ {print $2}')
    swap_percent=$(awk "BEGIN {printf \"%.1f\", $swap_used/$swap_total*100}")

    cpu_user=$(echo "$top_info" | grep "%Cpu(s):" | awk '{print $2}')

    echo "전체 메모리 사용률: ${mem_used_gi}GiB / ${mem_total_gi}GiB (${mem_percent}%)"
    echo "전체 Swap 메모리 사용률: ${swap_used}MiB / ${swap_total}MiB (${swap_percent}%)"
    echo "전체 CPU 사용률: ${cpu_user}%"

    echo "🔥 CPU 사용량 상위 10개"
    run_cmd "ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 11"
    echo "🔥 메모리 사용량 상위 10개"
    run_cmd "ps -eo pid,comm,%cpu,%mem --sort=-%mem | head -n 11"
  else
    echo "[$pname] 프로세스 상세정보:"
    run_cmd "ps -ef | grep -i $pname | grep -v grep || echo '해당 프로세스 없음'"
  fi
}

function check_system_status() {
  echo "📊 시스템 상태:"
  run_cmd "uptime"
  run_cmd "df -h"
  run_cmd "free -m"
}

function check_system_log() {
  echo "📋 시스템 로그 확인:"
  run_cmd "sudo tail -n 50 /var/log/messages || sudo tail -n 50 /var/log/syslog"
}

function check_package() {
  read -p "확인할 패키지명을 입력하세요 (비워두면 전체 목록 안내): " pkg
  if [[ -z "$pkg" ]]; then
    echo "패키지명을 지정하지 않았습니다. 전체 목록을 보려면 다음을 실행하세요:"
    echo "▶ sudo yum list installed  또는  dpkg -l"
    return
  fi

  if command -v dpkg &>/dev/null; then
    run_cmd "dpkg -l | grep -i $pkg || echo '패키지 없음'"
  elif command -v rpm &>/dev/null; then
    run_cmd "rpm -qa | grep -i $pkg || echo '패키지 없음'"
  else
    echo "❌ 지원하지 않는 패키지 관리자"
  fi
}

function check_ports() {
  read -p "확인할 포트번호를 입력하세요 (비워두면 전체): " port
  if command -v ss &>/dev/null; then
    [[ -z "$port" ]] && run_cmd "sudo ss -tulnp" || run_cmd "sudo ss -tulnp | grep ':$port'"
  else
    [[ -z "$port" ]] && run_cmd "netstat -tulnp" || run_cmd "netstat -tulnp | grep ':$port'"
  fi
}

function print_top_services() {
  echo "📌 현재 CPU 사용량 기준 상위 서비스:"
  ps -eo pid,%cpu,cmd --sort=-%cpu | head -n 20 | awk 'NR>1 {print $1}' |
    xargs -r -n1 bash -c 'sudo cat /proc/$0/cgroup 2>/dev/null | grep "name=systemd" | sed "s|.*system.slice/||;s|.service.*||"' |
    sort | uniq -c | sort -nr | head -n 10
}

function check_service_status() {
  print_top_services
  read -p "확인할 서비스명을 입력하세요 (예: sshd, nginx): " service
  if command -v systemctl &>/dev/null; then
    run_cmd "systemctl status $service"
  else
    run_cmd "service $service status"
  fi
}

function check_service_logs() {
  print_top_services
  read -p "로그를 확인할 서비스명을 입력하세요: " service
  if command -v journalctl &>/dev/null; then
    run_cmd "sudo journalctl -u $service -n 50 --no-pager"
  else
    echo "journalctl 이 없으면 /var/log/messages 참고:"
    run_cmd "sudo grep -i $service /var/log/messages | tail -n 50"
  fi
}

function check_io_top() {
  echo "📈 디스크 IO가 높은 프로세스:"
  if command -v iotop &>/dev/null; then
    run_cmd "sudo -n iotop -b -n 1 | head -n 20 || true"
  else
    echo "iotop 이 없으면 ps 기반으로 대체:"
    run_cmd "ps -eo pid,comm,io --sort=-io | head -n 15"
  fi
}

function check_login_history() {
  echo "👥 최근 로그인 사용자:"
  run_cmd "last -a | head -n 20"
}

function map_pid_to_container() {
  read -p "확인할 PID를 입력하세요: " pid
  if sudo test -f "/proc/$pid/cgroup"; then
    echo "🔍 $pid 가 속한 컨테이너 정보:"
    sudo cat "/proc/$pid/cgroup" | grep "docker\\|kubepods" || echo "컨테이너 정보 없음"
  else
    echo "해당 PID가 존재하지 않거나 접근할 권한이 없습니다."
  fi
}

function map_container_to_pid() {
  read -p "확인할 컨테이너 이름 또는 ID 일부를 입력하세요: " cname
  echo "🔍 컨테이너 [$cname]에 속한 프로세스들:"
  docker inspect --format '{{.State.Pid}}' "$cname" 2>/dev/null && return
  docker ps -q --filter "name=$cname" | while read cid; do
    echo "컨테이너 $cid:"
    docker top "$cid" || echo "docker top 실패"
  done
}

# Main Menu
while true; do
  echo -e "\n=== 실행할 작업을 선택하세요 ==="
  echo "a. 프로세스 상세 확인 또는 CPU/MEM 사용률 보기"
  echo "b. 시스템 상태 확인"
  echo "c. 시스템 로그 확인"
  echo "d. 패키지 설치 여부 확인"
  echo "e. 포트, 네트워크 사용 확인"
  echo "g. 서비스 상태 확인"
  echo "h. 서비스 로그 확인"
  echo "i. 디스크 IO Top 프로세스"
  echo "j. 사용자 로그인 기록 보기"
  echo "k. PID → 컨테이너 ID 매핑"
  echo "l. 컨테이너 이름 → 프로세스 역매핑"
  echo "q. 종료"

  read -rp "선택 (a~l, q): " choice

  case "$choice" in
    a) check_process_or_top_usage ;;
    b) check_system_status ;;
    c) check_system_log ;;
    d) check_package ;;
    e) check_ports ;;
    g) check_service_status ;;
    h) check_service_logs ;;
    i) check_io_top ;;
    j) check_login_history ;;
    k) map_pid_to_container ;;
    l) map_container_to_pid ;;
    q) echo "종료합니다."; exit 0 ;;
    *) echo "❗ 잘못된 선택입니다." ;;
  esac
done

