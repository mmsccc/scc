#!/bin/bash
# ===========================================
# MACIEJJANKOWSKI.COM DEPLOYMENT SCRIPT
# Secure deployment to production server
# ===========================================

set -e  # Exit on any error

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_ROOT/configs/deploy.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Warning: Configuration file not found at $CONFIG_FILE"
    echo "Using default settings..."
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" >> "$PROJECT_ROOT/$DEPLOYMENT_LOG"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] $1" >> "$PROJECT_ROOT/$DEPLOYMENT_LOG"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARNING] $1" >> "$PROJECT_ROOT/$DEPLOYMENT_LOG"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" >> "$PROJECT_ROOT/$DEPLOYMENT_LOG"
}

# Function to check if SSH connection works
check_ssh_connection() {
    log_info "Checking SSH connection to $REMOTE_HOST..."
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_USER@$REMOTE_HOST" "echo 'SSH connection successful'" >/dev/null 2>&1; then
        log_success "SSH connection established"
        return 0
    else
        log_error "SSH connection failed. Please check your SSH key or credentials."
        log_info "Make sure you have SSH access to $REMOTE_USER@$REMOTE_HOST"
        log_info "You may need to run: ssh-copy-id $REMOTE_USER@$REMOTE_HOST"
        return 1
    fi
}

# Function to build the site
build_site() {
    log_info "Building Jekyll site..."

    # Change to project root directory
    cd "$PROJECT_ROOT"

    # Set the Gemfile path
    export BUNDLE_GEMFILE="$PROJECT_ROOT/configs/Gemfile"

    # Build the site
    if bundle exec jekyll build --quiet; then
        log_success "Site built successfully"
        return 0
    else
        log_error "Site build failed"
        return 1
    fi
}

