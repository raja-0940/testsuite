#!/usr/bin/env bash
# setup-kuadrant-coredns.sh (dnspolicy tests, non-disruptive): deploy kuadrant-coredns (CoreDNS + Kuadrant plugin, reads DNSRecord CRs)
# side-by-side, same manifests as s390x CI step kuadrant-s390x-install-coredns, but exposed via NodePort
# (no MetalLB here). Does NOT change what the testsuite / named currently resolve against.
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-/root/.kube/config}
NS=${COREDNS_NS:-kuadrant-coredns}; ZONE=${DNS_ZONE:-kuadrant.internal}; IMG=${COREDNS_IMAGE:-quay.io/kuadrant/coredns-kuadrant:latest}; NODEPORT=${COREDNS_NODEPORT:-30554}
oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata: {name: ${NS}}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: kuadrant-coredns, namespace: ${NS}}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: kuadrant-coredns-plugin}
rules:
- apiGroups: ["kuadrant.io"]
  resources: ["dnsrecords"]
  verbs: ["list", "watch", "get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: kuadrant-coredns-plugin}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: kuadrant-coredns-plugin}
subjects:
- {kind: ServiceAccount, name: kuadrant-coredns, namespace: ${NS}}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: kuadrant-coredns, namespace: ${NS}}
data:
  Corefile: |
    ${ZONE} {
        debug
        errors
        log
        health {
            lameduck 5s
        }
        ready
        geoip GeoLite2-City-demo.mmdb {
            edns-subnet
        }
        metadata
        transfer {
            to *
        }
        kuadrant
        prometheus 0.0.0.0:9153
    }
    . {
        forward . /etc/resolv.conf
        log
        errors
    }
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: kuadrant-coredns, namespace: ${NS}}
spec:
  replicas: 1
  selector: {matchLabels: {app.kubernetes.io/name: kuadrant-coredns}}
  template:
    metadata: {labels: {app.kubernetes.io/name: kuadrant-coredns}}
    spec:
      serviceAccountName: kuadrant-coredns
      containers:
      - name: coredns
        image: ${IMG}
        args: ["-conf", "/etc/coredns/Corefile"]
        env: [{name: WATCH_NAMESPACES, value: ""}]
        ports:
        - {containerPort: 53, name: udp-53, protocol: UDP}
        - {containerPort: 53, name: tcp-53, protocol: TCP}
        readinessProbe: {httpGet: {path: /ready, port: 8181}, initialDelaySeconds: 10, periodSeconds: 5}
        livenessProbe: {httpGet: {path: /health, port: 8080}, initialDelaySeconds: 60, periodSeconds: 10, failureThreshold: 5}
        resources: {limits: {cpu: 200m, memory: 256Mi}, requests: {cpu: 100m, memory: 128Mi}}
        securityContext:
          allowPrivilegeEscalation: false
          capabilities: {add: [NET_BIND_SERVICE], drop: [ALL]}
          readOnlyRootFilesystem: true
        volumeMounts: [{mountPath: /etc/coredns, name: config-volume}]
      volumes:
      - name: config-volume
        configMap: {name: kuadrant-coredns, items: [{key: Corefile, path: Corefile}]}
---
apiVersion: v1
kind: Service
metadata: {name: kuadrant-coredns, namespace: ${NS}}
spec:
  type: NodePort
  selector: {app.kubernetes.io/name: kuadrant-coredns}
  ports:
  - {name: udp-53, port: 53, protocol: UDP, targetPort: udp-53, nodePort: ${NODEPORT}}
  - {name: tcp-53, port: 53, protocol: TCP, targetPort: tcp-53, nodePort: ${NODEPORT}}
YAML
# NET_BIND_SERVICE on port 53 needs anyuid-like SCC on OpenShift (s390x runs it the same way)
oc adm policy add-scc-to-user anyuid -z kuadrant-coredns -n ${NS} >/dev/null 2>&1 || true
oc rollout status deploy/kuadrant-coredns -n ${NS} --timeout=180s
