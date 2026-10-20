# 10 – Node Stuck in SchedulingDisabled

> Troubleshooting runbook. Previous: [09 – Pod stuck in Pending](09-pending-insufficient-memory.md) · Next: [11 – Container keeps restarting – OOMKilled](11-oomkilled.md)

**Summary:** After an aborted maintenance, a node is stuck in `Ready,SchedulingDisabled`. Running pods keep working, but no new pods are scheduled there → `kubectl get nodes` shows the state → release it with `kubectl uncordon <node>`. Typical cause: `kubectl drain` cordons the node first and then aborts with an error.

| Field | Value |
|---|---|
| Date | 16.10.2026 (reproduced in the lab) |
| Affected node | node5 |
| Root cause | `kubectl drain` without options cordoned the node and then aborted |

## 1. Report

No user report: all services keep running, the cluster simply has one worker less without anyone noticing. Found during the daily check: "node5 has been in SchedulingDisabled since the maintenance."

Reproduced on 16.10.2026 with `kubectl drain node5` without options. The command cordons the node (`node/node5 cordoned`) and then aborts, because DaemonSet pods and pods with `emptyDir` are only removed with additional options. No pod was moved, but the cordon stayed in place.

## 2. Diagnosis: from symptom to cause

The diagnosis goes from the state of the node to the cordon, to when it was set and to its effect.

**Run on:** kubespray VM as k8s (one session; the variables `N` and `D` are reused)

### Step 1 – Which node is conspicuous?

```bash
N=node5
kubectl get nodes
kubectl get pods -A -o wide --field-selector spec.nodeName=$N --no-headers | wc -l
```

What happened before (the drain that caused the problem):

```
$ kubectl drain node5
node/node5 cordoned
error: unable to drain node "node5" due to error: [cannot delete DaemonSet-managed Pods (use --ignore-daemonsets to ignore): kube-system/calico-node-mp4q2, kube-system/csi-smb-node-wdckz, kube-system/kube-proxy-d6ng6, kube-system/nodelocaldns-pkvr4, longhorn-system/engine-image-ei-493e04e7-z56dl, longhorn-system/longhorn-csi-plugin-tp5fw, longhorn-system/longhorn-manager-sbz9x, metallb-system/metallb-frr-k8s-ndhm4, metallb-system/metallb-speaker-nx7p7, cannot delete Pods with local storage (use --delete-emptydir-data to override): kube-system/metrics-server-765c774d7b-d8576, opendesk/clamav-simple-0, opendesk/dovecot-79c77d95d-d8kzm, opendesk/open-xchange-gotenberg-694d586596-x9msw, …, opendesk/postfix-7b746855cc-vptgj], continuing command...
There are pending nodes to be drained:
 node5
```

Output of the diagnosis:

```
NAME     STATUS                     ROLES           AGE   VERSION
master   Ready                      control-plane   8d    v1.36.4
node1    Ready                      <none>          8d    v1.36.4
node2    Ready                      <none>          8d    v1.36.4
node3    Ready                      <none>          8d    v1.36.4
node4    Ready                      <none>          8d    v1.36.4
node5    Ready,SchedulingDisabled   <none>          8d    v1.36.4
29
```

**Result:** node5 has the status `Ready,SchedulingDisabled`, and the same 29 pods as before the drain keep running on it.

**Conclusion:** the node is healthy (`Ready`) but does not accept new pods. The drain did not move a single pod.

### Step 2 – Why does the node not accept pods?

```bash
kubectl describe node $N | grep -E 'Taints|Unschedulable'
kubectl get events -A --field-selector involvedObject.name=$N --sort-by=.lastTimestamp | tail -5
```

```
Taints:             node.kubernetes.io/unschedulable:NoSchedule
Unschedulable:      true

longhorn-system   119s   Normal   Schedulable          node/node5   Node node5 is cordoned
longhorn-system   119s   Normal   Schedulable          node/node5   Node node5 is cordoned
longhorn-system   119s   Normal   Schedulable          node/node5   Node node5 is cordoned
longhorn-system   119s   Normal   Schedulable          node/node5   Node node5 is cordoned
default           114s   Normal   NodeNotSchedulable   node/node5   Node node5 status is now: NodeNotSchedulable
```

