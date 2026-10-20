# 08 – Update Stuck: ImagePullBackOff

> Troubleshooting runbook. Previous: [07 – Webmail "Connection error"](07-webmail-connection-error.md) · Next: [09 – Pod stuck in Pending](09-pending-insufficient-memory.md)

**Summary:** After an update, a pod does not start (ImagePullBackOff), but the service keeps running → read the pod's events (`kubectl describe pod`) → if the image tag is wrong, `kubectl rollout undo deploy/<name>` → then fix the version in the configuration.

| Field | Value |
|---|---|
| Date | 15.10.2026 (reproduced in the lab) |
| Affected service | `open-xchange-core-user-guide` (webmail help pages) in openDesk |
| Root cause | Image tag that does not exist in the registry |

## 1. Report

> "Yesterday's update went through, but `helmfile apply` ended with a timeout. Since then, a pod in openDesk does not start. Users have not reported anything."

Reproduced on 15.10.2026 with the deployment `open-xchange-core-user-guide` (help pages of webmail): the "update" set the image with `kubectl set image` to the non-existent tag `9.99.9`.

## 2. Diagnosis: from symptom to cause

The diagnosis goes from the failing pod to its deployment, and from there to the events that name the exact reason. Each step rules out one possibility.

**Run on:** kubespray VM as k8s (one session; the variables `D` and `P` are reused)

### Step 1 – Which pod is not OK?

```bash
kubectl -n opendesk get pods | grep -vE 'Running|Completed'
```

```
NAME                                            READY   STATUS             RESTARTS   AGE
open-xchange-core-user-guide-64d7b497d4-6zhxx   0/1     ImagePullBackOff   0          82s
```

**Conclusion:** exactly one pod does not start because its image cannot be pulled. The name of the deployment is the pod name without the two hash parts at the end.

### Step 2 – Why do users not notice anything?

```bash
D=open-xchange-core-user-guide
kubectl -n opendesk get deploy $D
kubectl -n opendesk get pods -o wide | grep user-guide
kubectl -n opendesk rollout status deploy/$D --timeout=30s
```

```
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
open-xchange-core-user-guide   1/1     1            1           30h

open-xchange-core-user-guide-64d7b497d4-6zhxx   0/1   ImagePullBackOff   0   2m58s   10.233.74.96    node4
open-xchange-core-user-guide-7fb88db995-ppqph   1/1   Running            0   30h     10.233.97.162   node5

Waiting for deployment "open-xchange-core-user-guide" rollout to finish: 1 old replicas are pending termination...
error: timed out waiting for the condition
```

**Result:** the deployment shows `1/1` and looks healthy. But there are two pods: the new one in `ImagePullBackOff` on node4 and the old one, `Running` for 30 hours, on node5. `rollout status` reports "1 old replicas are pending termination..." and gives up with "timed out waiting for the condition".

**Conclusion:** with a RollingUpdate, the old pod is only removed once the new one is ready. So the service keeps running, but the update never finishes. This is exactly where `helmfile apply` runs into its timeout as well.

### Step 3 – What does the new pod say?

```bash
P=open-xchange-core-user-guide-64d7b497d4-6zhxx
kubectl -n opendesk describe pod $P | tail -15
```

```
Events:
  Type     Reason     Age                  From               Message
  ----     ------     ----                 ----               -------
  Normal   Scheduled  4m9s                 default-scheduler  Successfully assigned opendesk/open-xchange-core-user-guide-64d7b497d4-6zhxx to node4
  Normal   Pulling    62s (x5 over 4m9s)   kubelet            spec.containers{main}: Pulling image "registry.opencode.de/bmi/opendesk/components/supplier/open-xchange/images-mirror/core-user-guide:9.99.9"
  Warning  Failed     62s (x5 over 4m8s)   kubelet            spec.containers{main}: Failed to pull image ".../core-user-guide:9.99.9": rpc error: code = NotFound desc = failed to pull and unpack image ".../core-user-guide:9.99.9": failed to resolve image: .../core-user-guide:9.99.9: not found
  Warning  Failed     62s (x5 over 4m8s)   kubelet            spec.containers{main}: Error: ErrImagePull
  Warning  Failed     24s (x15 over 4m8s)  kubelet            spec.containers{main}: Error: ImagePullBackOff
  Normal   BackOff    2s (x17 over 4m8s)   kubelet            spec.containers{main}: Back-off pulling image ".../core-user-guide:9.99.9"
```

