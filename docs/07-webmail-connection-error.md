# 07 – Incident: Webmail Shows "Connection error"

> Troubleshooting runbook. Previous: [06 – Adding a worker node](06-add-worker-node.md) · Next: [08 – Update stuck – ImagePullBackOff](08-imagepullbackoff.md)

**Summary:** Webmail shows "Connection error", the portal works → check the endpoints of `open-xchange-core-mw-http-api` → if they are empty, scale the deployment `open-xchange-core-mw-groupware` back up with `kubectl scale … --replicas=1`.

| Field | Value |
|---|---|
| Date | 15.10.2026 |
| Affected service | OX App Suite (webmail) in openDesk, see [05](05-ox-app-suite.md) |
| Root cause | Deployment scaled to 0 replicas → service without endpoints → API returns 503 |

## 1. User report

> "Webmail only shows 'Connection error – The service is not available right now'. Portal and Files are working."

The browser shows the OX error page "Connection error – The service is not available right now." with the buttons **Sign out** and **Retry**.

## 2. Diagnosis: from symptom to cause

The diagnosis follows the path of the request from the outside in: **browser → ingress → service → endpoints → pod → deployment**. Each step rules out one possibility.

**Run on:** browser on the Windows workstation, then the kubespray VM as k8s (one session)

### Step 1 – Read the browser console

F12 → Console, reload the page. Marked in red:

```
Failed to load resource: the server responded with a status of 500 ()      appsuite/pwa.json:1
Manifest fetch from https://webmail.k8s.lab/appsuite/pwa.json failed, code 500
Failed to load resource: the server responded with a status of 503 ()      appsuite/api/apps/ma…ig&version=8.49.4:1
Failed to load resource: the server responded with a status of 503 ()      appsuite/api/apps/ma…ig&version=8.49.4:1
Server is down.                                                            main.js:79
Uncaught (in promise) Object                                               meta.js:28
Uncaught (in promise) Object                                               util.js:79
```

**Conclusion:** the page itself loads, but the requests to `/appsuite/api` fail with 503 (Service Unavailable), followed by "Server is down" and `code: 'NOSERVER'`.

### Step 2 – Test the start page and the API separately

```bash
curl -k -s -D - -o /dev/null https://webmail.k8s.lab | grep -i '^location'
curl -k -s -o /dev/null -w "/appsuite/      -> %{http_code}\n" https://webmail.k8s.lab/appsuite/
curl -k -s -o /dev/null -w "/appsuite/api/  -> %{http_code}\n" https://webmail.k8s.lab/appsuite/api/
```

```
location: /appsuite/
/appsuite/      -> 200
/appsuite/api/  -> 503
```

**Conclusion:** the user interface works, the API does not. A test on `/` alone returns 302 and would not have shown the problem.

### Step 3 – Which service serves the two paths?

```bash
kubectl -n opendesk get ingress -o json | jq -r '.items[] | select(.spec.rules[].host=="webmail.k8s.lab") | .metadata.name as $n | .spec.rules[].http.paths[] | "\($n)\t\(.path)\t\(.backend.service.name)"'
```

Result (excerpt from 24 routes):

```
open-xchange-appsuite-appsuite-base                  /appsuite/      open-xchange-core-ui-middleware
open-xchange-appsuite-http-api-routes-appsuite-api   /appsuite/api   open-xchange-core-mw-http-api
```

**Conclusion:** the user interface comes from `open-xchange-core-ui-middleware`, the API from `open-xchange-core-mw-http-api`.

### Step 4 – Are there pods behind the services?

```bash
kubectl -n opendesk get endpoints open-xchange-core-ui-middleware open-xchange-core-mw-http-api
```

```
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME                              ENDPOINTS                                                  AGE
open-xchange-core-ui-middleware   10.233.97.164:9090,10.233.97.166:9090,10.233.97.164:8080   29h
open-xchange-core-mw-http-api     <none>                                                     29h
```

**Conclusion:** there is no ready pod behind the API service. The warning "v1 Endpoints is deprecated" is normal.

### Step 5 – Which pods is the service looking for?

```bash
S=open-xchange-core-mw-http-api
SEL=$(kubectl -n opendesk get svc $S -o json | jq -r '.spec.selector | to_entries | map("\(.key)=\(.value)") | join(",")')
echo "Selector: $SEL"
kubectl -n opendesk get pods -l "$SEL"
```

