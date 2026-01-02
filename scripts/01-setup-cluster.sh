#!/bin/bash

# ============================================================================
# K3d DevOps Lab Cluster Setup Script
# ============================================================================
# This script provisions a k3d Kubernetes cluster with configurable options.
# All settings are loaded from config.env
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
if [ -f "${SCRIPT_DIR}/config.env" ]; then
    source "${SCRIPT_DIR}/config.env"
else
    echo "Error: config.env not found. Please create it from config.env.example"
    exit 1
fi

# Determine k3d binary
K3D_BIN="k3d"
if [ -f "${SCRIPT_DIR}/k3d" ]; then
    K3D_BIN="${SCRIPT_DIR}/k3d"
    echo_info "Using local k3d binary: ${K3D_BIN}"
fi

# ============================================================================
# Step 1: Check Prerequisites
# ============================================================================

check_prerequisites() {
    echo_info "Checking prerequisites..."

    # Check k3d
    if ! command -v "${K3D_BIN}" &> /dev/null && [ ! -f "${K3D_BIN}" ]; then
        echo_error "k3d is not installed."
        echo_info "To install k3d, run one of these commands:"
        echo ""
        echo "  # Using curl (recommended)"
        echo "  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"
        echo ""
        echo "  # Using wget"
        echo "  wget -q -O - https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"
        echo ""
        echo "  # Using Homebrew (macOS/Linux)"
        echo "  brew install k3d"
        echo ""
        exit 1
    else
        echo_info "k3d is installed: $(${K3D_BIN} version | head -1)"
    fi

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        echo_error "kubectl is not installed."
        echo_info "To install kubectl, run one of these commands:"
        echo ""
        echo "  # Linux (x86_64)"
        echo "  curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
        echo "  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl"
        echo ""
        echo "  # macOS (Intel)"
        echo "  curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl\""
        echo "  chmod +x ./kubectl && sudo mv ./kubectl /usr/local/bin/kubectl"
        echo ""
        echo "  # Using Homebrew (macOS/Linux)"
        echo "  brew install kubectl"
        echo ""
        exit 1
    else
        echo_info "kubectl is installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client | head -1)"
    fi

    # Check Docker
    if ! command -v docker &> /dev/null; then
        echo_error "Docker is not installed or not running. k3d requires Docker."
        exit 1
    else
        if ! docker info &> /dev/null; then
            echo_error "Docker is installed but not running. Please start Docker."
            exit 1
        fi
        echo_info "Docker is running"
    fi
}

# ============================================================================
# Step 2: Create K3d Cluster
# ============================================================================

create_cluster() {
    echo_info "Creating k3d cluster '${CLUSTER_NAME}'..."

    # Check if cluster already exists
    if ${K3D_BIN} cluster list | grep -q "${CLUSTER_NAME}"; then
        echo_warn "Cluster '${CLUSTER_NAME}' already exists."
        read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo_info "Deleting existing cluster..."
            ${K3D_BIN} cluster delete "${CLUSTER_NAME}"
        else
            echo_info "Keeping existing cluster. Skipping creation."
            return 0
        fi
    fi

    # Build k3d create command
    local k3d_cmd="${K3D_BIN} cluster create ${CLUSTER_NAME}"
    k3d_cmd+=" --servers ${SERVER_COUNT}"
    k3d_cmd+=" --agents ${AGENT_COUNT}"
    k3d_cmd+=" --port ${HTTP_PORT}:80@loadbalancer"
    k3d_cmd+=" --port ${HTTPS_PORT}:443@loadbalancer"
    k3d_cmd+=" --port ${TRAEFIK_DASHBOARD_PORT}:8080@loadbalancer"
    
    # Add image if specified
    if [ -n "${K3S_IMAGE}" ]; then
        k3d_cmd+=" --image ${K3S_IMAGE}"
    fi
    
    k3d_cmd+=" --wait"

    echo_info "Running: ${k3d_cmd}"
    eval "${k3d_cmd}"

    echo_info "Cluster '${CLUSTER_NAME}' created successfully!"
}

# ============================================================================
# Step 3: Configure Kubeconfig
# ============================================================================

configure_kubeconfig() {
    echo_info "Configuring kubeconfig..."

    ${K3D_BIN} kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-merge-default --kubeconfig-switch-context

    echo_info "Kubeconfig merged and context switched to k3d-${CLUSTER_NAME}"
}

