#!/bin/bash

# ENV variables
KUBECONFIG_OLD="kubeconfig/old.yaml"
KUBECONFIG_NEW="kubeconfig/new.yaml"
NODE_PORT1=30797
NAME_SERVICE="beta-test-cache-del-me"
NAMESPACE_OLD="redis-test"
NAMESPACE_NEW="$NAMESPACE_OLD"
REGEX_REDIS_PASS="${NAME_SERVICE}-credentials"
PODS_TEMPLATE="rfr-${NAME_SERVICE}"
REGEX_PODS="${PODS_TEMPLATE}-[0-9]+"
PODS_SENTINEL_TEMPLATE="rfs-${NAME_SERVICE}"
REGEX_PODS_SENTINEL="${PODS_SENTINEL_TEMPLATE}-[0-9a-z]+-[0-9a-z]+"

# Log file
LOG_FILE="./migration.log"

# Colors for output (only for console)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Disable console output by default (set to 1 to enable)
CONSOLE_OUTPUT=0

# Function for logging (both to console and file)
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Remove color codes for file logging
    local clean_message=$(echo -e "$message" | sed -E 's/\x1B\[[0-9;]*[mGK]//g')
    # Log to file
    echo "[$timestamp] $clean_message" >> "$LOG_FILE"
    # Log to console with colors only if enabled
    if [[ $CONSOLE_OUTPUT -eq 1 ]]; then
        echo -e "$message"
    fi
}

log_info() {
    log "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    log "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    log "${RED}[ERROR]${NC} $1"
}

log_debug() {
    log "${BLUE}[DEBUG]${NC} $1"
}

# Function to log command errors with full output
log_command_error() {
    local command="$1"
    local output="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [COMMAND_ERROR] Command: $command" >> "$LOG_FILE"
    echo "[$timestamp] [COMMAND_ERROR] Output: $output" >> "$LOG_FILE"
    
    if [[ $CONSOLE_OUTPUT -eq 1 ]]; then
        log_error "Command failed: $command"
        log_debug "Error output: $output"
    fi
}

# Initialize log file
init_log() {
    echo "=== Redis Migration Log ===" > "$LOG_FILE"
    echo "Started at: $(date)" >> "$LOG_FILE"
    echo "Service: $NAME_SERVICE" >> "$LOG_FILE"
    echo "Old namespace: $NAMESPACE_OLD" >> "$LOG_FILE"
    echo "New namespace: $NAMESPACE_NEW" >> "$LOG_FILE"
    echo "Pod template: $PODS_TEMPLATE" >> "$LOG_FILE"
    echo "Sentinel template: $PODS_SENTINEL_TEMPLATE" >> "$LOG_FILE"
    echo "============================" >> "$LOG_FILE"
}

# Validation function
validate_env() {
    local missing_vars=()
    
    [[ -z "$KUBECONFIG_OLD" ]] && missing_vars+=("KUBECONFIG_OLD")
    [[ -z "$KUBECONFIG_NEW" ]] && missing_vars+=("KUBECONFIG_NEW")
    [[ -z "$NAME_SERVICE" ]] && missing_vars+=("NAME_SERVICE")
    [[ -z "$NAMESPACE_OLD" ]] && missing_vars+=("NAMESPACE_OLD")
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing_vars[*]}"
        exit 1
    fi
    
    if [[ ! -f "$KUBECONFIG_OLD" ]]; then
        log_error "KUBECONFIG_OLD file not found: $KUBECONFIG_OLD"
        exit 1
    fi
    
    if [[ ! -f "$KUBECONFIG_NEW" ]]; then
        log_error "KUBECONFIG_NEW file not found: $KUBECONFIG_NEW"
        exit 1
    fi
}

