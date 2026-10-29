#!/bin/bash
# The smoke check (Task 4.7): runs the built app bundle once against a local stub server and checks what it logged.
#
#   scripts/smoke.sh [--no-build]
#
#   --no-build  uses build/menubar-monitor.app as it is, instead of running ./build.sh first
#
# 1. It builds the bundle and starts a python3 stub server on 127.0.0.1, which answers with the fixtures that
#    Tests/Fixtures/Smoke/routes.json names, and records each request.
# 2. It runs `menubar-monitor --smoke`, which runs the launch steps, one Jenkins check and one GitLab load, then exits.
# 3. It checks the exit code, the Activity entries, the requests and the cache files.
#
# Nothing touches the user's data or screen: the files go into a temporary MENUBAR_MONITOR_DATA_DIR, the preferences
# into a UserDefaults suite of their own, the tokens are made up and stay in memory, and --smoke runs no
# NSApplication, so no status item, window, banner or sound appears.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build=true
for arg in "$@"; do
	case $arg in
	--no-build) build=false ;;
	*)
		echo "usage: $0 [--no-build]" >&2
		exit 2
		;;
	esac
done

cd "$root"
if $build; then
	./build.sh
fi
app=$root/build/menubar-monitor.app
if [[ ! -x $app/Contents/MacOS/menubar-monitor ]]; then
	echo "no app at $app: run ./build.sh first" >&2
	exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/menubar-monitor-smoke.XXXXXX")
server=
cleanup() {
	if [[ -n $server ]]; then
		kill "$server" 2>/dev/null || true
	fi
	rm -rf "$work"
}
trap cleanup EXIT

# The stub server. It refuses a request without the right kind of Authorization header, as Jenkins and GitLab would,
# and writes one JSON line per request: method, path with query, the GraphQL operation and the auth scheme.
python3 -I - "$root/Tests/Fixtures" "$work/port" "$work/requests.jsonl" <<'PY' &
import http.server, json, re, sys

fixtures, port_file, requests_file = sys.argv[1:4]
routes = json.load(open(f"{fixtures}/Smoke/routes.json"))

class Stub(http.server.BaseHTTPRequestHandler):
    def answer(self, status, file=None):
        body = open(f"{fixtures}/{file}", "rb").read() if file else b"{}"
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def record(self, scheme, operation=None):
        with open(requests_file, "a") as out:
            out.write(json.dumps({"method": self.command, "path": self.path, "operation": operation, "auth": scheme}) + "\n")

    def scheme(self):
        return self.headers.get("Authorization", "").split(" ")[0] or None

    def do_GET(self):
        path, _, query = self.path.partition("?")
        self.record(self.scheme())
        if self.scheme() != "Basic":
            return self.answer(401)
        for route in routes["jenkins"]:
            if re.search(route["path"], path) and route.get("query", "") in query:
                return self.answer(200, route["file"])
        self.answer(404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        match = re.search(r"\b(?:query|mutation)\s+(\w+)", body.get("query", ""))
        operation = match.group(1) if match else None
        self.record(self.scheme(), operation)
        if self.path != "/api/graphql":
            return self.answer(404)
        if self.scheme() != "Bearer":
            return self.answer(401)
        file = routes["graphql"].get(operation)
        self.answer(200 if file else 404, file)

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stub)
with open(port_file, "w") as out:
    out.write(str(server.server_address[1]))
server.serve_forever()
PY
server=$!
# Not a job of this shell any more, so killing it at the end prints no "Terminated" notice.
disown "$server"
for _ in $(seq 50); do
	[[ -s $work/port ]] && break
	sleep 0.1
done
if [[ ! -s $work/port ]]; then
	echo "the stub server didn't start" >&2
	exit 2
fi
port=$(cat "$work/port")

status=0
MENUBAR_MONITOR_DATA_DIR=$work/data "$app/Contents/MacOS/menubar-monitor" --smoke --stub "http://127.0.0.1:$port" \
	>"$work/smoke.out" 2>&1 || status=$?
sed 's/^/  /' "$work/smoke.out"

# The checks, on what the app logged, what the stub saw and what the app stored.
python3 -I - "$status" "$work/data" "$work/requests.jsonl" <<'PY'
import json, os, sys

status, data, requests_file = int(sys.argv[1]), sys.argv[2], sys.argv[3]
log_file = f"{data}/Logs/menubar-monitor.log"
entries = [json.loads(line) for line in open(log_file)] if os.path.exists(log_file) else []
requests = [json.loads(line) for line in open(requests_file)] if os.path.exists(requests_file) else []
failures = []

def check(ok, what):
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        failures.append(what)

def logged(source, text):
    return any(e["source"] == source and text in e["message"] for e in entries)

operations = {r["operation"] for r in requests if r["operation"]}
check(status == 0, f"the app exits with 0 (got {status})")
check(bool(entries), "the Activity log is in MENUBAR_MONITOR_DATA_DIR")
check(logged("app", "jenkins-menubar"), "the import at launch is logged")
check(any(r["path"].startswith("/job/project/api/json?tree=jobs") for r in requests), "the check asks Jenkins for the jobs")
check(any(r["path"].startswith("/job/project/job/MR-1/api/json") for r in requests), "the check asks for my job MR-1")
check("CurrentUser" in operations, "the check asks GitLab for the username")
check("MergeRequests" in operations, "the GitLab load asks for the merge requests")
check("WorkItems" in operations, "the GitLab load asks for the work items")
check(all(r["auth"] == ("Bearer" if r["method"] == "POST" else "Basic") for r in requests), "every request has its kind of auth")
check(not any("smoke-" in r["path"] for r in requests), "no token in a URL")
check(not any(e["level"] == "error" for e in entries), "no error in the Activity log")
for cache in ["jenkins", "merge-request-list", "work-items"]:
    check(os.path.exists(f"{data}/Caches/main/{cache}.json"), f"the {cache} cache is written")
sys.exit(1 if failures else 0)
PY
