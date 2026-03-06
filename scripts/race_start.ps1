# ============================================
# START ALL RACE DAY INFRASTRUCTURE
# ============================================

# This script is intended to be run from the repository root, but it will work
# even if invoked from another directory.
$repoRoot = Split-Path -Parent $PSScriptRoot
$configYaml = Join-Path $repoRoot 'config\race-day.yaml'
$tfvarsPath = Join-Path $repoRoot 'terraform\terraform.tfvars'

Write-Host "Starting F1 race day infrastructure..." -ForegroundColor Green

# Start AKS only if it is currently stopped
Write-Host "Checking AKS cluster state..."
$aksState = az aks show --name openf1-aks --resource-group openf1-rg --query "powerState.code" --output tsv
if ($aksState -eq "Stopped") {
    Write-Host "Starting AKS cluster (this takes ~5 min)..."
    az aks start --name openf1-aks --resource-group openf1-rg
} else {
    Write-Host "AKS already running, skipping..." -ForegroundColor Yellow
}

# Start Stream Analytics only if it is currently stopped
Write-Host "Checking Stream Analytics state..."
$saState = az stream-analytics job show --name openf1-analytics --resource-group openf1-rg --query "jobState" --output tsv
if ($saState -eq "Stopped") {
    Write-Host "Starting Stream Analytics..."
    az stream-analytics job start --name openf1-analytics --resource-group openf1-rg --output-start-mode JobStartTime
} else {
    Write-Host "Stream Analytics already running, skipping..." -ForegroundColor Yellow
}

# Start Grafana container
Write-Host "Starting Grafana..."
az container start --name openf1-grafana --resource-group openf1-rg

# Get AKS credentials
Write-Host "Getting AKS credentials..."
az aks get-credentials --name openf1-aks --resource-group openf1-rg

# Clean SQL tables for a new race
Write-Host "Cleaning SQL tables for new race..."
$sqlPassword = (Get-Content $tfvarsPath | Select-String 'sql_admin_password' | ForEach-Object { $_ -replace '.*=\s*"(.+)"', '$1' })
az sql db query `
  --name f1db `
  --server openf1-sqlserver-brazilsouth `
  --resource-group openf1-rg `
  --admin-user openf1admin `
  --admin-password $sqlPassword `
  --query "DELETE FROM positions; DELETE FROM laps; DELETE FROM telemetry; DELETE FROM weather;"

# Fetch Event Hubs connection string
Write-Host "Fetching Event Hubs connection string..."
$connStr = az eventhubs namespace authorization-rule keys list `
  --resource-group openf1-rg `
  --namespace-name openf1-eventhub `
  --name producer-rule `
  --query primaryConnectionString --output tsv

# Fetch script URL from Blob Storage
$key = az storage account keys list --account-name openf1storage001 --resource-group openf1-rg --query "[0].value" --output tsv
$scriptUrl = az storage blob url --container-name scripts --name producer_race.py --account-name openf1storage001 --account-key $key --output tsv

# Create Kubernetes secret
Write-Host "Creating Kubernetes secrets..."
kubectl create secret generic f1-secrets `
  --from-literal=eventhub-connection-string="$connStr" `
  --from-literal=script-url="$scriptUrl" `
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy the producer to AKS
Write-Host "Deploying producer to AKS..."
kubectl apply -f $configYaml

# Display Grafana URL
$grafana = az container show --name openf1-grafana --resource-group openf1-rg --query "ipAddress.fqdn" --output tsv

Write-Host ""
Write-Host "All systems go!" -ForegroundColor Green
Write-Host "Grafana: http://${grafana}:3000" -ForegroundColor Cyan
Write-Host "Race day producer running on AKS!" -ForegroundColor Cyan
Write-Host ""
Write-Host "Monitor with: kubectl logs -l app=f1-producer -f" -ForegroundColor Yellow