# Kubectl wrapper functions with error logging
kubectl_old() {
    local command_output
    command_output=$(KUBECONFIG="$KUBECONFIG_OLD" kubectl "$@" 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        log_command_error "kubectl_old $*" "$command_output"
    fi
    
    echo "$command_output"
    return $exit_code
}

kubectl_new() {
    local command_output
    command_output=$(KUBECONFIG="$KUBECONFIG_NEW" kubectl "$@" 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        log_command_error "kubectl_new $*" "$command_output"
    fi
    
    echo "$command_output"
    return $exit_code
}

# Function to get REDIS_PASSWORD from secret only
get_redis_password() {
    local namespace="$1"
    
    log_info "Getting REDIS_PASSWORD from secret in namespace: $namespace"
    
    # Try to get from secret
    local secret_password
    secret_password=$(kubectl_old --namespace="$namespace" get secret "$REGEX_REDIS_PASS" \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    
    if [[ -n "$secret_password" ]]; then
        log_info "Retrieved REDIS_PASSWORD from secret"
        echo "$secret_password"
    else
        log_error "Could not retrieve REDIS_PASSWORD from secret $REGEX_REDIS_PASS"
        exit 1
    fi
}

# Step 1: Find master pod in old cluster
find_master_pod() {
    log_info "Searching for master pod in old cluster..."
    
    local master_pod
    master_pod=$(kubectl_old --namespace="$NAMESPACE_OLD" get pods \
        -l "redisfailovers-role=master" \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | head -1)
    
    if [[ -z "$master_pod" ]]; then
        log_error "No running master pod found"
        exit 1
    fi
    
    log_info "Found master pod: $master_pod"
    echo "$master_pod"
}

# Step 2: Execute redis command in master pod
set_min_replicas() {
    local master_pod="$1"
    local redis_password="$2"
    
    log_info "Setting min-replicas-to-write in pod: $master_pod"
    
    local command_output
    command_output=$(kubectl_old --namespace="$NAMESPACE_OLD" exec "$master_pod" -- \
        redis-cli -a "$redis_password" config set min-replicas-to-write 10 2>&1)
    
    if [[ $? -eq 0 ]]; then
        log_info "Successfully set min-replicas-to-write to 10"
    else
        log_error "Failed to set min-replicas-to-write in pod $master_pod"
        log_command_error "redis-cli config set min-replicas-to-write 10" "$command_output"
        return 1
    fi
}

# Step 3: Get node IP
get_node_ip() {
    local master_pod="$1"
    log_info "Getting node IP for pod: $master_pod"
    
    local node_name
    node_name=$(kubectl_old --namespace="$NAMESPACE_OLD" get pod "$master_pod" \
        -o jsonpath='{.spec.nodeName}')
    
    if [[ -z "$node_name" ]]; then
        log_error "Failed to get node name for pod: $master_pod"
        return 1
    fi
    
    local node_ip
    node_ip=$(kubectl_old --namespace="$NAMESPACE_OLD" get node "$node_name" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    
    if [[ -z "$node_ip" ]]; then
        log_error "Failed to get node IP for node: $node_name"
        return 1
    fi
    
    log_info "Node IP: $node_ip"
    echo "$node_ip"
}

# Step 4: Deploy NodePort service
deploy_nodeport() {
    log_info "Deploying NodePort service on port: $NODE_PORT1"
    
    local command_output
    command_output=$(cat <<EOF | kubectl_old --namespace="$NAMESPACE_OLD" apply -f - 2>&1
apiVersion: v1
kind: Service
metadata:
  name: ${NAME_SERVICE}-migration
  namespace: $NAMESPACE_OLD
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: $NAME_SERVICE
    redisfailovers-role: master
  ports:
  - port: 6379
    targetPort: 6379
    nodePort: $NODE_PORT1
EOF
)
    
    if [[ $? -eq 0 ]]; then
        log_info "NodePort service deployed successfully"
    else
        log_error "Failed to deploy NodePort service"
        log_command_error "kubectl apply NodePort service" "$command_output"
        return 1
    fi
}

# Step 5: Migrate single RedisFailover CRD with bootstrap configuration (without saving files)
migrate_resources() {
    local redis_password="$1"
    local node_ip="$2"
    
    log_info "Migrating RedisFailover CRD with bootstrap configuration..."
    
    # Create namespace if it doesn't exist
    if ! kubectl_new get namespace "$NAMESPACE_NEW" &>/dev/null; then
        log_info "Creating namespace: $NAMESPACE_NEW"
        local namespace_output
        namespace_output=$(kubectl_new create namespace "$NAMESPACE_NEW" 2>&1)
        if [[ $? -ne 0 ]]; then
            log_warn "Failed to create namespace: $namespace_output"
        fi
    fi
    
    # Copy Secret (with check if it already exists)
    log_info "Copying Secret: $REGEX_REDIS_PASS"
    
    # Check if secret already exists in new cluster
    if kubectl_new --namespace="$NAMESPACE_NEW" get secret "$REGEX_REDIS_PASS" &>/dev/null; then
        log_info "Secret $REGEX_REDIS_PASS already exists in new cluster, skipping..."
    else
        local secret_output
        secret_output=$(kubectl_old --namespace="$NAMESPACE_OLD" get secret "$REGEX_REDIS_PASS" \
            -o yaml 2>&1 | kubectl_new --namespace="$NAMESPACE_NEW" apply -f - 2>&1)
        
        if [[ $? -eq 0 ]]; then
            log_info "Secret copied successfully"
        else
            log_error "Failed to copy Secret"
            log_command_error "kubectl copy secret" "$secret_output"
            return 1
        fi
    fi
    
    # Get RedisFailover CRD
    log_info "Searching for RedisFailover CRD with exact name: $NAME_SERVICE"
    
    local redis_failover_yaml
    
    # Try to get RedisFailover from old cluster
    if kubectl_old --namespace="$NAMESPACE_OLD" get redisfailover "$NAME_SERVICE" &>/dev/null; then
        # Namespaced CRD
        log_info "Found namespaced RedisFailover: $NAME_SERVICE"
        redis_failover_yaml=$(kubectl_old --namespace="$NAMESPACE_OLD" get redisfailover "$NAME_SERVICE" -o yaml 2>&1)
    elif kubectl_old get redisfailover "$NAME_SERVICE" &>/dev/null; then
        # Cluster-scoped CRD
        log_info "Found cluster-scoped RedisFailover: $NAME_SERVICE"
        redis_failover_yaml=$(kubectl_old get redisfailover "$NAME_SERVICE" -o yaml 2>&1)
    else
        log_error "RedisFailover CRD not found with name: $NAME_SERVICE"
        return 1
    fi
    
    # Create modified manifest with bootstrap configuration and apply directly
    log_info "Creating and applying modified RedisFailover with bootstrap configuration..."
    
    # Use yq or awk to modify the YAML and apply directly
    if command -v yq &> /dev/null; then
        # Using yq (version 4.x) - with quotes for port, apply directly
        local modified_yaml
        modified_yaml=$(echo "$redis_failover_yaml" | yq eval "
            .spec.bootstrapNode.allowSentinels = true |
            .spec.bootstrapNode.host = \"$node_ip\" |
            .spec.bootstrapNode.port = \"$NODE_PORT1\"
        " 2>&1)
        
        if [[ $? -eq 0 ]]; then
            log_info "Used yq for YAML modification"
            # Apply modified YAML directly
            local apply_output
            apply_output=$(echo "$modified_yaml" | kubectl_new --namespace="$NAMESPACE_NEW" apply -f - 2>&1)
            
            if [[ $? -eq 0 ]]; then
                log_info "Successfully migrated modified RedisFailover: $NAME_SERVICE"
            else
                log_error "Failed to migrate modified RedisFailover: $NAME_SERVICE"
                log_command_error "kubectl apply RedisFailover" "$apply_output"
                return 1
            fi
        else
            log_error "Failed to modify RedisFailover YAML with yq: $modified_yaml"
            return 1
        fi
    else
        # Fallback to awk if yq is not available - with quotes for port
        local modified_yaml
        modified_yaml=$(echo "$redis_failover_yaml" | awk -v node_ip="$node_ip" -v node_port="$NODE_PORT1" '
        /^spec:/ {
            print $0
            print "  bootstrapNode:"
            print "    allowSentinels: true"
            print "    host: " node_ip
            print "    port: \"" node_port "\""
            next
        }
        /^  bootstrapNode:/ {
            # Skip existing bootstrapNode section
            skip = 1
            next
        }
        /^  [a-zA-Z]/ && skip {
            skip = 0
        }
        !skip {
            print $0
        }
        ')
        
        log_info "Used awk for YAML modification"
        # Apply modified YAML directly
        local apply_output
        apply_output=$(echo "$modified_yaml" | kubectl_new --namespace="$NAMESPACE_NEW" apply -f - 2>&1)
        
        if [[ $? -eq 0 ]]; then
            log_info "Successfully migrated modified RedisFailover: $NAME_SERVICE"
        else
            log_error "Failed to migrate modified RedisFailover: $NAME_SERVICE"
            log_command_error "kubectl apply RedisFailover" "$apply_output"
            return 1
        fi
    fi
}

# Step 6: Configure replication in new cluster
configure_replication() {
    local node_ip="$1"
    local redis_password="$2"
    
    log_info "Configuring replication to $node_ip:$NODE_PORT1"
    
    # Wait for pods to be ready in new cluster
    log_info "Waiting for pods to be ready in new cluster..."
    local attempts=0
    local max_attempts=60
    
    while [[ $attempts -lt $max_attempts ]]; do
        local ready_pods
        ready_pods=$(kubectl_new --namespace="$NAMESPACE_NEW" get pods \
            -l "app.kubernetes.io/name=$NAME_SERVICE" --no-headers 2>/dev/null | grep "Running" | wc -l || echo "0")
        
        if [[ $ready_pods -gt 0 ]]; then
            log_info "Found $ready_pods running pod(s)"
            break
        fi
        
        attempts=$((attempts + 1))
        log_info "Waiting for pods... (attempt $attempts/$max_attempts)"
        sleep 5
    done
    
    # Get all pods matching the pattern
    local pods
    pods=$(kubectl_new --namespace="$NAMESPACE_NEW" get pods \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        tr ' ' '\n' | grep -E "$REGEX_PODS" || true)
    
    if [[ -z "$pods" ]]; then
        log_error "No pods found matching pattern: $REGEX_PODS"
        return 1
    fi
    
    log_info "Found pods to configure: $pods"
    
    for pod in $pods; do
        log_info "Configuring replication for pod: $pod -> $node_ip:$NODE_PORT1"
        
        # Execute slaveof command
        local slaveof_output
        slaveof_output=$(kubectl_new --namespace="$NAMESPACE_NEW" exec "$pod" -- \
            redis-cli -a "$redis_password" slaveof "$node_ip" "$NODE_PORT1" 2>&1)
        
        if [[ $? -eq 0 ]]; then
            log_info "Successfully configured replication for pod: $pod"
        else
            log_warn "Failed to configure replication for pod: $pod"
            log_command_error "redis-cli slaveof $node_ip $NODE_PORT1" "$slaveof_output"
        fi
    done
}

# Step 7: Monitor replication
monitor_replication() {
    local redis_password="$1"
    
    log_info "Monitoring replication progress..."
    
    local attempts=0
    local max_attempts=120
    
    while [[ $attempts -lt $max_attempts ]]; do
        local all_synced=true
        local pods
        pods=$(kubectl_new --namespace="$NAMESPACE_NEW" get pods \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
            tr ' ' '\n' | grep -E "$REGEX_PODS" || true)
        
        if [[ -z "$pods" ]]; then
            log_warn "No pods found for monitoring"
            sleep 10
            continue
        fi
        
        for pod in $pods; do
            # Get replication info
            local replication_info
            replication_info=$(kubectl_new --namespace="$NAMESPACE_NEW" exec "$pod" -- \
                redis-cli -a "$redis_password" info replication 2>&1)
            
            if [[ $? -ne 0 ]]; then
                log_warn "Failed to get replication info for pod: $pod"
                log_command_error "redis-cli info replication" "$replication_info"
                all_synced=false
                continue
            fi
            
            # Check sync status
            if echo "$replication_info" | grep -q "master_sync_in_progress:1"; then
                local sync_left=$(echo "$replication_info" | grep "master_sync_left_bytes" | cut -d: -f2 | tr -d '\r' || echo "unknown")
                log_info "Pod $pod still syncing... bytes left: $sync_left"
                all_synced=false
            elif echo "$replication_info" | grep -q "master_link_status:up"; then
                log_info "Pod $pod replication is up"
            else
                log_warn "Pod $pod replication status unknown or not connected"
                all_synced=false
            fi
        done
        
        if [[ "$all_synced" == true ]]; then
            log_info "All pods have completed replication"
            return 0
        fi
        
        attempts=$((attempts + 1))
        sleep 10
    done
    
    log_warn "Replication monitoring timeout reached after $max_attempts attempts"
    return 1
}

# Step 8: Promote PODS_TEMPLATE-0 to master
promote_to_master() {
    local redis_password="$1"
    
    log_info "Promoting ${PODS_TEMPLATE}-0 to master"
    
    local promote_output
    promote_output=$(kubectl_new --namespace="$NAMESPACE_NEW" exec "${PODS_TEMPLATE}-0" -- \
        redis-cli -a "$redis_password" slaveof NO ONE 2>&1)
    
    if [[ $? -eq 0 ]]; then
        log_info "Successfully promoted ${PODS_TEMPLATE}-0 to master"
    else
        log_error "Failed to promote ${PODS_TEMPLATE}-0 to master"
        log_command_error "redis-cli slaveof NO ONE" "$promote_output"
        return 1
    fi
}

# Step 9: Reconfigure other pods to replicate from PODS_TEMPLATE-0
reconfigure_replication() {
    local redis_password="$1"
    
    log_info "Reconfiguring other pods to replicate from ${PODS_TEMPLATE}-0"
    
    # Get pod IP for PODS_TEMPLATE-0
    local master_pod_ip
    master_pod_ip=$(kubectl_new --namespace="$NAMESPACE_NEW" get pod "${PODS_TEMPLATE}-0" \
        -o jsonpath='{.status.podIP}')
    
    if [[ -z "$master_pod_ip" ]]; then
        log_error "Failed to get IP for ${PODS_TEMPLATE}-0"
        return 1
    fi
    
    log_info "Master pod ${PODS_TEMPLATE}-0 IP: $master_pod_ip"
    
    # Get all pods except PODS_TEMPLATE-0
    local pods
    pods=$(kubectl_new --namespace="$NAMESPACE_NEW" get pods \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        tr ' ' '\n' | grep -E "$REGEX_PODS" | grep -v "${PODS_TEMPLATE}-0" || true)
    
    if [[ -n "$pods" ]]; then
        for pod in $pods; do
            log_info "Reconfiguring pod: $pod to replicate from ${PODS_TEMPLATE}-0 ($master_pod_ip)"
            
            local reconfigure_output
            reconfigure_output=$(kubectl_new --namespace="$NAMESPACE_NEW" exec "$pod" -- \
                redis-cli -a "$redis_password" slaveof "$master_pod_ip" 6379 2>&1)
            
            if [[ $? -eq 0 ]]; then
                log_info "Successfully reconfigured replication for pod: $pod"
            else
                log_warn "Failed to reconfigure replication for pod: $pod"
                log_command_error "redis-cli slaveof $master_pod_ip 6379" "$reconfigure_output"
            fi
        done
    else
        log_info "No other pods found to reconfigure"
    fi
}

# Step 10: Reconfigure sentinel pods
reconfigure_sentinel() {
    local redis_password="$1"
    
    log_info "Reconfiguring sentinel pods"
    
    local master_pod_ip
    master_pod_ip=$(kubectl_new --namespace="$NAMESPACE_NEW" get pod "${PODS_TEMPLATE}-0" \
        -o jsonpath='{.status.podIP}')
    
    if [[ -z "$master_pod_ip" ]]; then
        log_error "Failed to get IP for ${PODS_TEMPLATE}-0"
        return 1
    fi
    
    log_info "Using master pod IP for sentinel: $master_pod_ip"
    
    # Get all sentinel pods
    local sentinel_pods
    sentinel_pods=$(kubectl_new --namespace="$NAMESPACE_NEW" get pods \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        tr ' ' '\n' | grep -E "$REGEX_PODS_SENTINEL" || true)
    
    if [[ -z "$sentinel_pods" ]]; then
        log_info "No sentinel pods found matching pattern: $REGEX_PODS_SENTINEL"
        return 0
    fi
    
    log_info "Found sentinel pods: $sentinel_pods"
    
    for pod in $sentinel_pods; do
        log_info "Reconfiguring sentinel pod: $pod"
        
        # Remove old master configuration
        local remove_output
        remove_output=$(kubectl_new --namespace="$NAMESPACE_NEW" exec "$pod" -- \
            redis-cli -p 26379 -a "$redis_password" sentinel remove mymaster 2>&1)
        
        if [[ $? -ne 0 ]]; then
            log_debug "Failed to remove old master config (may not exist): $remove_output"
        fi
        
        # Monitor new master with port 26379 for sentinel
        local monitor_output
        monitor_output=$(kubectl_new --namespace="$NAMESPACE_NEW" exec "$pod" -- \
            redis-cli -p 26379 -a "$redis_password" sentinel monitor mymaster "$master_pod_ip" 6379 2 2>&1)
        
        if [[ $? -ne 0 ]]; then
            log_warn "Failed to configure sentinel monitor for pod: $pod"
            log_command_error "redis-cli -p 26379 sentinel monitor" "$monitor_output"
        fi

        # Added auth password for redis
        local monitor_auth_pass
        monitor_auth_pass=$(kubectl_new --namespace="$NAMESPACE_NEW" exec "$pod" -- \
            redis-cli -p 26379 -a "$redis_password" sentinel set mymaster auth-pass "$redis_password" 2>&1)
        
        if [[ $? -ne 0 ]]; then
            log_warn "Failed to set auth-pass for master in sentinel for pod: $pod"
            log_command_error "redis-cli -p 26379 sentinel set mymaster auth-pass $monitor_auth_pass"
        fi

    done
    
    log_info "Sentinel reconfiguration completed"
}

# Step 11: Wait for stabilization
wait_for_stabilization() {
    log_info "Waiting 60 seconds for cluster stabilization..."
    sleep 60
}

# Step 12: Verify final cluster state
verify_cluster_state() {
    local redis_password="$1"
    
    log_info "Verifying final cluster state..."
    
    # Check Redis pods
    log_info "Checking Redis pods..."
    local redis_pods
    redis_pods=$(kubectl_new --namespace="$NAMESPACE_NEW" get pods \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        tr ' ' '\n' | grep -E "$REGEX_PODS" || true)
    
    local master_count=0
    local slave_count=0
    
    for pod in $redis_pods; do
        local role_info
        role_info=$(kubectl_new --namespace="$NAMESPACE_NEW" exec "$pod" -- \
            redis-cli -a "$redis_password" info replication 2>&1 | grep "role:" | cut -d: -f2 | tr -d '\r' || echo "unknown")
        
        if [[ $? -ne 0 ]]; then
            log_warn "Failed to get role info for pod: $pod"
            continue
        fi
        
        if [[ "$role_info" == "master" ]]; then
            master_count=$((master_count + 1))
            log_info "Pod $pod is MASTER"
        elif [[ "$role_info" == "slave" ]]; then
            slave_count=$((slave_count + 1))
            log_info "Pod $pod is SLAVE"
        else
            log_warn "Pod $pod has unknown role: $role_info"
        fi
    done
    
    log_info "Cluster summary: $master_count master, $slave_count slaves"
    
    if [[ $master_count -ne 1 ]]; then
        log_warn "Expected exactly 1 master, found $master_count"
    else
        log_info "Master count verification PASSED"
    fi
}

# Step 13: Update RedisFailover manifest - get current from new cluster and remove bootstrapNode
update_redis_failover_manifest() {
    log_info "Updating RedisFailover manifest - removing bootstrapNode configuration..."
    
    # Get current RedisFailover from new cluster
    log_info "Getting current RedisFailover from new cluster..."
    
    local current_redis_failover_yaml
    
    if kubectl_new --namespace="$NAMESPACE_NEW" get redisfailover "$NAME_SERVICE" &>/dev/null; then
        # Namespaced CRD
        log_info "Found namespaced RedisFailover in new cluster: $NAME_SERVICE"
        current_redis_failover_yaml=$(kubectl_new --namespace="$NAMESPACE_NEW" get redisfailover "$NAME_SERVICE" -o yaml 2>&1)
    elif kubectl_new get redisfailover "$NAME_SERVICE" &>/dev/null; then
        # Cluster-scoped CRD
        log_info "Found cluster-scoped RedisFailover in new cluster: $NAME_SERVICE"
        current_redis_failover_yaml=$(kubectl_new get redisfailover "$NAME_SERVICE" -o yaml 2>&1)
    else
        log_error "RedisFailover CRD not found in new cluster with name: $NAME_SERVICE"
        return 1
    fi
    
    # Remove bootstrapNode configuration and apply directly
    log_info "Removing bootstrapNode configuration and applying final RedisFailover..."
    
    # Use yq or awk to remove bootstrapNode and apply directly
    if command -v yq &> /dev/null; then
        # Using yq to remove bootstrapNode
        local final_yaml
        final_yaml=$(echo "$current_redis_failover_yaml" | yq eval 'del(.spec.bootstrapNode)' 2>&1)
        
        if [[ $? -eq 0 ]]; then
            log_info "Used yq to remove bootstrapNode"
            # Apply final YAML directly
            local apply_output
            apply_output=$(echo "$final_yaml" | kubectl_new --namespace="$NAMESPACE_NEW" apply -f - 2>&1)
            
            if [[ $? -eq 0 ]]; then
                log_info "Successfully applied final RedisFailover manifest without bootstrap configuration"
            else
                log_error "Failed to apply final RedisFailover manifest"
                log_command_error "kubectl apply final RedisFailover" "$apply_output"
                return 1
            fi
        else
            log_error "Failed to remove bootstrapNode with yq: $final_yaml"
            return 1
        fi
    else
        # Fallback to awk to remove bootstrapNode section
        local final_yaml
        final_yaml=$(echo "$current_redis_failover_yaml" | awk '
        /^  bootstrapNode:/ {
            skip = 1
            next
        }
        /^  [a-zA-Z]/ && skip {
            skip = 0
        }
        !skip {
            print $0
        }
        ')
        
        log_info "Used awk to remove bootstrapNode"
        # Apply final YAML directly
        local apply_output
        apply_output=$(echo "$final_yaml" | kubectl_new --namespace="$NAMESPACE_NEW" apply -f - 2>&1)
        
        if [[ $? -eq 0 ]]; then
            log_info "Successfully applied final RedisFailover manifest without bootstrap configuration"
        else
            log_error "Failed to apply final RedisFailover manifest"
            log_command_error "kubectl apply final RedisFailover" "$apply_output"
            return 1
        fi
    fi
}

# Step 14: Final verification
final_verification() {
    local redis_password="$1"
    
    log_info "Performing final verification after manifest update..."
    
    # Wait a bit for the update to take effect
    sleep 30
    
    # Re-run the verification
    verify_cluster_state "$redis_password"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up NodePort service..."
    local cleanup_output
    cleanup_output=$(kubectl_old --namespace="$NAMESPACE_OLD" delete service "${NAME_SERVICE}-migration" 2>&1)
    
    if [[ $? -ne 0 ]]; then
        log_debug "NodePort cleanup had issues (may not exist): $cleanup_output"
    fi
}

# Main execution
main() {
    init_log
    log_info "Starting Redis migration process..."
    log_info "Service: $NAME_SERVICE"
    log_info "Old namespace: $NAMESPACE_OLD"
    log_info "New namespace: $NAMESPACE_NEW"
    log_info "Pod template: $PODS_TEMPLATE"
    log_info "Sentinel template: $PODS_SENTINEL_TEMPLATE"
    
    # Validate environment
    validate_env
    
    # Set trap for cleanup
    trap cleanup EXIT
    
    # Get REDIS_PASSWORD from secret only
    REDIS_PASSWORD=$(get_redis_password "$NAMESPACE_OLD")
    log_info "REDIS_PASSWORD retrieved successfully from secret"
    
    # Execute steps
    log_info "=== Step 1: Finding master pod ==="
    local master_pod=$(find_master_pod)
    
    log_info "=== Step 2: Setting min-replicas-to-write ==="
    if ! set_min_replicas "$master_pod" "$REDIS_PASSWORD"; then
        log_error "Step 2 failed"
        exit 1
    fi
    
    log_info "=== Step 3: Getting node IP ==="
    local node_ip=$(get_node_ip "$master_pod")
    if [[ $? -ne 0 ]]; then
        log_error "Step 3 failed"
        exit 1
    fi
    
    log_info "=== Step 4: Deploying NodePort ==="
    if ! deploy_nodeport; then
        log_error "Step 4 failed"
        exit 1
    fi
    
    log_info "=== Step 5: Migrating resources ==="
    if ! migrate_resources "$REDIS_PASSWORD" "$node_ip"; then
        log_error "Step 5 failed"
        exit 1
    fi
    
    log_info "=== Step 6: Configuring replication ==="
    if ! configure_replication "$node_ip" "$REDIS_PASSWORD"; then
        log_error "Step 6 failed"
        exit 1
    fi
    
    log_info "=== Step 7: Monitoring replication ==="
    if ! monitor_replication "$REDIS_PASSWORD"; then
        log_warn "Step 7 completed with warnings"
    fi
    
    log_info "=== Step 8: Promoting to master ==="
    if ! promote_to_master "$REDIS_PASSWORD"; then
        log_error "Step 8 failed"
        exit 1
    fi
    
    log_info "=== Step 9: Reconfiguring replication ==="
    if ! reconfigure_replication "$REDIS_PASSWORD"; then
        log_warn "Step 9 completed with warnings"
    fi
    
    log_info "=== Step 10: Reconfiguring sentinel ==="
    if ! reconfigure_sentinel "$REDIS_PASSWORD"; then
        log_warn "Step 10 completed with warnings"
    fi
    
    log_info "=== Step 11: Waiting for stabilization ==="
    wait_for_stabilization
    
    log_info "=== Step 12: Verifying cluster state ==="
    verify_cluster_state "$REDIS_PASSWORD"
    
    log_info "=== Step 13: Updating RedisFailover manifest ==="
    if ! update_redis_failover_manifest; then
        log_error "Step 13 failed"
        exit 1
    fi
    
    log_info "=== Step 14: Final verification ==="
    final_verification "$REDIS_PASSWORD"
    
    log_info "Redis migration completed successfully!"
    log_info "Log file: $LOG_FILE"
    
    # Show final message in console even if output is disabled
    if [[ $CONSOLE_OUTPUT -eq 0 ]]; then
        echo "Redis migration completed successfully! Check logs in: $LOG_FILE"
    fi
}

# Run main function
main "$@"