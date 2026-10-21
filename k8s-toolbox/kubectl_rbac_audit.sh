#!/usr/bin/env bash
# kubectl_rbac_audit.sh
# Read-only RBAC review: who is bound to cluster-admin, which roles grant
# wildcards or escalate/bind/impersonate, which bindings hand rights to a
# default ServiceAccount or point at a role that no longer exists, and which
# bound roles can read Secrets. Prints the next command; never runs it.
#
# Usage:
#   ./kubectl_rbac_audit.sh [--namespace NS] [--context CTX] [--all-namespaces]
#                           [--only CHECK[,CHECK...]] [--list-checks]
#                           [--include-system]
#
# Exit codes:
#   0 findings reported
#   1 query or JSON parsing failed
#   2 kubectl or python3 missing / cannot reach cluster
#   3 bad arguments (including an unknown or empty --only)
#   4 nothing to report
set -euo pipefail

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}

CHECKS=(
  "cluster-admin|bindings to cluster-admin"
  "wildcard|roles with a * in verbs, resources, apiGroups or URLs, or escalate, bind, impersonate"
  "default-sa|bindings that give a default ServiceAccount rights"
  "dangling|bindings whose role does not exist"
  "secrets|bound roles that can read Secrets"
)

check_ids() {
  local row
  for row in "${CHECKS[@]}"; do
    printf '%s\n' "${row%%|*}"
  done
}

usage() {
  cat <<EOF
$(basename "$0") - read-only RBAC review of a cluster

Usage:
  $(basename "$0") [--namespace NS] [--context CTX] [--all-namespaces]
                  [--only CHECK[,CHECK...]] [--list-checks] [--include-system]

Answers the access-review questions: who holds cluster-admin, which roles
grant wildcards or escalate, bind or impersonate, which bindings give rights to
a default ServiceAccount, which bindings point at a role that is gone, and
which bound roles can read Secrets. ClusterRoles and ClusterRoleBindings are
always read cluster-wide; --namespace narrows Roles and RoleBindings only.
Findings are labelled [risk] (cluster-wide) or [advice] (one namespace). Each
is followed by a kubectl command to look further, printed and never run.
It reads RBAC objects only: never a Secret, never a token, and it does not use
kubectl auth can-i, which impersonates.

Options:
  --namespace NS, -n NS   Limit Roles and RoleBindings to one namespace
  --all-namespaces, -A    Every namespace (default when -n is omitted)
  --context CTX           kubectl context
  --only LIST             Only the named checks (see --list-checks)
  --list-checks           Print stable check ids and exit
  --include-system        Also judge system: objects and subjects, and the
                          built-in cluster-admin, admin, edit and view roles
  -h, --help              Show this help

Exit codes: 0 reported findings, 1 query or JSON parsing error,
            2 wrong environment, 3 usage (also an unknown or empty --only),
            4 nothing to report
EOF
}

NAMESPACE=""
CONTEXT=""
ALL_NS=1
KUBECTL=(kubectl)
FINDINGS=0
ONLY=""
LIST_CHECKS=0
INCLUDE_SYSTEM=0

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list-checks) LIST_CHECKS=1 ;;
    -n|--namespace) require_value "$1" "${2:-}"; NAMESPACE="$2"; ALL_NS=0; shift ;;
    --namespace=*) NAMESPACE="${1#*=}"; require_value "--namespace" "$NAMESPACE"; ALL_NS=0 ;;
    -A|--all-namespaces) ALL_NS=1; NAMESPACE="" ;;
    --context) require_value "$1" "${2:-}"; CONTEXT="$2"; shift ;;
    --context=*) CONTEXT="${1#*=}"; require_value "--context" "$CONTEXT" ;;
    --only) require_value "$1" "${2:-}"; ONLY="$2"; shift ;;
    --only=*) ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    --include-system) INCLUDE_SYSTEM=1 ;;
    *)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if (( LIST_CHECKS )); then
  check_ids
  exit 0
fi

# Unlike gke_cluster_doctor.sh, an empty selection is a usage error here:
# exit 4 already means "every check ran and found nothing".
SELECTED=()
known=" "
row=""
for row in "${CHECKS[@]}"; do
  known="$known ${row%%|*} "
