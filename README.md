# Platform Engineering - GCP Compute Engine via Crossplane

Plateforme d'Internal Developer Platform (IDP) permettant de provisionner des VMs GCP Compute Engine en self-service via un portail web, orchestrée par **GitHub Actions** + **ArgoCD** + **Crossplane**.

## Architecture

```
Frontend (HTML/JS)
  └─ GitHub API (workflow_dispatch)
       └─ GitHub Actions (génère le Claim YAML, commit dans le repo)
            └─ ArgoCD (détecte le changement, sync vers K8s)
                 └─ Crossplane (reconcile le Claim → crée la VM sur GCP)
```

| Composant | Rôle |
|-----------|------|
| **Kind** | Cluster Kubernetes local |
| **Crossplane** | Contrôleur Kubernetes qui gère les ressources GCP via l'API K8s |
| **Provider GCP Compute** | Provider Upbound pour Crossplane (Compute Engine) |
| **ArgoCD** | GitOps — synchronise les Claims du repo vers le cluster |
| **GitHub Actions** | CI/CD — génère les manifests Crossplane à partir du formulaire |
| **Frontend** | Portail développeur (HTML/CSS/JS vanilla) |

## Prérequis

- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- Un projet GCP avec un compte de service (fichier JSON) ayant le rôle `Compute Admin`
- Un repo GitHub (public ou privé avec deploy key)

## Quick Start

### 1. Cloner le repo et configurer les credentials GCP

```bash
git clone https://github.com/Shinr0/platform-project.git
cd platform-project

# Generer les credentials GCP via ADC :
gcloud auth application-default login
# Le script utilise par defaut ~/.config/gcloud/application_default_credentials.json

# Optionnel : forcer le project ID
export GCP_PROJECT_ID="your-gcp-project-id"
```

### 2. Lancer le setup complet

```bash
./scripts/setup.sh
```

Ce script va :
1. Créer un cluster Kind `platform-eng`
2. Installer Crossplane + le provider GCP Compute
3. Configurer les credentials GCP dans Crossplane
4. Appliquer la XRD et la Composition (API custom `VirtualMachine`)
5. Installer ArgoCD
6. Déployer l'Application ArgoCD qui surveille `crossplane/claims/`

### 3. Configurer ArgoCD

```bash
# Accéder à l'UI ArgoCD
kubectl port-forward svc/argo-cd-argocd-server -n argocd 8080:80

# Récupérer le mot de passe admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Ouvrir http://localhost:8080 et se connecter avec `admin` / `<mot de passe>`.

**Important** : mettre à jour l'URL du repo dans `argocd/application-claims.yaml` avant d'appliquer.

### 4. Ouvrir le portail développeur

```bash
# Ouvrir directement dans le navigateur
open frontend/index.html
# ou
python3 -m http.server 3000 -d frontend
```

Au premier lancement, configurer dans **Settings** :
- **GitHub Token** : un PAT avec les scopes `repo` et `workflow`
- **Repository** : `owner/platform-engineering`

### 5. Créer une VM

Remplir le formulaire et cliquer sur **Create VM**. Le flow :
1. Le frontend trigger le workflow GitHub Actions `create-vm.yml`
2. GitHub Actions génère un fichier `crossplane/claims/<vm-name>.yaml` et le commit
3. ArgoCD détecte le nouveau fichier et l'applique sur le cluster
4. Crossplane crée la VM sur GCP

## Structure du projet

```
.github/workflows/
  create-vm.yml          # Workflow de création de VM
  delete-vm.yml          # Workflow de suppression de VM
crossplane/
  provider/
    provider-gcp-compute.yaml  # Installation du provider Upbound
    provider-config.yaml       # Configuration credentials GCP
  compositions/
    xrd-vm.yaml               # API custom (CompositeResourceDefinition)
    composition-vm.yaml        # Mapping vers GCP Compute Instance
  claims/                      # Répertoire GitOps (watched by ArgoCD)
argocd/
  application-claims.yaml      # Application ArgoCD
frontend/
  index.html                   # Portail développeur
scripts/
  setup.sh                     # Script de setup complet
```

## API Custom Crossplane

La XRD expose une ressource `VirtualMachine` avec les paramètres suivants :

| Paramètre | Type | Défaut | Description |
|-----------|------|--------|-------------|
| `vmName` | string | *requis* | Nom de l'instance Compute Engine |
| `machineType` | string | `e2-micro` | Type de machine GCP |
| `zone` | string | `europe-west1-b` | Zone GCP |
| `diskSizeGb` | integer | `20` | Taille du disque de boot en GB |
| `imageFamily` | string | `debian-12` | Famille d'image OS |

Exemple de Claim :

```yaml
apiVersion: compute.platform.local/v1alpha1
kind: VirtualMachine
metadata:
  name: my-dev-server
  namespace: default
spec:
  parameters:
    vmName: my-dev-server
    machineType: e2-small
    zone: europe-west1-b
    diskSizeGb: 30
    imageFamily: debian-12
```

## Commandes utiles

```bash
# Vérifier l'état de Crossplane
kubectl get providers
kubectl get providerconfigs

# Vérifier les compositions
kubectl get xrd
kubectl get compositions

# Voir les VMs gérées par Crossplane
kubectl get virtualmachines
kubectl get instance.compute.gcp.upbound.io

# Voir les syncs ArgoCD
kubectl get applications -n argocd

# Logs Crossplane
kubectl logs -n crossplane-system -l app=crossplane
```

## Dépannage

- **Provider pas Healthy** : vérifier les credentials GCP (`kubectl describe provider upbound-provider-gcp-compute`)
- **ArgoCD ne sync pas** : vérifier l'URL du repo et les credentials dans ArgoCD
- **VM pas créée sur GCP** : vérifier les logs du provider (`kubectl logs -n crossplane-system -l pkg.crossplane.io/revision`)
- **Erreur 403 sur GitHub API** : vérifier que le PAT a les scopes `repo` et `workflow`
