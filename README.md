# F1 Pipeline (OpenF1)

This repository deploys a complete **race telemetry pipeline** on Azure.
It ingests live F1 data via an open API, streams it through **Azure Event Hubs**, processes it with **Stream Analytics**, and visualizes it in **Grafana**.

---

## 🚀 What this repo contains

- `terraform/` – Defines Azure infrastructure (AKS cluster, Event Hubs, SQL, Stream Analytics, Grafana, storage).
- `config/race-day.yaml` – Kubernetes manifest for the race-day producer deployment.
- `scripts/` – PowerShell scripts to start/stop the race-day pipeline and run the producer.
- `scripts/producer_race.py` – The producer that polls the OpenF1 API and pushes events into Event Hubs.
- `requirements.txt` – Python dependencies for running the producer locally.

---

## ✅ High-level architecture

1. **Producer** (`producer_race.py`) polls `https://api.openf1.org/v1/` and sends events to Event Hubs.
2. **Event Hubs** streams those events into **Stream Analytics**.
3. Stream Analytics writes processed data into **Azure SQL** (used by Grafana dashboards).
4. **Grafana** runs in Azure Container Instances (ACI) and presents a public dashboard.
5. **AKS** runs the producer deployment, which is manually started/stopped.

---

## ⚙️ Prerequisites (install everything)

### ✅ 1) Install required tools

#### Windows (winget)
```powershell
# Azure CLI
winget install -e --id Microsoft.AzureCLI

# Terraform
winget install -e --id HashiCorp.Terraform

# kubectl
winget install -e --id Kubernetes.Kubectl

# Python 3.11+
winget install -e --id Python.Python.3.11
```

> If you prefer Chocolatey:
> ```powershell
> choco install azure-cli terraform kubernetes-cli python --version=3.11
> ```

#### macOS (Homebrew)
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew update
brew install azure-cli terraform kubectl python@3.11
```

#### Linux (Ubuntu/Debian)
```bash
# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Terraform
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform

# kubectl
sudo snap install kubectl --classic

# Python
sudo apt-get install -y python3 python3-pip
```

---

### ✅ 2) Install Python dependencies

From the repo root:

```powershell
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

---

### ✅ 3) Login to Azure and choose a subscription

```powershell
az login
az account set --subscription "<your-subscription-id-or-name>"
```

> Tip: Use `az account list -o table` to see available subscriptions.

---

### ✅ 4) Validate your toolchain

```powershell
az --version
terraform version
kubectl version --client
python --version
```

---

## 🏗️ 1) Configure secrets + deploy infrastructure (Terraform)

### (A) Set your secrets in `terraform.tfvars`

Terraform uses `terraform/terraform.tfvars` for sensitive values like the SQL admin password and Grafana admin password. Copy the example file and edit it before running `terraform apply`:

```powershell
cd terraform
copy terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars
```

> ✅ `terraform.tfvars` is included in `.gitignore` and **must not** be committed.

If you prefer environment variables instead of a tfvars file, you can also set:

```powershell
$env:TF_VAR_subscription_id = "<your-subscription-id>"
$env:TF_VAR_sql_admin_password = "<your-sql-password>"
$env:TF_VAR_grafana_password = "<your-grafana-password>"
```

### (B) Deploy the infrastructure

From the repo root:

```powershell
cd terraform
terraform init
terraform apply
```

> ✅ This will create all Azure resources (AKS, Event Hubs, SQL, Grafana, storage, etc.).

> 💡 Terraform state files are stored locally and are ignored by `.gitignore`.

---

## 🧩 2) Prepare Azure resources (portal / CLI)

### (A) Confirm the resource group

In the Azure Portal, locate the resource group created by Terraform. It will be named like:

- `<prefix>-rg`

### (B) Grab the Event Hubs connection string

The producer needs this to send events.

1. In the Portal, open the Event Hubs namespace (named `<prefix>-eventhub`).
2. Go to **Shared access policies** → `producer-rule`.
3. Copy **Primary Connection String**.

### (C) (Optional) Fetch the SQL admin password

Terraform stores the SQL admin password in Key Vault under:

- Secret name: `sql-admin-password`

Retrieve it with:

```powershell
az keyvault secret show --vault-name <your-keyvault-name> --name sql-admin-password --query value -o tsv
```

---

## ▶️ 3) Start the race-day pipeline

From the repo root:

```powershell
.
 scripts\race_start.ps1
```

What it does:
- Starts the AKS cluster (if stopped)
- Starts the Stream Analytics job (if stopped)
- Starts the Grafana container
- Creates the `f1-secrets` Kubernetes secret (Event Hubs connection string + producer script URL)
- Deploys the race producer via `config/race-day.yaml`

---

## 🛑 4) Stop the pipeline (cleanup)

From the repo root:

```powershell
.
 scripts\race_stop.ps1
```

It will:
- Delete the AKS deployment
- Stop the Stream Analytics job
- Stop the AKS cluster
- Stop the Grafana container

---

## 🧪 5) Run the producer locally (dev)

Set the required environment variables and run the producer directly:

```powershell
$env:EVENTHUB_CONNECTION_STRING = "<your-eventhub-connection-string>"
$env:EVENTHUB_POSITIONS = "f1-positions"
$env:EVENTHUB_LAPS = "f1-laps"
$env:EVENTHUB_TELEMETRY = "f1-telemetry"
$env:EVENTHUB_WEATHER = "f1-weather"

python .\scripts\producer_race.py
```

### Optional settings (environment variables)
- `POLL_INTERVAL_SECONDS` – how often to poll the OpenF1 API (default: 10)
- `LOOKBACK_SECONDS` – how far back in time to query data (default: 30)

---

## ✅ Troubleshooting

### Grafana not reachable
1. Confirm the container group is running:

```powershell
az container show --name <prefix>-grafana --resource-group <prefix>-rg --query "instanceView.state"
```

2. Confirm the public FQDN (from the output of `race_start.ps1` or):

```powershell
az container show --name <prefix>-grafana --resource-group <prefix>-rg --query "ipAddress.fqdn" -o tsv
```

### Producer not sending events

Check the AKS pod logs:

```powershell
kubectl logs -l app=f1-producer -f
```

### Event Hubs auth issues

If the producer fails with Event Hubs auth errors, ensure the connection string is from `producer-rule` and has **Send** permissions.

---

## 📌 Notes / Best Practices

- The AKS cluster is designed to be started and stopped per race to save cost.
- Azure SQL is configured to auto-pause after 60 minutes of inactivity.
- Do **not** commit `terraform.tfstate` or `terraform.tfvars` (they are ignored by `.gitignore`).
