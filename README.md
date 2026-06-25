# vastraCo-helm

GitOps repository for deploying the VastraCo e-commerce platform to Amazon EKS using Helm, ArgoCD, and KGateway.

**GitHub:** https://github.com/VastraCo-AWS/vastraCo-helm

---

## Architecture

```
Internet
    │
    ▼
[AWS LoadBalancer]  ←  provisioned by KGateway GatewayClass
    │
    ▼
[KGateway]  (namespace: production)
    │
    ├── /api/auth/*        → user-service:3001
    ├── /api/orders/*      → order-service:3003
    ├── /api/categories/*  → product-service:3002
    ├── /api/products/*    → product-service:3002
    ├── /api/ai/*          → ai-service:3004
    └── /*                 → frontend:80
         │
         └── (nginx serves built React SPA; browser calls /api/* → KGateway)

[Services]
┌─────────────────┐   ┌──────────────────┐   ┌──────────────────┐
│  user-service   │   │ product-service  │   │  order-service   │
│  Node/Express   │   │  Node/Express    │   │  Node/Express    │
│  port 3001      │   │  port 3002       │   │  port 3003       │
│  DB: users_db   │   │  DB: products_db │   │  DB: orders_db   │
└────────┬────────┘   └────────┬─────────┘   └────────┬─────────┘
         │                     │                       │
         └─────────────────────┴───────────────────────┘
                               │
                        [Amazon RDS PostgreSQL]
                        (single instance, 3 logical DBs)

┌─────────────────┐
│   ai-service    │
│  Python FastAPI │
│  port 3004      │
│  IRSA → Bedrock │
└─────────────────┘

[Secrets]
All pods pull secrets via AWS Secrets Store CSI Driver → AWS Secrets Manager
IRSA provides pod-level AWS identity (no static credentials)
```

---

## Repository Structure

```
vastraCo-helm/
├── README.md
├── argocd/
│   ├── appproject.yaml             # ArgoCD project scoped to production namespace
│   └── application-production.yaml
├── kgateway/
│   ├── gateway.yaml                # KGateway Gateway resource
│   └── httproute.yaml              # Path-based routing rules
└── charts/
    └── vastraco-services/
        ├── Chart.yaml
        ├── values.yaml             # Base values (all services)
        ├── values-production.yaml  # Production overrides + IRSA role ARNs
        └── templates/
            ├── _helpers.tpl
            ├── namespace.yaml
            ├── deployment.yaml
            ├── service.yaml
            ├── serviceaccount.yaml
            ├── hpa.yaml
            ├── configmap.yaml
            ├── secretproviderclass.yaml
            └── networkpolicy.yaml
```

---

## Pre-Deployment Checklist

### 1. Install Secrets Store CSI Driver

```bash
helm repo add secrets-store-csi-driver \
  https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm install csi-secrets-store \
  secrets-store-csi-driver/secrets-store-csi-driver \
  -n kube-system \
  --set syncSecret.enabled=true
```

### 2. Install AWS Provider for CSI Driver

```bash
kubectl apply -f \
  https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml
```

### 3. Install KGateway

```bash
helm repo add kgateway https://kgateway.dev/charts
helm install kgateway kgateway/kgateway -n kgateway-system --create-namespace
```

### 4. Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 5. Apply ArgoCD Manifests

```bash
kubectl apply -f argocd/
```

### 6. Manually Create Logical Databases on RDS

The Terraform RDS instance creates a single master database named `vastraco`.
Each microservice connects to its own logical database. You must create these manually
using the master credentials from `vastraco/db-creds` in Secrets Manager:

```sql
-- Connect as vastraco_admin to the RDS endpoint
CREATE DATABASE users_db;
CREATE DATABASE products_db;
CREATE DATABASE orders_db;
```

**Note:** The Helm chart uses master credentials (`vastraco_admin`) for all services
with the correct `*_DB_NAME` per service set via ConfigMap. For production hardening,
create per-service DB users with least-privilege grants and store them as separate
secrets (`vastraco/user-db-creds`, etc.).

### 7. Verify IRSA Trust Policies

Ensure the EKS OIDC provider is configured and the Terraform-provisioned IRSA roles
trust the correct service accounts in namespace `production`:

| Service          | IAM Role ARN                                                            | K8s ServiceAccount  |
|------------------|-------------------------------------------------------------------------|---------------------|
| user-service     | arn:aws:iam::078426574503:role/vastraco-production-irsa-user-service    | user-service-sa     |
| product-service  | arn:aws:iam::078426574503:role/vastraco-production-irsa-product-service | product-service-sa  |
| order-service    | arn:aws:iam::078426574503:role/vastraco-production-irsa-order-service   | order-service-sa    |
| ai-service       | arn:aws:iam::078426574503:role/vastraco-production-irsa-ai-service      | ai-service-sa       |

---

## CD Pipeline — Image Tag Updates

GitHub Actions is the **sole** mechanism for updating image tags. ArgoCD only syncs Git state.

```
GitHub Actions CI/CD workflow:
  1. Build Docker image
  2. Push to ECR: 078426574503.dkr.ecr.us-east-1.amazonaws.com/<service>:<sha>
  3. Update values-production.yaml:
       yq e '.services.<service>.image.tag = "<sha>"' -i \
         charts/vastraco-services/values-production.yaml
  4. git commit -m "chore: update <service> image to <sha>"
  5. git push origin main
  6. ArgoCD detects the diff and triggers a rolling update on EKS
```

**Only `services.<service>.image.tag` is updated by the pipeline.
Image repositories are static and never change.**

**Do NOT use ArgoCD Image Updater, Flux ImagePolicy, or any image automation tooling.**

---

## AWS Secrets Manager — Key Mapping

| Secret Name           | JSON Key     | Mounted as k8s Secret Key |
|-----------------------|--------------|---------------------------|
| vastraco/db-creds     | host         | DB_HOST                   |
| vastraco/db-creds     | username     | DB_USERNAME               |
| vastraco/db-creds     | password     | DB_PASSWORD               |
| vastraco/jwt-secret   | jwt_secret   | JWT_SECRET                |

---

## Security Notes

- **Never set `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` in production Pods.** IRSA
  provides pod-level IAM identity via the OIDC token mounted at
  `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`. boto3 and the AWS SDK
  pick this up automatically via the default credential chain.
- Secrets are injected at runtime via the CSI Driver — they are never baked into container images.
- All containers run as non-root (`runAsUser: 1000` for Node/Python, `runAsUser: 101`
  for the nginx-based frontend).
- All Linux capabilities are dropped (`capabilities.drop: [ALL]`).
- A single `allow-namespace-traffic` NetworkPolicy permits intra-namespace traffic and
  ingress from `kgateway-system`. Egress is unrestricted to avoid blocking RDS,
  Secrets Manager, Bedrock, IRSA/STS, ECR, and ArgoCD connectivity.

---

## Manual Helm Install (without ArgoCD)

```bash
helm upgrade --install vastraco-production \
  charts/vastraco-services \
  -f charts/vastraco-services/values.yaml \
  -f charts/vastraco-services/values-production.yaml \
  -n production --create-namespace
```