**Conclusion:** the registry is reachable and authentication works, but the tag `9.99.9` does not exist. `ErrImagePull` is the failed attempt; `ImagePullBackOff` means Kubernetes keeps retrying with increasing pauses (up to 5 minutes).

### Step 4 – What changed compared to the old pod?

```bash
kubectl -n opendesk get pods -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,IMAGE:.spec.containers[0].image | grep -E 'NAME|user-guide'
```

```
NAME                                            STATUS    IMAGE
open-xchange-core-user-guide-64d7b497d4-6zhxx   Pending   registry.opencode.de/.../core-user-guide:9.99.9
open-xchange-core-user-guide-7fb88db995-ppqph   Running   registry.opencode.de/.../core-user-guide:8.49.2476344551@sha256:ae675c74…
```

**Conclusion:** the update only changed the image; the last working version is `8.49.2476344551`. The STATUS column shows `Pending` here: that is the phase of the pod, ImagePullBackOff is the reason.

### Step 5 – Is there a state to go back to?

```bash
kubectl -n opendesk rollout history deploy/$D
```

```
deployment.apps/open-xchange-core-user-guide
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

**Conclusion:** revision 2 is the faulty update, revision 1 the working state before it.

### Root cause

Image tag `9.99.9` does not exist in the registry → the new pod hangs in ImagePullBackOff → the rollout never finishes, `helmfile apply` runs into a timeout; the old pod keeps serving.

## 3. Fix and verification

First stabilize the service with `rollout undo`, then clarify the correct version calmly.

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
kubectl -n opendesk get pods -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,IMAGE:.spec.containers[0].image | grep -E 'NAME|user-guide'
kubectl -n opendesk get pods | grep -vE 'Running|Completed'
```

```
NAME                                            STATUS    IMAGE
open-xchange-core-user-guide-7fb88db995-ppqph   Running   registry.opencode.de/.../core-user-guide:8.49.2476344551@sha256:ae675c74…

NAME   READY   STATUS   RESTARTS   AGE
```

**Result:** only one pod is left, `Running`, with the original image `8.49.2476344551`; the list of pods outside Running/Completed only shows the header line. This matches the state saved before the exercise.

The running pod still has the same name as before (`open-xchange-core-user-guide-7fb88db995-ppqph`). `rollout undo` did not restart it – it only removed the faulty pod. For the users there was no interruption.

> **Important:** `rollout undo` only changes the running state in the cluster. If the wrong version is in the openDesk configuration, the error comes back with the next `helmfile apply`. So fix the version there before rolling out again.

**Emergency alternative** if `rollout undo` does not help: set the image back directly (values from the working pod, diagnosis step 4).

```bash
kubectl -n opendesk set image deploy/$D <container>=<working image>
```

## 4. Common causes of ImagePullBackOff

The text in the pod's events (diagnosis, step 3) shows which cause applies.

| Text in the events | Cause | Solution |
|---|---|---|
| `not found` / `manifest unknown` | Tag misspelled or not published yet | Check the tag, `rollout undo` |
| `unauthorized` / `authentication required` | imagePullSecret missing or expired | Renew the secret |
| `toomanyrequests` | Docker Hub download limit reached | Wait, or use your own registry |
| `i/o timeout` / `no such host` | DNS, firewall or proxy | Check from the node: `nslookup`, `curl` to the registry |
| `no match for platform` | Image not built for this CPU architecture | Choose a matching image |

## 5. Takeaways

- **"1/1 Ready" can hide a stuck rollout.** Check `rollout status` and look for a second pod of the same deployment.
- **For pull errors, read the events, not the logs.** The container never started, so there are no logs – the events contain the exact registry error.
- **Stabilize first, then investigate.** `rollout undo` brings back the last working state without interrupting users; the correct version can then be clarified calmly and fixed in the configuration.

---

Previous: [07 – Webmail "Connection error"](07-webmail-connection-error.md) · Next: [09 – Pod stuck in Pending](09-pending-insufficient-memory.md)