**Conclusion:** the node was cordoned. Kubernetes automatically sets the taint `unschedulable` for that, and Longhorn noticed the cordon as well.

### Step 3 – Since when, and by what?

```bash
kubectl get node $N --show-managed-fields -o json | jq -r '.metadata.managedFields[] | select(.fieldsV1["f:spec"]["f:unschedulable"]?) | "\(.manager)  \(.operation)  \(.time)"'
```

```
kubectl  Update  2026-10-16T06:54:03Z
```

**Result:** 08:54 local time (the time is in UTC).

**Conclusion:** the cordon was set with kubectl. Who ran the command is not recorded here; that would require the API server's audit log. Events expire after about one hour, but the managedFields are kept.

### Step 4 – What is the effect of the cordon?

Test with the non-critical deployment `open-xchange-core-user-guide`:

```bash
D=open-xchange-core-user-guide
kubectl -n opendesk rollout restart deploy/$D
kubectl -n opendesk rollout status deploy/$D --timeout=5m
kubectl -n opendesk get pods -o wide | grep user-guide
```

```
deployment.apps/open-xchange-core-user-guide restarted
Waiting for deployment "open-xchange-core-user-guide" rollout to finish: 1 old replicas are pending termination...
deployment "open-xchange-core-user-guide" successfully rolled out
open-xchange-core-user-guide-69d87f89dd-7r52d   1/1   Running   0   2m6s   10.233.102.171   node1   <none>   <none>
```

**Result:** the new pod runs on node1, not on node5.

**Conclusion:** every newly started pod (update, restart, crash) avoids node5. The cluster silently works with four instead of five workers. Only when those are full do pods stay Pending with `1 node(s) were unschedulable`.

### Root cause

Maintenance started with `kubectl drain` → aborted because of missing options → the node stayed cordoned (`SchedulingDisabled`) → new pods only land on the other workers.

## 3. Fix and verification

**Run on:** kubespray VM as k8s

### Step 1 – Release the node

```bash
kubectl uncordon $N
```

```
node/node5 uncordoned
```

### Step 2 – Verify

The taint and the cordon are gone, and all nodes have the same status as before the exercise again.

```bash
kubectl describe node $N | grep -E 'Taints|Unschedulable'
diff <(kubectl get nodes --no-headers | awk '{print $1, $2}') ~/szenario4-vorher.txt && echo SAME
kubectl -n opendesk get pods -o wide | grep user-guide
```

```
Taints:             <none>
Unschedulable:      false
SAME
open-xchange-core-user-guide-69d87f89dd-7r52d   1/1   Running   0   2m52s   10.233.102.171   node1   <none>   <none>
```

The file `~/szenario4-vorher.txt` was created before the exercise; in a real incident, `kubectl get nodes` without `SchedulingDisabled` is enough.

> **Important:** The user-guide pod stays on node1. Kubernetes does not move running pods back automatically after `uncordon`; node5 only fills up again with the next restarts and updates. Example from this exercise: in the first run, the pod moved from node5 to node4 and stayed there – that is why only 29 instead of 30 pods were running on node5 in the second run.

**Prevention:** add this to the daily check. No output means everything is fine.

```bash
kubectl get nodes | grep -E 'SchedulingDisabled|NotReady'
```

## 4. Doing maintenance correctly

**Dry run without any effect** (run for node5 on 16.10.2026). Only with `--dry-run=server`! Without this option, the pods are really moved.

```bash
kubectl drain $N --ignore-daemonsets --delete-emptydir-data --dry-run=server --timeout=60s
kubectl get nodes
```

