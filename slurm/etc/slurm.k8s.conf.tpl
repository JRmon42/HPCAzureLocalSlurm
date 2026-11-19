
# ---- Kubernetes / Kueue gateway (appended when K8S_GATEWAY is enabled) ----
# A static, always-on node (the controller in the POC) runs the Slurm jobs that submit work to
# Kubernetes through Kueue (azlocal-kueue-run.sh). These jobs only wait and relay logs, so many
# can share the node.
SuspendExcNodes=__CONTROLLER_NAME__
NodeName=__CONTROLLER_NAME__ NodeAddr=__CONTROLLER_IP__ CPUs=__GW_CPUS__ RealMemory=__GW_MEMORY__ State=UNKNOWN Feature=k8s-gateway
PartitionName=k8s Nodes=__CONTROLLER_NAME__ MaxTime=INFINITE State=UP OverSubscribe=FORCE:16
