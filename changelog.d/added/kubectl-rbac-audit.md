- `k8s-toolbox/kubectl_rbac_audit.sh` answers the access-review questions
  without anyone pasting a `kubectl | jq` pipeline: who is bound to
  cluster-admin, which roles use a `*` in verbs, resources, API groups or
  URLs, or escalate, bind or
  impersonate, which bindings hand rights to a default ServiceAccount, which
  point at a role that no longer exists, and which bound roles can read
  Secrets. Rows are labelled `[risk]` or `[advice]`, each comes with a
  printed next step, system objects and the built-in roles are skipped
  unless `--include-system` (except the `system:serviceaccounts` and
  `system:serviceaccounts:<ns>` groups, which are judged by default), and it reads RBAC objects only, never a Secret
  or a token.