```
Selector: app.kubernetes.io/instance=open-xchange,app.kubernetes.io/name=core-mw,roles.middleware.open-xchange.com/http-api=true
No resources found in opendesk namespace.
```

**Conclusion:** there is no matching pod at all. So it is not crashing – it is never created in the first place.

### Step 6 – Why is no pod created?

```bash
kubectl -n opendesk get deploy | grep -E 'NAME|open-xchange'
kubectl -n opendesk describe deploy open-xchange-core-mw-groupware | grep -E '^Replicas|Scaled'
```

```
NAME                                      READY   UP-TO-DATE   AVAILABLE   AGE
open-xchange-core-documentconverter       1/1     1            1           30h
open-xchange-core-guidedtours             1/1     1            1           30h
open-xchange-core-imageconverter          1/1     1            1           30h
open-xchange-core-mw-groupware            0/0     0            0           30h
open-xchange-core-ui                      1/1     1            1           30h
open-xchange-core-ui-middleware           1/1     1            1           30h
open-xchange-core-ui-middleware-updater   1/1     1            1           30h
open-xchange-core-user-guide              1/1     1            1           30h
open-xchange-gotenberg                    1/1     1            1           30h
open-xchange-guard-ui                     1/1     1            1           30h
open-xchange-nextcloud-integration-ui     1/1     1            1           30h
open-xchange-public-sector-ui             1/1     1            1           30h

Replicas:   0 desired | 0 updated | 0 total | 0 available | 0 unavailable
  Normal  ScalingReplicaSet  29m                deployment-controller  Scaled up replica set open-xchange-core-mw-groupware-bd67b6b88 from 0 to 1
  Normal  ScalingReplicaSet  15m (x2 over 51m)  deployment-controller  Scaled down replica set open-xchange-core-mw-groupware-bd67b6b88 from 1 to 0
```

**Conclusion:** all OX deployments are at `1/1`, only `open-xchange-core-mw-groupware` is at `0/0`. Together with `Replicas: 0 desired` and the event `Scaled down replica set … from 1 to 0`, this means the deployment was deliberately set to 0; before that it was at 1. "x2 over 51m" in the event means it was scaled down twice in the last 51 minutes.

### Root cause

Deployment `open-xchange-core-mw-groupware` at 0 replicas → service `open-xchange-core-mw-http-api` without endpoints → `/appsuite/api` returns 503 → webmail shows "Connection error".

## 3. Fix and verification

**Run on:** kubespray VM as k8s

### Step 1 – Fix

```bash
kubectl -n opendesk scale deploy open-xchange-core-mw-groupware --replicas=1
kubectl -n opendesk rollout status deploy/open-xchange-core-mw-groupware --timeout=10m
```

```
deployment.apps/open-xchange-core-mw-groupware scaled
Waiting for deployment "open-xchange-core-mw-groupware" rollout to finish: 0 of 1 updated replicas are available...
deployment "open-xchange-core-mw-groupware" successfully rolled out
```

**Result:** `successfully rolled out` after about 1 minute.

### Step 2 – Verify

```bash
kubectl -n opendesk get endpoints open-xchange-core-mw-http-api
curl -k -s -o /dev/null -w "/appsuite/api/ -> %{http_code}\n" https://webmail.k8s.lab/appsuite/api/
```

```
NAME                            ENDPOINTS           AGE
open-xchange-core-mw-http-api   10.233.71.26:8009   30h
/appsuite/api/ -> 404
```

**Result:** the endpoints show an IP again (it changes with every new pod). The API no longer returns 503 but 404 – that is normal: the middleware answers again, there is just no page at `/appsuite/api/` itself. After that, click **Retry** in the browser or reload the page – the calendar and mailbox load normally again.

## 4. Takeaways

- **Test the path that actually breaks.** The start page returned 200 and a check on `/` returned 302 – only a request to `/appsuite/api/` showed the 503.
- **Follow the request from the outside in.** Ingress → service → endpoints → pods → deployment narrows the problem down one layer at a time.
- **`<none>` endpoints plus "No resources found" means no pod exists at all.** In that case, look at the deployment's replica count and events, not at pod logs.

---

Previous: [06 – Adding a worker node](06-add-worker-node.md) · Next: [08 – Update stuck – ImagePullBackOff](08-imagepullbackoff.md)
