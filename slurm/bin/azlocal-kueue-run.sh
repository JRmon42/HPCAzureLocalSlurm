#!/usr/bin/env bash
# Slurm -> Kueue bridge. Runs as the body of a Slurm job on the gateway node (partition k8s):
# creates a Kubernetes Job in a Kueue LocalQueue, waits for Kueue to admit it, streams the pod logs
# into the Slurm output file, mirrors the exit code and deletes the Job on scancel / time limit.
#
#   kueue-run [--queue ocr-queue] [--namespace ocr] [--image IMG] [--cpu N] [--mem 6Gi] [--gpu N]
#             [--timeout SECONDS] [--env K=V]... -- command [args...]
# Volumes: hostPath in the POC; set OCR_PVC / MODELS_PVC (PersistentVolumeClaim names) in production.
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-/shared/k8s/${USER:-hpcuser}.kubeconfig}"
QUEUE=ocr-queue; NS=ocr; IMAGE=ghcr.io/ggml-org/llama.cpp:full
CPU=3; MEM=6Gi; GPU=1; TIMEOUT=7200; ENVS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --queue) QUEUE="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --cpu) CPU="$2"; shift 2 ;;
    --mem) MEM="$2"; shift 2 ;;
    --gpu) GPU="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --env) ENVS+=("$2"); shift 2 ;;
    --) shift; break ;;
    *) echo "kueue-run: unknown option $1" >&2; exit 64 ;;
  esac
done
[[ $# -gt 0 ]] || { echo "kueue-run: no command" >&2; exit 64; }

JOBID="${SLURM_JOB_ID:-manual$$}"
NAME="slurm-$JOBID"
ts() { date +%H:%M:%S; }
k() { kubectl -n "$NS" "$@"; }

cleanup() { k delete job "$NAME" --wait=false --ignore-not-found >/dev/null 2>&1; }
on_signal() { echo "$(ts) Slurm job cancelled -> deleting Kubernetes job $NAME"; cleanup; exit 143; }
trap on_signal TERM INT

# Job manifest (JSON). Kueue's webhook suspends it until the queue admits it.
ENV_LIST="$(printf '%s\n' "${ENVS[@]:-}")" \
NAME="$NAME" NS="$NS" QUEUE="$QUEUE" IMAGE="$IMAGE" CPU="$CPU" MEM="$MEM" GPU="$GPU" \
TIMEOUT="$TIMEOUT" JOBID="$JOBID" SLURM_USER="${SLURM_JOB_USER:-${USER:-unknown}}" \
python3 - "$@" >"/tmp/$NAME.json" <<'PY'
import json, os, sys
e = os.environ
env = [{"name": "NODE_NAME", "valueFrom": {"fieldRef": {"fieldPath": "spec.nodeName"}}},
       {"name": "SLURM_JOB_ID", "value": e["JOBID"]}]
for line in e["ENV_LIST"].splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        env.append({"name": k, "value": v})
labels = {"slurm.azlocal/job-id": e["JOBID"]}
res = {"cpu": e["CPU"], "memory": e["MEM"]}
if int(e["GPU"]) > 0:
    res["nvidia.com/gpu"] = e["GPU"]
job = {
    "apiVersion": "batch/v1", "kind": "Job",
    "metadata": {"name": e["NAME"], "namespace": e["NS"],
                 "labels": dict(labels, **{"kueue.x-k8s.io/queue-name": e["QUEUE"]}),
                 "annotations": {"slurm.azlocal/user": e["SLURM_USER"]}},
    "spec": {"backoffLimit": 0, "ttlSecondsAfterFinished": 3600,
             "activeDeadlineSeconds": int(e["TIMEOUT"]),
             "template": {"metadata": {"labels": labels}, "spec": {
                 "restartPolicy": "Never",
                 "containers": [{"name": "main", "image": e["IMAGE"], "command": sys.argv[1:],
                                 "env": env,
                                 "resources": {"requests": res, "limits": res},
                                 "volumeMounts": [{"name": "ocr", "mountPath": "/ocr"},
                                                  {"name": "models", "mountPath": "/models"}]}],
                 "volumes": [
                     {"name": "ocr", "persistentVolumeClaim": {"claimName": e["OCR_PVC"]}} if e.get("OCR_PVC")
                     else {"name": "ocr", "hostPath": {"path": "/shared/ocr"}},
                     {"name": "models", "persistentVolumeClaim": {"claimName": e["MODELS_PVC"]}} if e.get("MODELS_PVC")
                     else {"name": "models", "hostPath": {"path": "/var/lib/models", "type": "DirectoryOrCreate"}}]}}},
}
print(json.dumps(job))
PY
[[ -s "/tmp/$NAME.json" ]] || { echo "kueue-run: cannot build the job manifest" >&2; exit 70; }

echo "$(ts) Slurm job $JOBID -> Kubernetes job $NS/$NAME (LocalQueue $QUEUE, cpu=$CPU mem=$MEM gpu=$GPU)"
kubectl apply -f "/tmp/$NAME.json" || exit 70
rm -f "/tmp/$NAME.json"

last=""
while :; do
  suspended="$(k get job "$NAME" -o jsonpath='{.spec.suspend}' 2>/dev/null || echo gone)"
  [[ "$suspended" == "gone" ]] && { echo "$(ts) job disappeared"; exit 1; }
  [[ "$suspended" != "true" ]] && break
  msg="$(k get workloads -o jsonpath="{range .items[?(@.metadata.ownerReferences[0].name==\"$NAME\")]}{.status.conditions[?(@.type==\"QuotaReserved\")].message}{end}" 2>/dev/null)"
  if [[ "$msg" != "$last" ]]; then echo "$(ts) queued by Kueue: ${msg:-waiting for the workload object}"; last="$msg"; fi
  sleep 5 & wait $!
done
echo "$(ts) admitted by Kueue (quota reserved), pod starting"

for _ in $(seq 1 120); do
  phase="$(k get pods -l job-name="$NAME" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)"
  [[ -n "$phase" && "$phase" != "Pending" ]] && break
  sleep 5 & wait $!
done
k logs -f "job/$NAME" 2>&1 &
logpid=$!
while :; do
  st="$(k get job "$NAME" -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null)"
  [[ "$st" == "1/"* ]] && { rc=0; break; }
  [[ "$st" == */[1-9]* ]] && { rc=1; break; }
  sleep 3 & wait $!
done
wait "$logpid" 2>/dev/null
echo "$(ts) Kubernetes job $NAME finished rc=$rc (GPU quota released)"
exit $rc
