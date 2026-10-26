#!/usr/bin/env bash
# First-time deployment of the app to NKP: Deployment, Service and an optional
# Ingress. Run once (as bamboo-deployer, or as admin) before the first Bamboo
# deployment; after that Bamboo only changes the image (scripts/bamboo-deploy.sh).
# Safe to re-run to change port, probes or replicas.
#
# Env vars:
#   NAMESPACE       namespace from nkp/setup.sh (required)
#   APP             Deployment/Service/container name (required), e.g. hr-chatbot-be
#   IMAGE           initial image (required), e.g. <harbor>/ajb-hr/be:<commit-sha>
#   PORT            container port (required)
#   HEALTH_PATH     HTTP path for readiness/liveness, e.g. /health
#                   (default: TCP check on PORT)
#   REPLICAS        default 2
#   INGRESS_HOST    if set, also create an Ingress for this host
#   INGRESS_CLASS   default kommander-traefik
#
# The pod reads environment variables from secret <APP>-env if it exists
# (created by an admin, e.g. kubectl -n <ns> create secret generic <APP>-env --from-env-file=app.env)
# and pulls with secret harbor-pull if it exists.
set -euo pipefail

: "${NAMESPACE:?NAMESPACE must be set}"
: "${APP:?APP must be set}"
: "${IMAGE:?IMAGE must be set}"
: "${PORT:?PORT must be set}"
REPLICAS="${REPLICAS:-2}"
INGRESS_CLASS="${INGRESS_CLASS:-kommander-traefik}"

if [[ -n "${HEALTH_PATH:-}" ]]; then
  probe="httpGet: { path: ${HEALTH_PATH}, port: http }"
else
  probe="tcpSocket: { port: http }"
fi

manifest="$(cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP}
spec:
  replicas: ${REPLICAS}
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app: ${APP}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: ${APP}
    spec:
      imagePullSecrets:
        - name: harbor-pull
      containers:
        - name: ${APP}
          image: ${IMAGE}
          ports:
            - name: http
              containerPort: ${PORT}
          envFrom:
            - secretRef:
                name: ${APP}-env
                optional: true
          readinessProbe:
            ${probe}
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            ${probe}
            initialDelaySeconds: 30
            periodSeconds: 10
          resources:
            requests: { cpu: 100m, memory: 128Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP}
  namespace: ${NAMESPACE}
spec:
  selector:
    app: ${APP}
  ports:
    - name: http
      port: 80
      targetPort: http
EOF
)"

if [[ -n "${INGRESS_HOST:-}" ]]; then
  manifest+="$(cat <<EOF

---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APP}
  namespace: ${NAMESPACE}
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
    - host: ${INGRESS_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${APP}
                port:
                  name: http
EOF
)"
fi

echo "${manifest}" | kubectl apply -f -
kubectl -n "${NAMESPACE}" rollout status "deployment/${APP}" --timeout="${ROLLOUT_TIMEOUT:-300s}"