```
node/node5 cordoned (server dry run)
Warning: ignoring DaemonSet-managed Pods: kube-system/calico-node-mp4q2, kube-system/csi-smb-node-wdckz, kube-system/kube-proxy-d6ng6, …
evicting pod cert-manager/cert-manager-webhook-646c95c5ff-2qfn8 (server dry run)
evicting pod idp/keycloak-postgres-0 (server dry run)
evicting pod kube-system/metrics-server-765c774d7b-d8576 (server dry run)
evicting pod longhorn-system/instance-manager-a32646b5bb6a32e8e858f2cd6dd4074e (server dry run)
evicting pod opendesk/clamav-simple-0 (server dry run)
evicting pod opendesk/dovecot-79c77d95d-d8kzm (server dry run)
evicting pod opendesk/postfix-7b746855cc-vptgj (server dry run)
…
error when evicting pods/"instance-manager-a32646b5bb6a32e8e858f2cd6dd4074e" -n "longhorn-system" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
^C
```

**Result:**

- The 9 DaemonSet pods (network, DNS, SMB CSI, Longhorn, MetalLB) are ignored; they run on every node.
- 20 pods would be moved, among them `idp/keycloak-postgres-0` (database of the Keycloak for the AD login), `opendesk/dovecot`, `opendesk/postfix` and `opendesk/clamav-simple-0`. They all run only once, so login and mail are briefly unavailable during a real maintenance.
- `longhorn-system/instance-manager-…` reports every 5 seconds "Cannot evict pod as it would violate the pod's disruption budget". Longhorn uses it to protect the volumes attached to node5. In the dry run no pod actually moves, so the block persists (cancel with Ctrl+C or `--timeout`). During a real maintenance, Longhorn normally releases the pod once the pods with volumes have moved – unless node5 holds the last healthy replica of a volume.
- Afterwards, `kubectl get nodes` shows node5 without `SchedulingDisabled`: the dry run did not cordon anything.

**Procedure for a real maintenance** (not carried out in this exercise):

1. Choose a maintenance window outside working hours and inform the users (login and mail briefly unavailable).
2. Check the Longhorn volumes: `kubectl -n longhorn-system get volumes.longhorn.io`, all should be `healthy`.
3. `kubectl drain $N --ignore-daemonsets --delete-emptydir-data --timeout=15m`
4. Do the maintenance (e.g. updates, VM reboot).
5. `kubectl uncordon $N` – **always**, even if the maintenance is aborted.
6. `kubectl get nodes`: no `SchedulingDisabled` anymore.

## 5. Common messages during kubectl drain

| Message | Meaning | Solution |
|---|---|---|
| `cannot delete DaemonSet-managed Pods` | The pod belongs to a DaemonSet and runs on every node | `--ignore-daemonsets` |
| `cannot delete Pods with local storage` | The pod uses `emptyDir`; this data is lost when it moves | `--delete-emptydir-data`, if the data is only temporary |
| `… declare no controller` | A single pod without a Deployment or StatefulSet; it would not be recreated | Delete the pod deliberately, or `--force` |
| `Cannot evict pod as it would violate the pod's disruption budget` | A PodDisruptionBudget does not allow an interruption right now | `kubectl get pdb -A`, find the cause or wait |
| `There are pending nodes to be drained` | The drain was aborted, the node stays cordoned | Fix the error and repeat the drain, or `kubectl uncordon` |

## 6. Takeaways

- **A failed drain still cordons the node.** The cordon is the first thing `kubectl drain` does, so an aborted drain always needs an `uncordon`.
- **A cordoned node fails silently.** Nothing breaks and nobody reports it; only a routine check like `grep -E 'SchedulingDisabled|NotReady'` catches it.
- **Use `--dry-run=server` before a real drain.** It shows which single-instance pods (database, mail) will be interrupted and whether a PodDisruptionBudget will block the drain.

---

Previous: [09 – Pod stuck in Pending](09-pending-insufficient-memory.md) · Next: [11 – Container keeps restarting – OOMKilled](11-oomkilled.md)
