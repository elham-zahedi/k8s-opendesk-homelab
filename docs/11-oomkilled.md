# 11 – Container Keeps Restarting: OOMKilled

> Troubleshooting runbook. Previous: [10 – Node stuck in SchedulingDisabled](10-node-schedulingdisabled.md) · Next: [12 – Worker node failure and replacement](12-node-failure-replace-worker.md)

**Summary:** A container is terminated and restarted again and again, RESTARTS keeps rising (OOMKilled, CrashLoopBackOff). `kubectl describe pod` shows `Reason: OOMKilled` and `Exit Code: 137` → the container exceeded its memory limit and was killed by the kernel → raise the limit appropriately or reduce the memory demand, and record the value in the configuration.

| Field | Value |
|---|---|
| Date | Reproduced on 16.10.2026, outputs from 19.10.2026 |
| Affected workload | Test deployment `speicher-test` in its own namespace `uebung` (openDesk not affected) |
| Root cause | The program needs 150 MB, the memory limit is 100Mi |

## 1. Report

> "The new service does not start properly. It is restarted every few seconds."

Reproduced on 16.10.2026 (outputs from 19.10.2026) in a separate namespace `uebung` with the deployment `speicher-test`. It uses the image `polinux/stress` from the example in the Kubernetes documentation. The program allocates 150 MB of memory, the limit is 100Mi. openDesk is not affected. After the exercise, the namespace `uebung` was deleted again; in a real incident this step does not exist.

## 2. Diagnosis: from symptom to cause

The diagnosis goes from the status of the pod, via the termination reason of the container, to the kernel message on the node.

**Run on:** kubespray VM as k8s (one session; the variable `P` is reused)

### Step 1 – What does the pod show?

```bash
kubectl -n uebung get pods
```

```
NAME                             READY   STATUS      RESTARTS       AGE
speicher-test-644c67cf5b-xb2zg   0/1     OOMKilled   3 (34s ago)    53s

NAME                             READY   STATUS      RESTARTS       AGE
speicher-test-644c67cf5b-xb2zg   0/1     OOMKilled   4 (109s ago)   2m34s
```

**Result:** `0/1 OOMKilled`, RESTARTS 3 after 53 seconds and 4 after a good two and a half minutes.

**Conclusion:** the container starts but is terminated again and again. Unlike Pending ([09](09-pending-insufficient-memory.md)), the scheduler has already placed the pod on a node; the problem only appears at runtime.

### Step 2 – Why is the container terminated?

```bash
P=$(kubectl -n uebung get pod -l app=speicher-test -o jsonpath='{.items[0].metadata.name}')
kubectl -n uebung describe pod $P | grep -A5 -E '^ +(State|Last State):'
kubectl -n uebung describe pod $P | grep 'Restart Count'
kubectl -n uebung get events --sort-by=.lastTimestamp | tail -6
```

```
    State:          Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Mon, 19 Oct 2026 07:43:43 +0000
      Finished:     Mon, 19 Oct 2026 07:43:43 +0000
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Mon, 19 Oct 2026 07:42:15 +0000
      Finished:     Mon, 19 Oct 2026 07:42:15 +0000
    Restart Count:  5

113s   Normal    Pulled    pod/speicher-test-644c67cf5b-xb2zg   Successfully pulled image "polinux/stress" in 831ms (831ms including waiting). Image size: 4041495 bytes.
25s    Normal    Created   pod/speicher-test-644c67cf5b-xb2zg   Container created
25s    Normal    Pulling   pod/speicher-test-644c67cf5b-xb2zg   Pulling image "polinux/stress"
24s    Normal    Started   pod/speicher-test-644c67cf5b-xb2zg   Container started
23s    Warning   BackOff   pod/speicher-test-644c67cf5b-xb2zg   Back-off restarting failed container app in pod speicher-test-644c67cf5b-xb2zg_uebung(56f0261c-…)
```

**Result:** State and Last State `Terminated`, `Reason: OOMKilled`, `Exit Code: 137`, start and end in the same second; `Restart Count: 5`; event `BackOff: Back-off restarting failed container`.

**Conclusion:** 137 = 128 + 9, i.e. signal 9 (SIGKILL). The container was hard-killed right after starting because of a lack of memory. Kubernetes restarts it with increasing pauses (10 s, 20 s, 40 s … up to 5 minutes). That is CrashLoopBackOff; depending on the moment, the STATUS column shows `OOMKilled` or `CrashLoopBackOff`.

### Step 3 – How much is the container allowed to use?