# ============================================================================
# Step 4: Verify Cluster
# ============================================================================

verify_cluster() {
    echo_info "Verifying cluster connectivity..."

    local expected_nodes=$((SERVER_COUNT + AGENT_COUNT))
    local max_retries=30
    local retry=0

    echo_info "Waiting for all ${expected_nodes} nodes to be Ready..."

    while [ $retry -lt $max_retries ]; do
        ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo "0")
        if [ "$ready_nodes" -eq "$expected_nodes" ]; then
            break
        fi
        echo_info "Waiting for nodes... ($ready_nodes/${expected_nodes} ready)"
        sleep 5
        ((retry++))
    done

    if [ "$ready_nodes" -ne "$expected_nodes" ]; then
        echo_error "Not all nodes are ready after waiting. Please check cluster status."
        kubectl get nodes
        exit 1
    fi

    echo_info "All ${expected_nodes} nodes are Ready!"
    echo ""
    kubectl get nodes -o wide
    echo ""

    # Wait for Traefik CRD installation to complete
    echo_info "Waiting for Traefik CRD installation to complete..."
    local max_crd_wait=60
    local crd_wait=0
    while [ $crd_wait -lt $max_crd_wait ]; do
        if kubectl wait --for=condition=complete --timeout=5s job/helm-install-traefik-crd -n kube-system 2>/dev/null; then
            echo_info "Traefik CRDs installed successfully!"
            break
        fi
        ((crd_wait+=5))
        if [ $crd_wait -ge $max_crd_wait ]; then
            echo_warn "Traefik CRD installation timeout, but continuing..."
        fi
    done

    # Wait for Traefik deployment to be ready
    echo_info "Waiting for Traefik deployment to be ready..."
    kubectl wait --for=condition=available --timeout=180s deployment/traefik -n kube-system 2>/dev/null || {
        echo_warn "Traefik deployment not ready yet. Checking status..."
        kubectl get pods -n kube-system | grep traefik || true
    }

    # Verify IngressRoute CRD is available
    echo_info "Verifying Traefik IngressRoute CRD is available..."
    local max_ingressroute_wait=30
    local ingressroute_wait=0
    while [ $ingressroute_wait -lt $max_ingressroute_wait ]; do
        if kubectl get crd ingressroutes.traefik.io &>/dev/null; then
            echo_info "✓ IngressRoute CRD is ready!"
            break
        fi
        echo_info "Waiting for IngressRoute CRD..."
        sleep 2
        ((ingressroute_wait+=2))
        if [ $ingressroute_wait -ge $max_ingressroute_wait ]; then
            echo_error "IngressRoute CRD not found. Traefik may not be properly installed."
            exit 1
        fi
    done

    echo_info "Cluster components:"
    kubectl get pods -n kube-system
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo ""
    echo "============================================================"
    echo "  K3d DevOps Lab Cluster Setup"
    echo "============================================================"
    echo ""
    echo "Configuration:"
    echo "  Cluster Name:  ${CLUSTER_NAME}"
    echo "  Servers:       ${SERVER_COUNT}"
    echo "  Agents:        ${AGENT_COUNT}"
    echo "  HTTP Port:     ${HTTP_PORT}"
    echo "  HTTPS Port:    ${HTTPS_PORT}"
    echo ""

    check_prerequisites
    create_cluster
    configure_kubeconfig
    verify_cluster

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}Setup Complete!${NC}"
    echo "============================================================"
    echo ""
    echo "Cluster Name: ${CLUSTER_NAME}"
    echo "Nodes: ${SERVER_COUNT} server + ${AGENT_COUNT} agents = $((SERVER_COUNT + AGENT_COUNT)) total"
    echo ""
    echo "Port Mappings:"
    echo "  - localhost:${HTTP_PORT}   -> loadbalancer:80"
    echo "  - localhost:${HTTPS_PORT}  -> loadbalancer:443"
    echo "  - localhost:${TRAEFIK_DASHBOARD_PORT} -> loadbalancer:8080"
    echo ""
    echo "Next steps:"
    echo "  1. Verify Traefik: curl localhost (should return 404)"
    echo "  2. Run ./02-install-tools.sh to install ArgoCD and monitoring"
    echo "  3. Run ./03-deploy-app.sh to deploy the application"
    echo ""
}

main "$@"