#!/bin/bash

# Function to display usage instructions
usage() {
    echo "Usage: $0 -p|--provision|-d|--delete [resources]"
    echo "Options:"
    echo "  -p, --provision  Provision specified resources (web-app, payment-service, user-service, db-migration, cache-service, monitoring-service)."
    echo "  -d, --delete     Delete specified resources (web-app, payment-service, user-service, db-migration, cache-service, monitoring-service, all)."
    exit 1
}

# Function to create the namespace
create_namespace() {
    kubectl create namespace prod-apps --dry-run=client -o yaml | kubectl apply -f -
    kubectl config set-context --current --namespace=prod-apps
}

# Function to create a pod with a DNS resolution failure (simulating a web app)
create_web_app_pod() {
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: web-app-pod
spec:
  containers:
  - name: web-app-container
    image: busybox
    command: ["sh", "-c", "while true; do nslookup api.internal-service.svc.cluster.local || echo 'API service DNS resolution failed'; sleep 5; done"]
  restartPolicy: Never
EOF
}

# Function to create a pod with an invalid image (simulating a payment service)
create_payment_service_pod() {
    kubectl run payment-service-pod --image=nonexistent/payment-service:latest --restart=Never
}

# Function to create a pod that crashes (simulating a user service)
# Function to create a pod that generates logs and then crashes (simulating a user service)
create_user_service_pod() {
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: user-service-pod
spec:
  containers:
  - name: user-service-container
    image: busybox
    command: ["sh", "-c", "echo 'Starting user service...'; sleep 10; echo 'Processing data...'; sleep 10; echo 'Critical error occurred! Terminating service...'; exit 1"]
  restartPolicy: Never
EOF
}


# Function to create a pod with excessive resource requests (simulating a database migration)
create_db_migration_pod() {
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: db-migration-pod
spec:
  containers:
  - name: db-migration-container
    image: busybox
    command: ["sh", "-c", "echo 'Starting database migration'; sleep 3600"]
    resources:
      requests:
        cpu: "6000m"
        memory: "12Gi"
  restartPolicy: Never
EOF
}

# Function to create a pod with a missing ConfigMap (simulating a cache service misconfiguration)
create_cache_service_pod() {
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: cache-service-pod
spec:
  containers:
  - name: cache-container
    image: redis:latest
    env:
    - name: CACHE_CONFIG
      valueFrom:
        configMapKeyRef:
          name: non-existent-cache-config
          key: cache-config-key
  restartPolicy: Never
EOF
}

# Function to create a service with a wrong selector (simulating a monitoring service misconfiguration)
create_monitoring_service() {
    kubectl run monitoring-agent-pod --image=prom/prometheus --labels="app=monitoring-agent"
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: monitoring-service
spec:
  selector:
    app: non-existent-monitoring-agent
  ports:
    - protocol: TCP
      port: 9090
      targetPort: 9090
EOF
}

# Function to delete specified resources
delete_resource() {
    resource=$1
    case $resource in
        web-app)
            kubectl delete pod web-app-pod -n prod-apps
            ;;
        payment-service)
            kubectl delete pod payment-service-pod -n prod-apps
            ;;
        user-service)
            kubectl delete pod user-service-pod -n prod-apps
            ;;
        db-migration)
            kubectl delete pod db-migration-pod -n prod-apps
            ;;
        cache-service)
            kubectl delete pod cache-service-pod -n prod-apps
            ;;
        monitoring-service)
            kubectl delete pod monitoring-agent-pod -n prod-apps
            kubectl delete service monitoring-service -n prod-apps
            ;;
        all)
            kubectl delete namespace prod-apps
            ;;
        *)
            echo "Unknown resource: $resource"
            ;;
    esac
}

# Function to provision specified resources
provision_resources() {
    resources=$1

    echo "Provisioning Kubernetes pods with realistic application errors for testing..."
    
    # Create a namespace for isolation
    create_namespace

    IFS=',' read -ra ADDR <<< "$resources"
    for resource in "${ADDR[@]}"; do
        case $resource in
            web-app)
                create_web_app_pod
                ;;
            payment-service)
                create_payment_service_pod
                ;;
            user-service)
                create_user_service_pod
                ;;
            db-migration)
                create_db_migration_pod
                ;;
            cache-service)
                create_cache_service_pod
                ;;
            monitoring-service)
                create_monitoring_service
                ;;
            *)
                echo "Unknown resource: $resource"
                ;;
        esac
    done

    echo "Specified error pods provisioned successfully in the 'prod-apps' namespace."
    
    # List all pods in the namespace to verify
    kubectl get pods -n prod-apps

    # Reset to the default namespace
    kubectl config set-context --current --namespace=default
}

# Check for at least two arguments
if [[ $# -lt 2 ]]; then
    usage
fi

# Main logic based on input flags
case "$1" in
    -p|--provision)
        provision_resources "$2"
        ;;
    -d|--delete)
        delete_resource "$2"
        ;;
    *)
        usage
        ;;
esac