# Function to deploy via rsync over SSH
deploy_via_rsync() {
    log_info "Starting deployment via rsync over SSH..."

    # Count files for reporting
    FILE_COUNT=$(find "$LOCAL_BUILD_DIR" -type f | wc -l)
    DIR_COUNT=$(find "$LOCAL_BUILD_DIR" -type d | wc -l)
    TOTAL_SIZE=$(du -sh "$LOCAL_BUILD_DIR" | cut -f1)

    log_info "Deploying $FILE_COUNT files ($DIR_COUNT directories, $TOTAL_SIZE)..."

    # Create backup on remote server
    log_info "Creating backup on remote server..."
    if ssh "$REMOTE_USER@$REMOTE_HOST" "
        mkdir -p '$REMOTE_PATH/../backup' &&
        cd '$REMOTE_PATH' &&
        if [ -d . ] && [ \"\$(ls -A . 2>/dev/null)\" ]; then
            cp -r . '../backup/$(date +%Y%m%d-%H%M%S)-backup/' 2>/dev/null &&
            echo 'Backup created successfully'
        else
            echo 'Directory empty, skipping backup'
        fi
    " 2>/dev/null; then
        log_success "Backup created successfully"
    else
        log_warning "Could not create backup on remote server (continuing anyway)"
    fi

    # Upload files using rsync over SSH
    log_info "Uploading files to $REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH"

    # Build rsync command with options
    RSYNC_CMD="rsync -avz"
    RSYNC_CMD="$RSYNC_CMD --exclude=.git"
    RSYNC_CMD="$RSYNC_CMD --exclude=.DS_Store"
    RSYNC_CMD="$RSYNC_CMD --exclude=*.log"
    RSYNC_CMD="$RSYNC_CMD --exclude=*.tmp"
    RSYNC_CMD="$RSYNC_CMD --exclude=*.bak"
    RSYNC_CMD="$RSYNC_CMD --exclude=*.swp"
    RSYNC_CMD="$RSYNC_CMD --exclude=*.swo"
    RSYNC_CMD="$RSYNC_CMD --exclude=*.orig"
    RSYNC_CMD="$RSYNC_CMD --exclude=*.rej"
    RSYNC_CMD="$RSYNC_CMD --exclude=*~"
    RSYNC_CMD="$RSYNC_CMD --exclude=.sass-cache"
    RSYNC_CMD="$RSYNC_CMD --exclude=.jekyll-cache"
    RSYNC_CMD="$RSYNC_CMD --exclude=.obsidian"
    RSYNC_CMD="$RSYNC_CMD --exclude=.vscode"
    RSYNC_CMD="$RSYNC_CMD --exclude=.github"
    RSYNC_CMD="$RSYNC_CMD --exclude=Gemfile.lock"
    RSYNC_CMD="$RSYNC_CMD --exclude=.bundle"
    RSYNC_CMD="$RSYNC_CMD --exclude=vendor"
    RSYNC_CMD="$RSYNC_CMD --exclude=node_modules"
    RSYNC_CMD="$RSYNC_CMD --exclude=_docs"
    RSYNC_CMD="$RSYNC_CMD --exclude=_dont touch"
    RSYNC_CMD="$RSYNC_CMD --exclude=_experiments"
    RSYNC_CMD="$RSYNC_CMD --exclude=_to_review"
    RSYNC_CMD="$RSYNC_CMD --exclude=archives"
    RSYNC_CMD="$RSYNC_CMD --exclude=configs"
    RSYNC_CMD="$RSYNC_CMD --exclude=logs"
    RSYNC_CMD="$RSYNC_CMD --exclude=__old"
    RSYNC_CMD="$RSYNC_CMD --exclude=__meta"
    RSYNC_CMD="$RSYNC_CMD -e 'ssh -o ConnectTimeout=$SSH_TIMEOUT -o ServerAliveInterval=60 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'"

    # Debug: Show the command being executed
    log_info "Executing: $RSYNC_CMD \"$LOCAL_BUILD_DIR/\" \"$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/\""

    # Execute rsync with error handling
    set +e  # Temporarily disable exit on error
    RSYNC_OUTPUT=$(eval "$RSYNC_CMD \"$LOCAL_BUILD_DIR/\" \"$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/\" 2>&1")
    RSYNC_EXIT_CODE=$?
    set -e  # Re-enable exit on error

    # Check if rsync was successful or had acceptable errors
    if [ $RSYNC_EXIT_CODE -eq 0 ] || [ $RSYNC_EXIT_CODE -eq 23 ]; then
        # Exit code 0 = success, 23 = partial transfer but files were copied
        log_success "Files uploaded successfully (exit code: $RSYNC_EXIT_CODE)"

        # Verify at least some files were transferred
        if ssh "$REMOTE_USER@$REMOTE_HOST" "test -f /home/evil1/domains/structureclarityconfidence.com/public_html/index.html && test -s /home/evil1/domains/structureclarityconfidence.com/public_html/index.html && grep -q 'Structure, Clarity, Confidence' /home/evil1/domains/structureclarityconfidence.com/public_html/index.html"; then
            log_success "Key files verified on remote server"
        else
            log_error "Key files not found on remote server after transfer"
            return 1
        fi
    else
        log_error "Rsync failed with exit code: $RSYNC_EXIT_CODE"
        log_error "Rsync output: $RSYNC_OUTPUT"
        return 1
    fi
}

# Function to verify deployment
verify_deployment() {
    log_info "Verifying deployment..."

    # Use the expanded path directly
    REMOTE_PATH_EXPANDED="/home/evil1/domains/structureclarityconfidence.com/public_html"

    log_info "Checking path: $REMOTE_PATH_EXPANDED"

    # Check if key files exist on remote server
    if ssh "$REMOTE_USER@$REMOTE_HOST" "
        echo 'Checking files on remote server...'
        ls -la '$REMOTE_PATH_EXPANDED/' | head -3
        test -f '$REMOTE_PATH_EXPANDED/index.html' && echo 'index.html found' || echo 'index.html NOT found'
        test -s '$REMOTE_PATH_EXPANDED/index.html' && echo 'index.html has content' || echo 'index.html is empty'
        grep -q 'Structure, Clarity, Confidence' '$REMOTE_PATH_EXPANDED/index.html' && echo 'correct content found' || echo 'correct content NOT found'
        test -d '$REMOTE_PATH_EXPANDED/assets' && echo 'assets dir found' || echo 'assets dir NOT found'
        test -f '$REMOTE_PATH_EXPANDED/index.html' &&
        test -s '$REMOTE_PATH_EXPANDED/index.html' &&
        grep -q 'Strategic Consulting' '$REMOTE_PATH_EXPANDED/index.html'
    "; then
        log_success "Deployment verified - key files found on remote server"

        # Get file count on remote server
        REMOTE_FILE_COUNT=$(ssh "$REMOTE_USER@$REMOTE_HOST" "find '$REMOTE_PATH_EXPANDED' -type f | wc -l")
        REMOTE_SIZE=$(ssh "$REMOTE_USER@$REMOTE_HOST" "du -sh '$REMOTE_PATH_EXPANDED' | cut -f1")

        log_info "Remote server stats: $REMOTE_FILE_COUNT files, $REMOTE_SIZE"

        return 0
    else
        log_error "Deployment verification failed - key files not found"
        return 1
    fi
}

# Function to show deployment summary
show_summary() {
    echo
    echo "=========================================="
    echo "DEPLOYMENT SUMMARY"
    echo "=========================================="
    echo "Server: $REMOTE_HOST"
    echo "User: $REMOTE_USER"
    echo "Path: $REMOTE_PATH"
    echo "Local build: $LOCAL_BUILD_DIR"
    echo "Timestamp: $(date)"
    echo "=========================================="
}

# Function to rollback if needed
rollback() {
    log_warning "Starting rollback procedure..."

    # Find the latest backup
    LATEST_BACKUP=$(ssh "$REMOTE_USER@$REMOTE_HOST" "ls -td ~/domains/maciejjankowski.com/backup/*/ | head -1")

    if [ -n "$LATEST_BACKUP" ]; then
        log_info "Rolling back to backup: $LATEST_BACKUP"
        ssh "$REMOTE_USER@$REMOTE_HOST" "
            cd '$REMOTE_PATH'
            rm -rf *
            cp -r $LATEST_BACKUP* .
            echo 'Rollback completed'
        "
        log_success "Rollback completed successfully"
    else
        log_error "No backup found for rollback"
    fi
}

# Main deployment function
main() {
    echo "=========================================="
    echo "MACIEJJANKOWSKI.COM DEPLOYMENT SCRIPT"
    echo "=========================================="
    echo "Target: $REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH"
    echo "Local build dir: $LOCAL_BUILD_DIR"
    echo "=========================================="

    # Pre-deployment checks
    if ! check_ssh_connection; then
        log_error "SSH connection check failed. Please verify your SSH setup."
        exit 1
    fi

    # Build the site
    if ! build_site; then
        log_error "Site build failed. Please check for Jekyll errors."
        exit 1
    fi

    # Verify build directory exists
    if [ ! -d "$PROJECT_ROOT/$LOCAL_BUILD_DIR" ]; then
        log_error "Build directory $LOCAL_BUILD_DIR not found"
        exit 1
    fi

    # Deploy
    if ! deploy_via_rsync; then
        log_error "Deployment failed during file upload."
        echo
        echo "Troubleshooting tips:"
        echo "1. Check SSH connection: ssh $REMOTE_USER@$REMOTE_HOST"
        echo "2. Verify remote path exists: ssh $REMOTE_USER@$REMOTE_HOST 'ls -la $REMOTE_PATH'"
        echo "3. Check disk space: ssh $REMOTE_USER@$REMOTE_HOST 'df -h'"
        echo "4. Test rsync manually: rsync -avz --dry-run $PROJECT_ROOT/$LOCAL_BUILD_DIR/ $REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH"
        echo
        log_error "Deployment failed. Would you like to rollback? (y/N)"
        read -r response
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            rollback
        fi
        exit 1
    fi

    # Verify
    if ! verify_deployment; then
        log_error "Deployment verification failed."
        echo
        echo "Verification checks:"
        echo "1. Check if files exist: ssh $REMOTE_USER@$REMOTE_HOST 'ls -la $REMOTE_PATH'"
        echo "2. Test website: curl -I https://maciejjankowski.com"
        echo
        log_error "Deployment verification failed. Would you like to rollback? (y/N)"
        read -r response
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            rollback
        fi
        exit 1
    fi

    # Success
    show_summary
    log_success "🎉 Deployment completed successfully!"
    log_info "Your site is now live at: https://maciejjankowski.com"
    log_info "Don't forget to clear any CDN cache if you're using one."
}

# Handle command line arguments
case "${1:-}" in
    "--dry-run")
        log_info "DRY RUN MODE - Testing build and connection without uploading"
        check_ssh_connection
        build_site
        log_success "Dry run completed successfully"
        ;;
    "--rollback")
        log_info "ROLLBACK MODE - Rolling back to previous deployment"
        if check_ssh_connection; then
            rollback
        fi
        ;;
    "--verify")
        log_info "VERIFY MODE - Checking current deployment status"
        if check_ssh_connection; then
            verify_deployment
        fi
        ;;
    "--help"|"-h")
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --dry-run     Test build and connection without uploading"
        echo "  --rollback    Rollback to previous deployment"
        echo "  --verify      Check current deployment status"
        echo "  --help, -h    Show this help message"
        echo ""
        echo "Environment Variables:"
        echo "  SSH_KEY_PATH    Path to SSH private key (optional)"
        echo "  REMOTE_HOST     Remote server hostname (default: s3.mydevil.net)"
        echo "  REMOTE_USER     Remote username (default: evil1)"
        echo "  REMOTE_PATH     Remote path (default: ~/domains/maciejjankowski.com/public_html)"
        echo ""
        echo "Examples:"
        echo "  $0              # Full deployment"
        echo "  $0 --dry-run    # Test without uploading"
        echo "  $0 --verify     # Check deployment status"
        echo "  $0 --rollback   # Rollback to previous version"
        ;;
    *)
        main
        ;;
esac