```bash
kubectl -n uebung get pod $P -o jsonpath='{.spec.containers[0].resources}'; echo
kubectl -n uebung get pod $P -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'; echo
kubectl -n uebung logs $P --previous
```

```
{"limits":{"cpu":"200m","memory":"100Mi"},"requests":{"cpu":"50m","memory":"50Mi"}}
{"containerID":"containerd://22223e3f885f…","exitCode":137,"finishedAt":"2026-10-19T07:42:15Z","reason":"OOMKilled","startedAt":"2026-10-19T07:42:15Z"}
stress: info: [1] dispatching hogs: 0 cpu, 0 io, 1 vm, 0 hdd
```

**Result:** limit memory 100Mi, request 50Mi; last termination OOMKilled, exitCode 137, start and end in the same second. The log only contains the start message `stress: info: [1] dispatching hogs: 0 cpu, 0 io, 1 vm, 0 hdd`.

**Conclusion:** the limit is the hard boundary. Logs hardly help with OOMKilled: SIGKILL gives the program no time for a message, the log simply stops. If the previous container has already been removed, `--previous` even reports `unable to retrieve container logs` (as in the first run on 16.10.).

### Step 4 – What does the kernel on the node report?

```bash
N=$(kubectl -n uebung get pod $P -o jsonpath='{.spec.nodeName}')
NIP=$(kubectl get node $N -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "$N $NIP"
ssh k8s@$NIP "sudo dmesg -T | grep -iE 'out of memory|oom-kill|killed process' | tail -4"
```

```
node4 10.240.0.25
[Mon Oct 19 07:46:37 2026] oom-kill:constraint=CONSTRAINT_MEMCG,nodemask=(null),cpuset=cri-containerd-29c4c2c3…,mems_allowed=0,oom_memcg=/kubepods.slice/kubepods-burstable.slice/…,task=stress,pid=256088,uid=0
[Mon Oct 19 07:46:37 2026] Memory cgroup out of memory: Killed process 256088 (stress) total-vm:154384kB, anon-rss:101504kB, file-rss:256kB, shmem-rss:0kB, UID:0 pgtables:244kB oom_score_adj:997
[Mon Oct 19 07:46:37 2026] Memory cgroup out of memory: Killed process 256075 (stress) total-vm:780kB, anon-rss:0kB, file-rss:512kB, shmem-rss:0kB, UID:0 pgtables:36kB oom_score_adj:997
```

**Result:** node4 (10.240.0.25), `oom-kill:constraint=CONSTRAINT_MEMCG … task=stress` and `Memory cgroup out of memory: Killed process … (stress) … anon-rss:101504kB`.

**Conclusion:** `CONSTRAINT_MEMCG` means the limit of the container's cgroup was reached – not the memory of the node. At the moment it was killed, the process used about 99 MiB, i.e. exactly the limit. The second stress process was killed as well, because on OOM Kubernetes terminates the whole container.

### Root cause

Memory demand 150 MB → larger than the limit of 100Mi → the kernel kills the container (OOMKilled, exit code 137) → Kubernetes restarts it → OOMKilled again → CrashLoopBackOff.

## 3. Fix and verification

**Run on:** kubespray VM as k8s

### Step 1 – Raise the limit

```bash
kubectl -n uebung set resources deploy/speicher-test -c app --limits=memory=256Mi
kubectl -n uebung rollout status deploy/speicher-test --timeout=3m
```

```
deployment.apps/speicher-test resource requirements updated
Waiting for deployment "speicher-test" rollout to finish: 1 old replicas are pending termination...
deployment "speicher-test" successfully rolled out
```

### Step 2 – Verify

```bash
kubectl -n uebung get pods
sleep 60; kubectl -n uebung top pod
```

```
NAME                             READY   STATUS    RESTARTS   AGE
speicher-test-59b7f6dd65-bn64s   1/1     Running   0          11s

NAME                             CPU(cores)   MEMORY(bytes)
speicher-test-59b7f6dd65-bn64s   84m          150Mi
```

**Result:** new pod `1/1 Running`, RESTARTS 0; usage 150Mi with a limit of 256Mi.

> **Important:**
> - Do not raise the limit blindly. First clarify whether the application really needs more or has a memory leak; watch the usage over time with `kubectl top pod`.
> - The limit should be above the peak usage. The request must still fit on a node (see [09](09-pending-insufficient-memory.md)).
> - For an openDesk component, the new value belongs in the helmfile configuration. Otherwise the next `helmfile apply` resets the old limit.

## 4. Check in production: were there OOMKilled containers in openDesk?

