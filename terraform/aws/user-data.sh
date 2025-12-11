#!/bin/bash

# 1. Update system (Use dnf for AL2023)
dnf update -y

# 2. Install Node.js 18 and Tools
# AL2023 native repos have Node.js 18. We do NOT use NodeSource.
dnf install -y nodejs nginx git

# 3. Create directory and Clone repository
mkdir -p /var/www
cd /var/www
# Check if repo var is set, default to a dummy if testing manually
REPO_URL="${git_repo}"
[ -z "$REPO_URL" ] && echo "Git repo not provided" && exit 1

git clone "$REPO_URL" vulnshop
cd vulnshop
git checkout "${git_branch}"

# 4. Install dependencies (Run as root to avoid permission issues with nginx user)
# Backend
cd /var/www/vulnshop/backend
npm install

# Frontend
cd /var/www/vulnshop/frontend
npm install
# Note: On t3.micro, builds can sometimes fail due to memory. 
# If this happens, we might need to add swap, but we'll try standard build first.
npm run build

# 5. Fix Permissions
# Now that files are created/built, we give ownership to nginx
chown -R nginx:nginx /var/www/vulnshop

# 6. Configure Nginx
cat > /etc/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    server {
        listen 80;
        server_name _;
        
        # Serve frontend
        location / {
            root /var/www/vulnshop/frontend/dist;
            try_files $uri $uri/ /index.html;
        }
        
        # Proxy API requests to backend
        location /api/ {
            proxy_pass http://localhost:3001/api/;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_cache_bypass $http_upgrade;
        }
    }
}
EOF

# 7. Create systemd service for backend
cat > /etc/systemd/system/vulnshop-backend.service << 'EOF'
[Unit]
Description=VulnShop Backend
After=network.target

[Service]
Type=simple
User=nginx
WorkingDirectory=/var/www/vulnshop/backend
Environment=NODE_ENV=production
Environment=PORT=3001
# Path to node in AL2023 is standard
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 8. Start and enable services
systemctl daemon-reload
systemctl enable vulnshop-backend
systemctl start vulnshop-backend
systemctl enable nginx
systemctl start nginx

# 9. Create status page
# We create this AFTER build to ensure the dist directory exists
mkdir -p /var/www/vulnshop/frontend/dist
cat > /var/www/vulnshop/frontend/dist/status.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>VulnShop Status - AWS</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .status { padding: 20px; background: #f0f0f0; border-radius: 5px; margin: 10px 0; }
        .success { background: #d4edda; border: 1px solid #c3e6cb; color: #155724; }
        .info { background: #d1ecf1; border: 1px solid #bee5eb; color: #0c5460; }
    </style>
</head>
<body>
    <h1>VulnShop Deployment Status</h1>
    <div class="status success">
        <h3>✅ Application Deployed Successfully</h3>
        <p><strong>Platform:</strong> Amazon Web Services (AL2023)</p>
        <p><strong>Frontend:</strong> <a href="/">Available at root</a></p>
        <p><strong>Backend API:</strong> <a href="/api/products">Available at /api/</a></p>
    </div>
    
    <div class="status info">
        <h3>📋 Application Information</h3>
        <p><strong>Default Admin:</strong> admin / admin123</p>
        <p><strong>Default User:</strong> testuser / user123</p>
    </div>
    
    <div class="status info">
        <h3>☁️ AWS Specific</h3>
        <p><strong>OS:</strong> Amazon Linux 2023</p>
        <p><strong>Storage:</strong> gp3 Encrypted Volume</p>
    </div>
</body>
</html>
EOF

# ensure permissions are correct on the new status file
chown nginx:nginx /var/www/vulnshop/frontend/dist/status.html

# 10. Wait and test
sleep 30
curl -f http://localhost/status.html || echo "Warning: Frontend not responding"
curl -f http://localhost:3001/api/products || echo "Warning: Backend not responding"

# Log completion
echo "VulnShop deployment completed on AWS AL2023" >> /var/log/vulnshop-deployment.log
