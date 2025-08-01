#!/bin/bash

echo "🚀 Robust ArgoCD Deployment Script"
echo "=================================="

# Function to wait for pods to be ready
wait_for_pods() {
    local namespace=$1
    local timeout=${2:-300}
    echo "⏳ Waiting for pods in namespace $namespace to be ready..."
    
    local end_time=$((SECONDS + timeout))
    while [ $SECONDS -lt $end_time ]; do
        local not_ready=$(kubectl get pods -n $namespace --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)
        if [ "$not_ready" -eq 0 ]; then
            echo "✅ All pods are ready"
            return 0
        fi
        echo "   Still waiting... ($not_ready pods not ready)"
        sleep 10
    done
    
    echo "⚠️  Timeout waiting for pods to be ready"
    kubectl get pods -n $namespace
    return 1
}

# Function to restart failed deployments
restart_failed_deployments() {
    local namespace=$1
    echo "🔄 Checking for failed deployments in $namespace..."
    
    local deployments=("argocd-dex-server" "argocd-repo-server" "argocd-application-controller" "argocd-applicationset-controller" "argocd-server")
    local restarted=false
    
    for deployment in "${deployments[@]}"; do
        # Check if deployment exists
        if ! kubectl get deployment $deployment -n $namespace > /dev/null 2>&1; then
            continue
        fi
        
        local ready=$(kubectl get deployment $deployment -n $namespace -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        local desired=$(kubectl get deployment $deployment -n $namespace -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        
        if [ "$ready" != "$desired" ] || [ "$ready" = "null" ] || [ "$ready" = "" ]; then
            echo "🔄 Restarting $deployment (ready: $ready/$desired)"
            kubectl rollout restart deployment/$deployment -n $namespace
            restarted=true
        fi
    done
    
    if [ "$restarted" = true ]; then
        echo "⏳ Waiting 30 seconds for restarts to take effect..."
        sleep 30
        return 0
    else
        echo "✅ All deployments appear healthy"
        return 1
    fi
}

# Main deployment function
deploy_argocd() {
    local max_attempts=3
    local attempt=1
    
    # Define file order
    local YAML_FILES=(
        "01-namespace.yaml"
        "02-crds.yaml"
        "03-serviceaccounts.yaml"
        "04-clusterroles.yaml"
        "05-clusterrolebindings.yaml"
        "06-configmaps.yaml"
        "07-secrets.yaml"
        "08-services.yaml"
        "09-deployments.yaml"
        "10-networkpolicies.yaml"
        "12-repository-secret.yaml"
    )
    
    echo "📋 Deploying ArgoCD components..."
    
    # Apply infrastructure first (non-deployment resources)
    for file in "${YAML_FILES[@]:0:8}"; do  # Skip deployments initially
        echo "📦 Applying $file..."
        if ! kubectl apply -f "$file"; then
            echo "❌ Failed to apply $file"
            exit 1
        fi
        
        # Add strategic delays
        case $file in
            "06-configmaps.yaml")
                echo "⏳ Waiting for ConfigMaps to propagate..."
                sleep 10
                ;;
            "07-secrets.yaml")
                echo "⏳ Waiting for Secrets to propagate..."
                sleep 10
                ;;
            "08-services.yaml")
                echo "⏳ Waiting for Services to be ready..."
                sleep 5
                ;;
        esac
    done
    
    # Deploy with retry logic
    while [ $attempt -le $max_attempts ]; do
        echo ""
        echo "🚀 Deployment attempt $attempt/$max_attempts"
        echo "======================================"
        
        # Apply deployments
        echo "📦 Applying 09-deployments.yaml..."
        kubectl apply -f "09-deployments.yaml"
        
        echo "⏳ Waiting 45 seconds for initial deployment..."
        sleep 45
        
        # Check and restart failed deployments
        if restart_failed_deployments "argocd"; then
            echo "⏳ Waiting additional 60 seconds after restarts..."
            sleep 60
        fi
        
        # Check if all pods are ready
        if wait_for_pods "argocd" 180; then
            echo "✅ Deployment successful on attempt $attempt"
            break
        else
            echo "❌ Deployment attempt $attempt failed"
            if [ $attempt -eq $max_attempts ]; then
                echo "💥 All deployment attempts failed"
                echo "📊 Final pod status:"
                kubectl get pods -n argocd
                exit 1
            fi
            ((attempt++))
            echo "🔄 Retrying in 30 seconds..."
            sleep 30
        fi
    done
    
    # Apply remaining resources
    echo ""
    echo "📦 Applying remaining resources..."
    for file in "${YAML_FILES[@]:9}"; do
        echo "📦 Applying $file..."
        kubectl apply -f "$file"
        
        # Add delay after repository secret as it can trigger deployment updates
        if [[ "$file" == "12-repository-secret.yaml" ]]; then
            echo "⏳ Waiting for repository secret changes to propagate..."
            sleep 30
        fi
    done
    
    # Final wait for all pods to be ready
    echo ""
    echo "⏳ Final check - waiting for all pods to be ready..."
    if ! kubectl wait --for=condition=ready pod --all -n argocd --timeout=180s; then
        echo "⚠️  Some pods are still starting, checking status..."
        kubectl get pods -n argocd
        
        # Wait a bit more for slow-starting pods
        echo "⏳ Giving pods additional time to start..."
        sleep 60
    fi
    
    # Final deployment reapplication to ensure consistency
    echo ""
    echo "🔄 Final step: Reapplying deployments to ensure consistency..."
    kubectl apply -f "09-deployments.yaml"
    echo "⏳ Waiting 30 seconds for final deployment updates..."
    sleep 30
}

