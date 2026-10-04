- Workflow checkouts that do not push set persist-credentials to false, so
  a job cannot use a leftover token. Summary steps pass event and step
  values through the environment instead of interpolating them into the
  shell. Docker base images whose tags resolve on Docker Hub are pinned
  to the registry manifest-list digest.
