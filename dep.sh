#!/bin/bash
set -euo pipefail
echo "Enter your Git repository URL "
read GIT_REPO_URL
echo "Enter your Personal Access Token:"
read -s GIT_PAT  
echo ""
echo "Enter branch name (press enter for 'main'):"
read GIT_BRANCH
GIT_BRANCH=${GIT_BRANCH:-main}
echo "Enter SSH username for the server:"
read SSH_USER
echo "Enter server IP address:"
read SERVER_IP

echo "Enter path to your SSH key (press enter for ~/.ssh/id_rsa):"
read SSH_KEY_PATH

SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
SSH_KEY_PATH=${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}
echo "Enter application port (default: 8080):"
read APP_PORT
APP_PORT=${APP_PORT:-8080}

PROJECT_NAME=$(basename "$GIT_REPO_URL" .git)

echo "Cloning repository..."
mkdir -p temp_deploy
cd temp_deploy

REPO_WITH_TOKEN=$(echo "$GIT_REPO_URL" | sed "s#https://#https://${GIT_PAT}@#")

if [ -d "$PROJECT_NAME" ]; then
    cd "$PROJECT_NAME"
    git pull origin "$GIT_BRANCH"
else
    git clone -b "$GIT_BRANCH" "$REPO_WITH_TOKEN" "$PROJECT_NAME"
    cd "$PROJECT_NAME"
fi

if [ -f "docker-compose.yml" ]; then
    DEPLOY_TYPE="compose"
elif [ -f "Dockerfile" ]; then
    DEPLOY_TYPE="docker"
else
    echo "Error: No Dockerfile or docker-compose.yml found"
    exit 1
fi

PROJECT_DIR=$(pwd)

echo "Setting up server..."
ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" << 'EOF'
    sudo apt-get update -qq
    
    # Install Docker
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        sudo usermod -aG docker $USER
        rm get-docker.sh
    fi
    
    # Install Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi
    
    # Install Nginx
    if ! command -v nginx &> /dev/null; then
        sudo apt-get install -y nginx
    fi
    
    sudo systemctl start docker
    sudo systemctl start nginx
EOF

echo "Deploying application..."
REMOTE_DIR="/home/${SSH_USER}/apps/${PROJECT_NAME}"

ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" "mkdir -p ${REMOTE_DIR}"

rsync -az -e "ssh -i ${SSH_KEY_PATH}" "$PROJECT_DIR/" "${SSH_USER}@${SERVER_IP}:${REMOTE_DIR}/"

ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" << EOF
    cd ${REMOTE_DIR}
    
    if [ "$DEPLOY_TYPE" = "compose" ]; then
        docker-compose down 2>/dev/null || true
        docker-compose up -d --build
    else
        docker stop ${PROJECT_NAME} 2>/dev/null || true
        docker rm ${PROJECT_NAME} 2>/dev/null || true
        docker build -t ${PROJECT_NAME}:latest .
        docker run -d --name ${PROJECT_NAME} --restart unless-stopped -p ${APP_PORT}:${APP_PORT} ${PROJECT_NAME}:latest
    fi
    
    sleep 3
EOF

echo "Configuring Nginx..."
ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" << EOF
    sudo tee /etc/nginx/sites-available/${PROJECT_NAME} > /dev/null << 'NGINX_EOF'
server {
    listen 80;
    server_name _;
    
    location / {
        proxy_pass http://localhost:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINX_EOF
    
    sudo ln -sf /etc/nginx/sites-available/${PROJECT_NAME} /etc/nginx/sites-enabled/${PROJECT_NAME}
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t && sudo systemctl reload nginx
EOF

cd ../..
rm -rf temp_deploy

echo ""
echo "Deployment complete!"
echo "Your application is live at: http://${SERVER_IP}"
echo ""