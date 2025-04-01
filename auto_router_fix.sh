#!/bin/bash

# 設定ファイルの読み込み（スクリプトと同じディレクトリにあることを想定）
SCRIPT_DIR=$(cd $(dirname $0); pwd)
source "${SCRIPT_DIR}/config.sh"

# ログ出力用関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# 指定されたページからセッションIDを取得する関数
get_session_id() {
    local page="$1"
    curl -fsL "${ROUTER_ADDR}/${page}" | \
        grep -o '<input type="hidden" name="nosave_session_num" value=".*">' | \
        grep -o 'value=".*"' | tr -d 'value="'
}

# エラーがあった場合にログ出力して終了する関数
check_error() {
    local result="$1"
    local action="$2"
    if [[ -n "$result" ]]; then
        log "$action failed: $result"
        exit 1
    fi
}

# ルーターの再起動を実行する関数
reboot_router() {
    # ログイン用セッションIDの取得
    local session_id
    session_id="$(get_session_id "login.html")"
    if [[ -z "$session_id" ]]; then
        log "Couldn't get login session ID"
        exit 1
    fi

    # ログイン処理
    local login_response
    login_response="$(curl -X POST -d "nosave_Username=${ROUTER_USER}&nosave_Password=${ROUTER_PASS}&MobileDevice=0&nosave_session_num=${session_id}" -fsL "${ROUTER_ADDR}/login.html" --http0.9)"
    local login_error
    login_error="$(echo "$login_response" | grep 'ERROR' | tr -d '<>tile/')"
    check_error "$login_error" "Login"

    # init用セッションIDの再取得
    session_id="$(get_session_id "init.html")"
    if [[ -z "$session_id" ]]; then
        log "Couldn't get init session ID"
        exit 1
    fi

    # 再起動リクエスト送信
    local reboot_response
    reboot_response="$(curl -X POST -d "nosave_reboot=1&nosave_session_num=${session_id}" -fsL "${ROUTER_ADDR}/init.html" --http0.9)"
    local reboot_error
    reboot_error="$(echo "$reboot_response" | grep 'ERROR' | tr -d '<>tile/')"
    check_error "$reboot_error" "Reboot"
    
    log "Router reboot command sent successfully."
}

# 疎通テストを実施する関数
check_connectivity() {
    local exit_code=1
    if [ "$DEBUG" = "true" ]; then
        exit_code="$DEBUG_PING_RESULT"
        log "DEBUGモード: ping結果として '$DEBUG_PING_RESULT' を使用します。"
    else
        for host in "${PING_HOSTS[@]}"; do
            echo -n "Pinging ${host}... " 1>&2
            if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" > /dev/null 2>&1; then
                echo "succeeded." 1>&2
                exit_code=0
                break
            else
                echo "failed." 1>&2
            fi
        done
    fi
    return $exit_code
}

# メイン処理
if check_connectivity; then
    log "Connectivity test succeeded."
    # 接続確認成功の場合、再試行カウンタをリセット
    [ -f "$STATE_FILE" ] && rm -f "$STATE_FILE"
    exit 0
else
    log "Connectivity test failed."
    current_time=$(date +%s)
    offline_start=""
    retry_count=0

    if [ -f "$STATE_FILE" ]; then
        # STATE_FILEの1行目がoffline_start、2行目がretry_count
        read -r offline_start < "$STATE_FILE"
        read -r retry_count < <(sed -n '2p' "$STATE_FILE")
    else
        offline_start="$current_time"
        retry_count=0
    fi

    # オフライン継続時間を計算（秒単位）
    elapsed_time=$(( current_time - offline_start ))
    log "Offline duration: ${elapsed_time}秒 (Threshold: ${DOWNTIME_THRESHOLD}分)"
    if [ "$elapsed_time" -ge $(($DOWNTIME_THRESHOLD * 60)) ]; then
        if [ "$retry_count" -lt "$MAX_RETRY_COUNT" ]; then
            log "Offline duration exceeds threshold. Attempting to reboot router..."
            reboot_router
            retry_count=$((retry_count + 1))
        else
            log "Retry limit exceeded. Router reboot will not be executed."
        fi
    else
        log "Offline duration has not reached threshold. Waiting..."
    fi

    # offline_startとretry_countをSTATE_FILEに保存
    {
        echo "$offline_start"
        echo "$retry_count"
    } > "$STATE_FILE"
fi