# Validation function
validate_deployment() {
    echo ""
    echo "🔍 Validating ArgoCD deployment..."
    echo "================================="
    
    # Check pods
    echo "📊 Pod Status:"
    kubectl get pods -n argocd
    
    # Count ready pods
    local total_pods=$(kubectl get pods -n argocd --no-headers | wc -l)
    local ready_pods=$(kubectl get pods -n argocd --no-headers | grep -E "1/1.*Running|2/2.*Running" | wc -l)
    local starting_pods=$(kubectl get pods -n argocd --no-headers | grep -E "ContainerCreating|Init:" | wc -l)
    
    echo ""
    echo "📈 Summary: $ready_pods/$total_pods pods ready"
    if [ "$starting_pods" -gt 0 ]; then
        echo "⏳ $starting_pods pods still starting..."
    fi
    
    if [ "$ready_pods" -eq "$total_pods" ]; then
        echo "✅ All pods are healthy!"
        
        # Get admin password
        echo ""
        echo "🔑 Getting admin credentials..."
        if kubectl -n argocd get secret argocd-initial-admin-secret > /dev/null 2>&1; then
            local admin_password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
            echo "✅ Admin password: $admin_password"
            echo ""
            echo "🎉 ArgoCD is ready!"
            echo "🌐 Access URL: https://argocd.integration.oneacrefund.org"
            echo "👤 Username: admin"
            echo "🔐 Password: $admin_password"
        else
            echo "⚠️  Admin secret not found - may still be initializing"
        fi
        return 0
        
    elif [ "$starting_pods" -gt 0 ] && [ $((ready_pods + starting_pods)) -eq "$total_pods" ]; then
        echo "⏳ Pods are still starting but no failures detected"
        echo "⏳ Waiting additional 60 seconds for startup to complete..."
        sleep 60
        
        # Recheck after wait
        ready_pods=$(kubectl get pods -n argocd --no-headers | grep -E "1/1.*Running|2/2.*Running" | wc -l)
        total_pods=$(kubectl get pods -n argocd --no-headers | wc -l)
        
        if [ "$ready_pods" -eq "$total_pods" ]; then
            echo "✅ All pods are now healthy!"
            
            # Get admin password
            echo ""
            echo "🔑 Getting admin credentials..."
            if kubectl -n argocd get secret argocd-initial-admin-secret > /dev/null 2>&1; then
                local admin_password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
                echo "✅ Admin password: $admin_password"
                echo ""
                echo "🎉 ArgoCD is ready!"
                echo "🌐 Access URL: https://argocd.integration.oneacrefund.org"
                echo "👤 Username: admin"
                echo "🔐 Password: $admin_password"
            else
                echo "⚠️  Admin secret not found - may still be initializing"
            fi
            return 0
        else
            echo "⚠️  Some pods are still not ready after extended wait"
            kubectl get pods -n argocd
            return 1
        fi
        
    else
        echo "❌ Some pods have failed"
        kubectl get pods -n argocd
        return 1
    fi
}

# Main execution
echo "Starting robust ArgoCD deployment..."

# Verify required files exist
YAML_FILES=(
    "01-namespace.yaml" "02-crds.yaml" "03-serviceaccounts.yaml"
    "04-clusterroles.yaml" "05-clusterrolebindings.yaml" "06-configmaps.yaml"
    "07-secrets.yaml" "08-services.yaml" "09-deployments.yaml"
    "10-networkpolicies.yaml" "12-repository-secret.yaml"
)

missing_files=()
for file in "${YAML_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        missing_files+=("$file")
    fi
done

if [ ${#missing_files[@]} -ne 0 ]; then
    echo "❌ Missing required files:"
    printf '   - %s\n' "${missing_files[@]}"
    exit 1
fi

# Run deployment
deploy_argocd

# Validate result
if validate_deployment; then
    echo ""
    echo "🎊 Deployment completed successfully!"
else
    echo ""
    echo "⚠️  Deployment completed with issues - manual intervention may be required"
    exit 1
fi
