#!/bin/sh
# PocketSSH connect helper. Usage: ./ssh.sh [command...]
# Password lives in .ssh_password (gitignored).
DIR=$(dirname "$0")
PW=$(cat "$DIR/.ssh_password" 2>/dev/null | tr -d '\r\n')
HOST=${POCKETSSH_HOST:-192.168.2.102}
ASK="$DIR/.askpass.sh"
printf '#!/bin/sh\necho %s\n' "$PW" > "$ASK"
chmod +x "$ASK"
SSH_ASKPASS="$ASK" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
  ssh -o StrictHostKeyChecking=no -p 2222 "momo@$HOST" "$@"