done
if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a items <<< "$ONLY"
  for raw in "${items[@]}"; do
    id="$(printf '%s' "$raw" | tr -d '[:space:]')"
    [[ -n "$id" ]] || continue
    case "$known" in
      *" $id "*) SELECTED+=("$id") ;;
      *) err "unknown check in --only: $id (see --list-checks)"; exit 3 ;;
    esac
  done
  if (( ${#SELECTED[@]} == 0 )); then
    err "--only selected nothing (see --list-checks)"
    exit 3
  fi
else
  for row in "${CHECKS[@]}"; do
    SELECTED+=("${row%%|*}")
  done
fi

want() {
  local needle s
  for needle in "$@"; do
    for s in "${SELECTED[@]}"; do
      [[ "$s" == "$needle" ]] && return 0
    done
  done
  return 1
}

if ! command -v kubectl >/dev/null 2>&1; then
  err "kubectl is not installed or not on PATH"
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  err "python3 is not installed or not on PATH"
  exit 2
fi

if [[ -n "$CONTEXT" ]]; then
  KUBECTL+=(--context "$CONTEXT")
fi

ns_args=()
if (( ALL_NS == 1 )); then
  ns_args+=(--all-namespaces)
elif [[ -n "$NAMESPACE" ]]; then
  ns_args+=(--namespace "$NAMESPACE")
fi

if ! "${KUBECTL[@]}" cluster-info >/dev/null 2>&1; then
  err "cannot reach the cluster (check kubeconfig / context)"
  exit 2
fi

section() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$*" "$C_RESET"; }

# The follow-up names the context this run read, so pasting it cannot land on
# whichever context happens to be current by then.
next_step() {
  local cmd="$1"
  if [[ -n "$CONTEXT" ]]; then
    cmd="kubectl --context $(printf '%q' "$CONTEXT") ${cmd#kubectl }"
  fi
  info "next      $cmd"
}

CHECK_ERRORS=0
FETCHED=""

# fetch RESOURCE ARGS...: one read-only get into FETCHED. A Forbidden here is
# itself worth knowing, so it is counted like any other failure and leaves
# FETCHED empty, which the filter skips.
fetch() {
  local resource="$1" rc=0
  shift
  FETCHED="$("${KUBECTL[@]}" get "$resource" "$@" -o json 2>/dev/null)" || rc=$?
  if (( rc != 0 )) || [[ -z "$FETCHED" ]]; then
    warn "could not list $resource"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
    FETCHED=""
  fi
}

# Only what the selected checks read: bindings for cluster-admin and
# default-sa, roles for wildcard, both for dangling and secrets.
section "RBAC objects"
crb_json=""; rb_json=""; cr_json=""; role_json=""
if want cluster-admin default-sa dangling secrets; then
  fetch clusterrolebindings; crb_json="$FETCHED"
  fetch rolebindings "${ns_args[@]}"; rb_json="$FETCHED"
fi
if want wildcard dangling secrets; then
  fetch clusterroles; cr_json="$FETCHED"
  fetch roles "${ns_args[@]}"; role_json="$FETCHED"
fi
FETCHED=""
selected_csv="$(IFS=','; printf '%s' "${SELECTED[*]}")"
info "checks    ${selected_csv//,/, }"
if (( INCLUDE_SYSTEM == 0 )); then
  info "skipping  system: objects and subjects, and the built-in roles (--include-system to judge them)"
fi

# The documents travel on one pipe, split by the ASCII record separator,
# which valid JSON cannot contain unescaped.
RS=$'\x1e'
if ! report="$(printf '%s%s%s%s%s%s%s' "$crb_json" "$RS" "$rb_json" "$RS" "$cr_json" "$RS" "$role_json" | python3 -c '
import json,sys
checks=sys.argv[1].split(",")
include_system=sys.argv[2] == "1"
limit=40
parts=sys.stdin.read().split("\x1e")
if len(parts) != 4:
  raise ValueError("expected four documents")
out=[]
def load(raw,what):
  # An empty part is a query that already failed (and was counted) or one
  # this selection did not need.
  if not raw.strip():
    return None
  try:
    items=json.loads(raw)["items"]
    if not isinstance(items,list) or any(not isinstance(i,dict) for i in items):
      raise ValueError("expected a Kubernetes items list")
    for i in items:
      if not (i.get("metadata") or {}).get("name"):
        raise ValueError("every item needs a name")
    return items
  except (ValueError,KeyError,TypeError):
    out.append("E\t"+what)
    return None
crbs=load(parts[0],"clusterrolebindings")
rbs=load(parts[1],"rolebindings")
crs=load(parts[2],"clusterroles")
roles=load(parts[3],"roles")
BUILTIN=("cluster-admin","admin","edit","view")
def system(name):
  return not include_system and name.startswith("system:")
def bindings():
  for kind,items in (("clusterrolebinding",crbs),("rolebinding",rbs)):
    for b in items or []:
      meta=b["metadata"]
      if system(meta["name"]):
        continue
      ref=b.get("roleRef") or {}
      ns=meta.get("namespace","")
      label=meta["name"] if kind == "clusterrolebinding" else "%s/%s" % (ns,meta["name"])
      describe="kubectl describe %s %s%s" % (kind,meta["name"]," -n "+ns if kind == "rolebinding" else "")
      subjects=[s for s in b.get("subjects") or [] if not system(str(s.get("name","")))]
      yield kind,ns,meta["name"],label,ref,subjects,describe
def subject_text(s):
  if s.get("kind") == "ServiceAccount":
    return "ServiceAccount %s/%s" % (s.get("namespace",""),s.get("name",""))
  return "%s %s" % (s.get("kind",""),s.get("name",""))
def all_roles():
  for kind,items in (("clusterrole",crs),("role",roles)):
    for r in items or []:
      meta=r["metadata"]
      if system(meta["name"]) or (not include_system and kind == "clusterrole" and meta["name"] in BUILTIN):
        continue
      rules=r.get("rules") or []
      if not isinstance(rules,list) or any(not isinstance(x,dict) for x in rules):
        raise ValueError("rules must be a list of objects")
      yield kind,meta.get("namespace",""),meta["name"],rules
def grants(kind,ns,name):
  # Bindings that hand this role out: a ClusterRole through either kind of
  # binding, a Role only through RoleBindings in its own namespace.
  found=[]
  for bkind,bns,bname,label,ref,subjects,_ in bindings():
    if ref.get("name") != name:
      continue
    if kind == "clusterrole" and ref.get("kind") == "ClusterRole":
      found.append((bkind,"%s %s (%s)" % (bkind,label,", ".join(subject_text(s) for s in subjects) or "no subjects")))
    elif kind == "role" and ref.get("kind") == "Role" and bkind == "rolebinding" and bns == ns:
      found.append((bkind,"%s %s (%s)" % (bkind,label,", ".join(subject_text(s) for s in subjects) or "no subjects")))
  return found
rows={c:[] for c in checks}
if "cluster-admin" in rows or "default-sa" in rows or "dangling" in rows:
  cr_names={r["metadata"]["name"] for r in crs or []}
  role_names={(r["metadata"].get("namespace",""),r["metadata"]["name"]) for r in roles or []}
  for kind,ns,name,label,ref,subjects,describe in bindings():
    scope="risk" if kind == "clusterrolebinding" else "advice"
    if "cluster-admin" in rows and ref.get("kind") == "ClusterRole" and ref.get("name") == "cluster-admin":
      for s in subjects:
        rows["cluster-admin"].append((scope,"%s %s -> cluster-admin: %s" % (kind,label,subject_text(s)),[describe]))
    if "default-sa" in rows:
      for s in subjects:
        if s.get("kind") == "ServiceAccount" and s.get("name") == "default":
          rows["default-sa"].append((scope,"%s %s -> %s: %s (every pod without its own serviceAccountName inherits it)" % (
            kind,label,ref.get("name",""),subject_text(s)),[describe]))
    if "dangling" in rows:
      target=ref.get("name","")
      missing=False
      if ref.get("kind") == "ClusterRole" and crs is not None:
        missing=target not in cr_names
      elif ref.get("kind") == "Role" and roles is not None:
        missing=(ns,target) not in role_names
      if missing:
        where="" if ref.get("kind") == "ClusterRole" else " in namespace %s" % ns
        rows["dangling"].append(("advice","%s %s -> %s %s, which does not exist%s" % (kind,label,ref.get("kind",""),target,where),
                                 [describe,"kubectl delete %s %s%s" % (kind,name," -n "+ns if kind == "rolebinding" else "")]))
if "wildcard" in rows or "secrets" in rows:
  for kind,ns,name,rules in all_roles():
    label=name if kind == "clusterrole" else "%s/%s" % (ns,name)
    describe="kubectl describe %s %s%s" % (kind,name," -n "+ns if kind == "role" else "")
    wild=[]
    strong=False
    secret_verbs=set()
    limited=[]
    for rule in rules:
      verbs=rule.get("verbs") or []
      resources=rule.get("resources") or []
      groups=rule.get("apiGroups") or []
      urls=rule.get("nonResourceURLs") or []
      where="%s in apiGroups %s" % (",".join(resources) or "-",",".join(g or "core" for g in groups) or "-")
      if "*" in verbs and ("*" in resources or "*" in groups):
        wild.append("* on "+where)
        strong=True
      else:
        # A wildcard in any one dimension is over-broad: every verb on named
        # resources, named verbs on every resource or API group, or a
        # non-resource URL pattern ending in * (a /healthz/* suffix glob).
        dims=[n for n,vals in (("verbs",verbs),("resources",resources),("apiGroups",groups)) if "*" in vals]
        if any(isinstance(u,str) and u.endswith("*") for u in urls):
          dims.append("nonResourceURLs")
        if dims:
          wild.append("wildcard %s: %s on %s%s" % (",".join(dims),",".join(verbs) or "-",where,
                                                   " (nonResourceURLs %s)" % ",".join(urls) if urls else ""))
      powers=sorted({v for v in verbs if v in ("escalate","bind","impersonate")})
      if powers:
        wild.append("%s on %s" % (",".join(powers),",".join(resources) or "-"))
        strong=True
      if ("secrets" in resources or "*" in resources) and ("" in groups or "*" in groups):
        read={v for v in verbs if v in ("get","list","watch","*")}
        if read:
          secret_verbs|=read
          if rule.get("resourceNames"):
            limited.extend(rule["resourceNames"])
    if "wildcard" in rows and wild:
      rows["wildcard"].append(("risk" if kind == "clusterrole" and strong else "advice",
                               "%s %s grants %s" % (kind,label,"; ".join(wild)),[describe]))
    if "secrets" in rows and secret_verbs:
      bound=grants(kind,ns,name)
      if bound:
        scope="risk" if any(b[0] == "clusterrolebinding" for b in bound) else "advice"
        note=" (limited by resourceNames: %s)" % ", ".join(limited) if limited else ""
        rows["secrets"].append((scope,"%s %s can %s secrets%s; bound to: %s" % (
          kind,label,", ".join(sorted(secret_verbs)),note,"; ".join(b[1] for b in bound)),[describe]))
HEADINGS={"cluster-admin":("cluster-admin bindings","no binding to cluster-admin outside system: names"),
          "wildcard":("Wildcard and escalation rules","no role uses a * wildcard or grants escalate, bind or impersonate"),
          "default-sa":("Default ServiceAccount bindings","no binding grants rights to a default ServiceAccount"),
          "dangling":("Bindings to missing roles","every binding points at a role that exists"),
          "secrets":("Roles that can read Secrets","no bound role outside the built-ins can read Secrets")}
for check in checks:
  out.append("S\t"+HEADINGS[check][0])
  found=rows[check]
  for label,text,nexts in found[:limit]:
    out.append("F\t[%s] %s" % (label,text))
    out.extend("N\t"+n for n in nexts)
  if len(found) > limit:
    out.append("M\t%d" % (len(found)-limit))
  if not found:
    out.append("Q\t"+HEADINGS[check][1])
print("\n".join(out))
' "$selected_csv" "$INCLUDE_SYSTEM" 2>/dev/null)"; then
  warn "could not parse the RBAC objects"
  CHECK_ERRORS=$((CHECK_ERRORS + 1))
  report=""
fi

while IFS=$'\t' read -r tag text; do
  [[ -n "$tag" ]] || continue
  case "$tag" in
    S) section "$text" ;;
    Q) ok "$text" ;;
    F) warn "$text"; FINDINGS=$((FINDINGS + 1)) ;;
    N) next_step "$text" ;;
    M)
      if [[ "$text" =~ ^[0-9]+$ ]]; then
        info "... and $text more"
        FINDINGS=$((FINDINGS + text))
      fi
      ;;
    E) warn "could not parse $text JSON"; CHECK_ERRORS=$((CHECK_ERRORS + 1)) ;;
  esac
done <<<"$report"

printf "\n"
if (( CHECK_ERRORS > 0 )); then
  err "${CHECK_ERRORS} query or JSON parsing check(s) failed; RBAC audit incomplete"
  exit 1
fi
if (( FINDINGS == 0 )); then
  ok "RBAC looks quiet"
  exit 4
fi
info "${FINDINGS} finding(s)"
exit 0
