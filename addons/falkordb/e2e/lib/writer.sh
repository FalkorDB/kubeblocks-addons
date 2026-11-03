#!/bin/bash
# The client fdb_start_writer runs in its own pod (see lib/falkordb.sh). It is
# bash rather than POSIX sh: it runs in the FalkorDB image, not on the runner.
#
# Writes RPUSHes through $HOST:$PORT until /tmp/stop exists, and logs each one
# the server acknowledged as "<ms> <value>": one new connection per write in
# new.acked, a single long-lived connection in persist.acked (reopened only when
# it drops). Any other reply goes to the matching .err file. The password is in
# REDISCLI_AUTH; TLS=true talks TLS. Each run writes to keys of its own, named
# after RUN.
cd /tmp || exit 1
# A write to a connection the server closed (a demoted primary drops its
# clients) must fail and reconnect, not kill the writer with SIGPIPE.
trap '' PIPE
: > new.acked; : > new.err; : > persist.acked; : > persist.err

now_ms() { date +%s%3N; }

new_connections() {
  local i=0 reply tls_flags=""
  [ "$TLS" = true ] && tls_flags="--tls --insecure"
  while [ ! -f stop ]; do
    i=$((i + 1))
    reply=$(timeout 2 redis-cli $tls_flags -h "$HOST" -p "$PORT" RPUSH "e2e:writer:$RUN:new" "$i" 2>&1)
    case "$reply" in
      ''|*[!0-9]*) echo "$(now_ms) $i ${reply//$'\n'/ }" >> new.err ;;
      *) echo "$(now_ms) $i" >> new.acked ;;
    esac
    sleep 0.05
  done
}

# The long-lived connection speaks RESP itself, so that every reply is read for
# the command it answers: redis-cli in a pipe can lose that pairing on errors.
resp_send() {
  local fd="$1" arg
  shift
  printf '*%d\r\n' "$#" >&"$fd" || return 1
  for arg in "$@"; do
    printf '$%d\r\n%s\r\n' "${#arg}" "$arg" >&"$fd" || return 1
  done
}

persistent_connection() {
  local i=0 reply rfd wfd
  while [ ! -f stop ]; do
    if [ "$TLS" = true ]; then
      coproc CONN { exec openssl s_client -quiet -connect "$HOST:$PORT" 2>/dev/null; }
      rfd=${CONN[0]}; wfd=${CONN[1]}
    else
      exec {rfd}<>"/dev/tcp/$HOST/$PORT" 2>/dev/null || { sleep 0.5; continue; }
      wfd=$rfd
    fi
    if [ -n "$REDISCLI_AUTH" ]; then
      resp_send "$wfd" AUTH "$REDISCLI_AUTH" && IFS= read -r -t 5 reply <&"$rfd"
    fi
    while [ ! -f stop ]; do
      i=$((i + 1))
      resp_send "$wfd" RPUSH "e2e:writer:$RUN:persist" "$i" 2>/dev/null || break
      if ! IFS= read -r -t 10 reply <&"$rfd"; then
        echo "$(now_ms) $i connection closed or no reply" >> persist.err
        break
      fi
      reply=${reply%$'\r'}
      case "$reply" in
        :*) echo "$(now_ms) $i" >> persist.acked ;;
        *) echo "$(now_ms) $i $reply" >> persist.err ;;
      esac
      sleep 0.05
    done
    if [ "$TLS" = true ]; then
      kill "$CONN_PID" 2>/dev/null; wait "$CONN_PID" 2>/dev/null
    else
      exec {rfd}>&-
    fi
    # the connection failed or dropped; while the Service has no endpoint,
    # reconnecting at once would only start process after process
    [ -f stop ] || sleep 0.5
  done
}

new_connections &
persistent_connection &
until [ -f stop ]; do sleep 0.5; done
wait
# both streams have logged their last write; fdb_check_writer waits for this
touch done
# stay up, so the logs can still be read after the writers have stopped
exec sleep infinity
