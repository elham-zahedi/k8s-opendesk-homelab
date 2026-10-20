# 09 – Pod Stuck in Pending: Insufficient Memory

> Troubleshooting runbook. Previous: [08 – Update stuck – ImagePullBackOff](08-imagepullbackoff.md) · Next: [10 – Node stuck in SchedulingDisabled](10-node-schedulingdisabled.md)

**Summary:** After a resource change, a new pod stays `Pending` (NODE `<none>`) while the old one keeps running → read the pod's events (`kubectl describe pod`) → on "Insufficient memory", compare the requests with the capacity of the nodes → `kubectl rollout undo deploy/<name>` → then fix the values in the configuration.

| Field | Value |
|---|---|
| Date | 15.10.2026 (reproduced in the lab) |
| Affected service | `open-xchange-core-user-guide` (webmail help pages) in openDesk |
| Root cause | Memory request `64Gi` instead of `64Mi` – larger than any node |

## 1. Report

> "Yesterday the memory of the webmail help service was adjusted. Since then, the rollout does not finish and a pod is permanently in Pending."

Reproduced on 15.10.2026 with the deployment `open-xchange-core-user-guide`: instead of `64Mi`, `64Gi` was set by mistake with `kubectl set resources` – a typical typo between Mi and Gi (1 Gi = 1024 Mi).

## 2. Diagnosis: from symptom to cause

The diagnosis goes from the waiting pod to the scheduler's decision, and then compares the requested resources with what the nodes have. Each step rules out one possibility.

**Run on:** kubespray VM as k8s (one session; the variables `D` and `P` are reused)

### Step 1 – Which pod is not OK?

```bash
kubectl -n opendesk get pods | grep -vE 'Running|Completed'
```

```
NAME                                            READY   STATUS    RESTARTS   AGE
open-xchange-core-user-guide-86bfb7f99c-hx9c8   0/1     Pending   0          10s
```

**Conclusion:** the pod has not been assigned to any node yet. There is neither a container nor an image download.

### Step 2 – Which node is the pod on?

```bash
D=open-xchange-core-user-guide
kubectl -n opendesk get pods -o wide | grep user-guide
```

```
open-xchange-core-user-guide-7fb88db995-ppqph   1/1   Running   0   46h   10.233.97.162   node5    <none>   <none>
open-xchange-core-user-guide-86bfb7f99c-hx9c8   0/1   Pending   0   82s   <none>          <none>   <none>   <none>
```

**Result:** the new pod has `<none>` in the NODE column; the old pod keeps running on node5.

**Conclusion:** the scheduler cannot find a suitable node. For comparison: with ImagePullBackOff ([08](08-imagepullbackoff.md)), the pod had been assigned to a node (node4), only the image was missing. As there, the old pod keeps serving and users notice nothing.

### Step 3 – What does the scheduler say?

```bash
P=open-xchange-core-user-guide-86bfb7f99c-hx9c8
kubectl -n opendesk describe pod $P | tail -8
```

```
Node-Selectors:              <none>
Tolerations:                 node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
                             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
Events:
  Type     Reason            Age    From               Message
  ----     ------            ----   ----               -------
  Warning  FailedScheduling  2m35s  default-scheduler  0/6 nodes are available: 1 node(s) had untolerated taint(s), 5 Insufficient memory. no new claims to deallocate, preemption: 0/6 nodes are available: 6 Preemption is not helpful for scheduling.
```

**Conclusion, part by part:**

- `0/6 nodes are available`: none of the six nodes fits.
- `1 node(s) had untolerated taint(s)`: the master is closed for normal pods (control-plane taint, see [02](02-kubernetes-cluster-kubespray.md)). This is intended.
- `5 Insufficient memory`: none of the five workers has enough free memory.
- `6 Preemption is not helpful`: even evicting other pods would not help.
- `no new claims to deallocate`: relates to Dynamic Resource Allocation and plays no role here.

### Step 4 – How much does the pod request, how much do the nodes have?

```bash
kubectl -n opendesk get pod $P -o jsonpath='{.spec.containers[0].resources}'; echo
kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory
kubectl describe node node1 | grep -A8 'Allocated resources'
```

```
{"limits":{"cpu":"99","memory":"64Gi"},"requests":{"cpu":"20m","memory":"64Gi"}}

NAME     CPU     MEMORY
master   7400m   15486756Ki
node1    7400m   15486740Ki
node2    7400m   15486756Ki
node3    7400m   15486748Ki
node4    7400m   15486756Ki
node5    7400m   15486748Ki

Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests          Limits
  --------           --------          ------
  cpu                2888m (39%)       1089100m (14717%)
  memory             3901788160 (24%)  15222007040 (95%)
```

**Result:**

- The pod requests `requests.memory: 64Gi`.
- Each node has `allocatable` of about 15 486 750 Ki, i.e. roughly 14.8 GiB (16 GB VMs from [01](01-proxmox-cloud-init-template.md)).
- On node1, 24 % of the memory is taken by requests.