This check only reads and can be run at any time during normal operation.

```bash
kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $p | .status.containerStatuses[]? | select(.lastState.terminated.reason=="OOMKilled") | "\($ns)/\($p)  \(.name)  restarts=\(.restartCount)  \(.lastState.terminated.finishedAt)"'
kubectl top pods -n opendesk --sort-by=memory | head -8
```

```
NAME                                                   CPU(cores)   MEMORY(bytes)
clamav-simple-0                                        1m           1123Mi
open-xchange-core-mw-groupware-bd67b6b88-8z9sf         6m           1040Mi
ums-keycloak-0                                         10m          935Mi
collabora-9b65654fb-qvz9b                              2m           720Mi
open-xchange-core-documentconverter-5584984f9f-qd9k6   3m           403Mi
ums-udm-rest-api-6d667fd557-s29tb                      29m          307Mi
open-xchange-core-imageconverter-854bd8f6d6-jpvt5      3m           271Mi
```

**Result on 19.10.2026:** the OOM check returned no output. No container in the cluster had OOMKilled as its last termination reason at that time, including openDesk. (In the first run on 16.10., the exercise pod still showed up here with `restarts=5`.) The biggest memory consumers in openDesk and their limits:

| Pod | Usage | Memory limit | Share |
|---|---|---|---|
| clamav-simple-0 | 1123Mi | 4Gi per container (2 containers) | Below 30 % |
| open-xchange-core-mw-groupware | 1040Mi | 8Gi | 13 % |
| ums-keycloak-0 | 935Mi | 2Gi | 46 % |
| collabora | 720Mi | 4Gi | 18 % |
| open-xchange-core-documentconverter | 403Mi | Not checked | – |
| ums-udm-rest-api | 307Mi | Not checked | – |
| open-xchange-core-imageconverter | 271Mi | Not checked | – |

**Conclusion:** all checked pods are well below 80 % of their limit; the highest is Keycloak at about 46 %. These pods are still the first candidates for OOMKilled. Repeat the comparison regularly:

```bash
kubectl -n opendesk get pods -o custom-columns=NAME:.metadata.name,MEM_LIMIT:.spec.containers[*].resources.limits.memory | grep -E 'NAME|clamav|groupware|ums-keycloak-0|collabora'
```

```
NAME                                             MEM_LIMIT
clamav-simple-0                                  4Gi,4Gi
collabora-9b65654fb-qvz9b                        4Gi
open-xchange-core-mw-groupware-bd67b6b88-8z9sf   8Gi
ums-keycloak-0                                   2Gi
```

## 5. Exit codes and comparison with "Pod stuck in Pending"

The exit code in the `Last State` field shows how a container ended.

| Exit code / reason | Meaning | Typical cause |
|---|---|---|
| 137, `OOMKilled` | Killed by the kernel because of memory (SIGKILL) | Limit too low, memory leak, Java heap larger than the limit |
| 137, without OOMKilled | Hard-killed from outside (SIGKILL) | Liveness probe failed and the container did not react to SIGTERM |
| 143 | Terminated gracefully (SIGTERM) | Normal stop, e.g. during a rollout or drain |
| 1 | Application error | Wrong configuration, missing file or variable; read the logs |
| 127 | Command not found | Wrong `command` in the container |
| 139 | Segmentation fault (SIGSEGV) | Bug in the program |

**Request too high or limit too low?**

| | [Pod stuck in Pending](09-pending-insufficient-memory.md) | Container keeps restarting |
|---|---|---|
| Wrong value | Request too high | Limit too low |
| Who intervenes | Scheduler, before the start | Kernel, at runtime |
| Status | `Pending`, NODE `<none>` | `OOMKilled` / `CrashLoopBackOff`, RESTARTS rising |
| Where it is visible | Event `FailedScheduling` | `Last State`, `Exit Code 137`, `dmesg` on the node |

## 6. Takeaways

- **Exit code 137 = 128 + 9 = SIGKILL.** Together with `Reason: OOMKilled`, it points to memory – the application logs usually show nothing, because the process gets no time to write a message.
- **`dmesg` tells you who hit the limit.** `CONSTRAINT_MEMCG` means the container's own limit, not a node running out of memory.
- **Fix the configuration, not only the cluster.** A limit raised with `kubectl set resources` is overwritten by the next `helmfile apply` unless the value is also changed in the configuration.

---

Previous: [10 – Node stuck in SchedulingDisabled](10-node-schedulingdisabled.md) · Next: [12 – Worker node failure and replacement](12-node-failure-replace-worker.md)
