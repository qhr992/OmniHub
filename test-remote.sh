#!/bin/bash
# End-to-end test of the terminal's remote features (ssh, SFTP, transfers,
# port forwards, proxies, Telnet) against throw-away servers on 127.0.0.1:
# a private sshd, a small web server, an HTTP CONNECT proxy that demands a
# password, and a Telnet-speaking login prompt. Nothing is shown on screen.
#
#   OMNIHUB_ADHOC=1 ./build.sh && ./test-remote.sh [output-dir]
set -uo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/OmniHub.app/Contents/MacOS/OmniHub"
OUT="${1:-$PWD/build/remote-test}"
WORK="$(mktemp -d /tmp/omnihub-rt.XXXXXX)"
SSH_PORT=22731; WEB_PORT=22732; PROXY_PORT=22733; TELNET_PORT=22734
PASSPHRASE="key-pass-123"; PROXY_PASSWORD="proxy-pass-456"
PIDS=()
# The test logs in to 127.0.0.1:$SSH_PORT, which ssh records in known_hosts.
# Take those lines out again (before and after), leaving the rest untouched.
forget_host() {
  local file="$HOME/.ssh/known_hosts"
  [ -f "$file" ] || return 0
  grep -q "^\[127\.0\.0\.1\]:$SSH_PORT " "$file" || return 0
  grep -v "^\[127\.0\.0\.1\]:$SSH_PORT " "$file" > "$WORK/known_hosts.keep"
  cat "$WORK/known_hosts.keep" > "$file"
}
cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; done
  forget_host
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/remote/sub folder" "$OUT"
echo hello > "$WORK/remote/hello world.txt"
echo inner > "$WORK/remote/sub folder/inner.txt"
# Big enough that the download is still running when progress is sampled.
dd if=/dev/urandom of="$WORK/remote/big.bin" bs=1m count=400 2>/dev/null

ssh-keygen -q -t ed25519 -N "" -f "$WORK/host_key"
ssh-keygen -q -t ed25519 -N "$PASSPHRASE" -f "$WORK/locked_key"
ssh-keygen -q -t ed25519 -N "" -f "$WORK/plain_key"
cat "$WORK/locked_key.pub" "$WORK/plain_key.pub" > "$WORK/authorized_keys"
cat > "$WORK/sshd_config" <<CONF
Port $SSH_PORT
ListenAddress 127.0.0.1
HostKey $WORK/host_key
AuthorizedKeysFile $WORK/authorized_keys
PidFile $WORK/sshd.pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
StrictModes no
AllowTcpForwarding yes
Subsystem sftp /usr/libexec/sftp-server
CONF
/usr/sbin/sshd -D -e -f "$WORK/sshd_config" 2>"$WORK/sshd.log" & PIDS+=($!)

(cd "$WORK/remote" && exec python3 -m http.server "$WEB_PORT" --bind 127.0.0.1 >/dev/null 2>&1) & PIDS+=($!)

cat > "$WORK/proxy.py" <<'PY'
import base64, socket, sys, threading
port, password, log = int(sys.argv[1]), sys.argv[2], sys.argv[3]
want = "Basic " + base64.b64encode(("proxyuser:" + password).encode()).decode()
def pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data: break
            b.sendall(data)
    except OSError: pass
    for s in (a, b):
        try: s.shutdown(socket.SHUT_RDWR)
        except OSError: pass
def serve(client):
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = client.recv(4096)
        if not chunk: return
        head += chunk
    lines = head.split(b"\r\n\r\n")[0].decode().split("\r\n")
    auth = next((l.split(":", 1)[1].strip() for l in lines if l.lower().startswith("proxy-authorization:")), "")
    if auth != want:
        open(log, "a").write("auth-FAILED\n")
        client.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n"); client.close(); return
    open(log, "a").write("auth-ok " + lines[0] + "\n")
    host, target = lines[0].split()[1].rsplit(":", 1)
    upstream = socket.create_connection((host, int(target)))
    client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    pipe(upstream, client)
server = socket.socket(); server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port)); server.listen(8)
while True:
    conn, _ = server.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
PY
python3 "$WORK/proxy.py" "$PROXY_PORT" "$PROXY_PASSWORD" "$WORK/proxy.log" & PIDS+=($!)

cat > "$WORK/telnetd.py" <<'PY'
import socket, sys
IAC, WILL, DO, ECHO, SGA = 255, 251, 253, 1, 3
def read_line(conn):
    out = b""
    while True:
        b = conn.recv(1)
        if not b: return out
        if b[0] == IAC:            # skip the client's 3-byte replies
            conn.recv(2); continue
        if b in (b"\r", b"\n"):
            if b == b"\r": conn.recv(1)   # CR NUL / CR LF
            return out
        out += b
server = socket.socket(); server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", int(sys.argv[1]))); server.listen(4)
while True:
    conn, _ = server.accept()
    try:
        conn.sendall(bytes([IAC, WILL, ECHO, IAC, WILL, SGA, IAC, DO, 31]))
        conn.sendall(b"Test telnet server\r\nlogin: ")
        user = read_line(conn)
        conn.sendall(user + b"\r\nPassword: ")
        password = read_line(conn)
        conn.sendall(b"\r\nWELCOME " + user + b" " + str(len(password)).encode() + b"\r\n$ ")
        conn.recv(1024)
    except OSError: pass
    conn.close()
PY
python3 "$WORK/telnetd.py" "$TELNET_PORT" & PIDS+=($!)

sleep 1.5
forget_host
export OMNIHUB_TEST_SSH_PORT=$SSH_PORT OMNIHUB_TEST_WEB_PORT=$WEB_PORT OMNIHUB_TEST_HTTP_PROXY_PORT=$PROXY_PORT
export OMNIHUB_TEST_TELNET_PORT=$TELNET_PORT OMNIHUB_TEST_KEY="$WORK/locked_key" OMNIHUB_TEST_PLAIN_KEY="$WORK/plain_key"
export OMNIHUB_TEST_KEY_PASSPHRASE="$PASSPHRASE" OMNIHUB_TEST_PROXY_PASSWORD="$PROXY_PASSWORD"
# Passwords the test saves go to a Keychain service of their own, not the real vault.
export OMNIHUB_VAULT_SERVICE="com.local.omnihub.vault.remote-test"
export OMNIHUB_TEST_REMOTE_DIR="$WORK/remote" OMNIHUB_TEST_PROXY_LOG="$WORK/proxy.log"
"$APP" --remote-selftest "$OUT"
STATUS=$?
# The downloaded copies (a 400 MB file among them) were only needed for the
# size checks: keep the report and screenshots, not the payload.
rm -rf "${OUT:?}/downloads"
if [ $STATUS -ne 0 ]; then echo "--- sshd log ---"; tail -15 "$WORK/sshd.log"; fi
exit $STATUS