**Conclusion:** 64 GiB is more than the total memory of any node. The pod can never be scheduled, no matter how empty the cluster is. The scheduler works with **requests**, not with actual usage – `kubectl top` does not help here.

As a side note, the output also explains the very high CPU limits seen in [05](05-ox-app-suite.md) (section 10.3): the chart sets `limits.cpu: 99` for this container.

### Step 5 – What was configured before?

```bash
kubectl -n opendesk get pods -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,MEM_REQ:.spec.containers[0].resources.requests.memory | grep -E 'NAME|user-guide'
kubectl -n opendesk rollout history deploy/$D
```

```
NAME                                            STATUS    MEM_REQ
open-xchange-core-user-guide-7fb88db995-ppqph   Running   32Mi
open-xchange-core-user-guide-86bfb7f99c-hx9c8   Pending   64Gi

deployment.apps/open-xchange-core-user-guide
REVISION  CHANGE-CAUSE
2         <none>
5         <none>
6         <none>
```

**Result:** the old pod requests `32Mi`, the new one `64Gi`.

**Conclusion:** the highest revision is the faulty change, the one before it is the working state. Missing numbers come from earlier `rollout undo` runs during the exercises: `rollout undo` does not go back to an old number but re-creates the restored state as a new revision.

### Root cause

Memory request `64Gi` instead of `64Mi` → larger than any node → the scheduler reports "Insufficient memory" → the new pod stays Pending, the rollout never finishes; the old pod keeps serving.

## 3. Fix and verification

First go back to the working state with `rollout undo`, then put the correct value into the configuration.

**Run on:** kubespray VM as k8s

### Step 1 – Back to the working state

```bash
kubectl -n opendesk rollout undo deploy/$D
kubectl -n opendesk rollout status deploy/$D --timeout=5m
```

```
deployment.apps/open-xchange-core-user-guide rolled back
deployment "open-xchange-core-user-guide" successfully rolled out
```

### Step 2 – Verify

```bash
kubectl -n opendesk get pods -o wide | grep user-guide
kubectl -n opendesk get deploy $D -o jsonpath='{.spec.template.spec.containers[0].resources}'; echo
kubectl -n opendesk get pods | grep -vE 'Running|Completed'
```

```
open-xchange-core-user-guide-7fb88db995-ppqph   1/1   Running   0   46h   10.233.97.162   node5   <none>   <none>
{"limits":{"cpu":"99","memory":"96Mi"},"requests":{"cpu":"20m","memory":"32Mi"}}
NAME   READY   STATUS   RESTARTS   AGE
```

**Result:** only one pod is left, `Running` on node5. The resources match the state saved before the exercise again: requests `cpu 20m`, `memory 32Mi`; limits `cpu 99`, `memory 96Mi`. The list of pods outside Running/Completed only shows the header line.

The running pod still has the same name as before (`open-xchange-core-user-guide-7fb88db995-ppqph`). `rollout undo` did not restart it – it only removed the waiting pod. For the users there was no interruption.

> **Important:** `rollout undo` only changes the running state in the cluster. If the wrong value is in the openDesk configuration, the error comes back with the next `helmfile apply`. So fix the value there and watch the unit: `Mi`, not `Gi`.

**Emergency alternative** if `rollout undo` does not help: set the resources back directly (values from 15.10.2026; compare with the working pod first).

```bash
C=$(kubectl -n opendesk get deploy $D -o jsonpath='{.spec.template.spec.containers[0].name}')
kubectl -n opendesk set resources deploy/$D -c $C --requests=cpu=20m,memory=32Mi --limits=cpu=99,memory=96Mi
```

## 4. Common FailedScheduling messages

The message in the event (diagnosis, step 3) names the reason why each node does not fit.

| Text in the event | Meaning | Solution |
|---|---|---|
| `Insufficient memory` / `Insufficient cpu` | Requests are larger than the free capacity of the nodes | Fix the requests or add nodes |
| `untolerated taint(s)` | The node is closed for this pod, e.g. the master | Usually intended; only a problem if no other node is left |
| `didn't match Pod's node affinity/selector` | The pod may only run on nodes with certain labels | Check the node labels or the selector |
| `unbound immediate PersistentVolumeClaims` | Volume not created or not bound yet | Check the PVC and the StorageClass (Longhorn) |
| `volume node affinity conflict` | The volume can only be reached on another node | Check the state of Longhorn and the nodes |
| `Too many pods` | Maximum number of pods per node reached | Remove pods or add nodes |

## 5. Takeaways

- **Pending with NODE `<none>` is a scheduling problem.** Nothing runs yet, so there are no logs – the `FailedScheduling` event is the place to look.
- **The scheduler counts requests, not usage.** A nearly idle cluster can still reject a pod whose request does not fit on any single node.
- **"Preemption is not helpful" is a strong hint.** If even evicting other pods would not help, the request is larger than a whole node – usually a unit mistake like `Gi` instead of `Mi`.

---

Previous: [08 – Update stuck – ImagePullBackOff](08-imagepullbackoff.md) · Next: [10 – Node stuck in SchedulingDisabled](10-node-schedulingdisabled.md)
