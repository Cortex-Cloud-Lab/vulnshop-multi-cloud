terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~>3.1"
    }
  }
}

provider "aws" {
  region = var.region
}

# Generate random suffix for resource names
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Data source for Amazon Linux 2 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "vulnshop-vpc-${random_string.suffix.result}"
    Environment = var.environment
    Project     = "VulnShop"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "vulnshop-igw-${random_string.suffix.result}"
    Environment = var.environment
    Project     = "VulnShop"
  }
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name        = "vulnshop-public-subnet-${random_string.suffix.result}"
    Environment = var.environment
    Project     = "VulnShop"
  }
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "vulnshop-public-rt-${random_string.suffix.result}"
    Environment = var.environment
    Project     = "VulnShop"
  }
}

# Route Table Association
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security Group for EC2
resource "aws_security_group" "ec2" {
  name_prefix = "vulnshop-ec2-${random_string.suffix.result}"
  vpc_id      = aws_vpc.main.id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Backend API
  ingress {
    from_port   = 3001
    to_port     = 3001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "vulnshop-ec2-sg-${random_string.suffix.result}"
    Environment = var.environment
    Project     = "VulnShop"
  }
}

# Key Pair
resource "aws_key_pair" "main" {
  key_name   = "vulnshop-key-${random_string.suffix.result}"
  public_key = var.ssh_public_key

  tags = {
    Name        = "vulnshop-key-${random_string.suffix.result}"
    Environment = var.environment
    Project     = "VulnShop"
  }
}

# IAM Role for EC2
resource "aws_iam_role" "ec2_role" {
  name = "vulnshop-ec2-role-${random_string.suffix.result}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "vulnshop-ec2-role-${random_string.suffix.result}"
    Environment = var.environment
    Project     = "VulnShop"
  }
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "vulnshop-ec2-profile-${random_string.suffix.result}"
  role = aws_iam_role.ec2_role.name
}

# EC2 Instance - Updated
resource "aws_instance" "main" {
  ami                     = data.aws_ami.amazon_linux.id
  instance_type           = var.instance_type
  key_name                = aws_key_pair.main.key_name
  vpc_security_group_ids  = [aws_security_group.ec2.id]
  subnet_id               = aws_subnet.public.id
  iam_instance_profile    = aws_iam_instance_profile.ec2_profile.name

  # --- ADDED SECTION START ---
  # This forces the instance to use gp3 instead of the AMI's default gp2
  root_block_device {
    volume_type = "gp3"
    volume_size = 32       # Optional: Set size (default for AL2 is 8GB)
    encrypted   = false    # Highly recommended to keep enabled
  }
  # --- ADDED SECTION END ---

  user_data = templatefile("${path.module}/user-data.sh", {
    git_repo   = var.git_repo
    git_branch = var.git_branch
  })

  tags = {
    Name        = "vulnshop-server-${random_string.suffix.result}"
    Environment = var.environment
    Project     = "VulnShop"
  }
}

# API Gateway
resource "aws_api_gateway_rest_api" "main" {
  name        = "vulnshop-api-${random_string.suffix.result}"
  description = "VulnShop API Gateway for educational security testing"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name        = "vulnshop-api-${random_string.suffix.result}"
    Environment = var.environment
    Project     = "VulnShop"
  }
}

# API Gateway Resource (proxy)
resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "{proxy+}"
}

# API Gateway Method for proxy
resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"

  # --- NEW BLOCK ---
  # This tells API Gateway "I expect a path parameter called 'proxy'"
  request_parameters = {
    "method.request.path.proxy" = true
  }
  # ----------------------
}

# API Gateway Method for root
resource "aws_api_gateway_method" "proxy_root" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_rest_api.main.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

# API Gateway Integration for proxy
resource "aws_api_gateway_integration" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_method.proxy.resource_id
  http_method = aws_api_gateway_method.proxy.http_method

  integration_http_method = "ANY"
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_instance.main.public_ip}:3001/{proxy}"

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

# API Gateway Integration for root
resource "aws_api_gateway_integration" "proxy_root" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_method.proxy_root.resource_id
  http_method = aws_api_gateway_method.proxy_root.http_method

  integration_http_method = "ANY"
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_instance.main.public_ip}:3001/"
}

# API Gateway CORS for proxy
resource "aws_api_gateway_method" "proxy_options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "proxy_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.proxy_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "proxy_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.proxy_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "proxy_options" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.proxy_options.http_method
  status_code = aws_api_gateway_method_response.proxy_options.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS,POST,PUT,DELETE'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

# API Gateway Deployment
resource "aws_api_gateway_deployment" "main" {
  depends_on = [
    aws_api_gateway_integration.proxy,
    aws_api_gateway_integration.proxy_root,
    aws_api_gateway_integration.proxy_options,
  ]

  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = var.environment

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.proxy.id,
      aws_api_gateway_method.proxy.id,
      aws_api_gateway_integration.proxy.id,
      aws_api_gateway_method.proxy_root.id,
      aws_api_gateway_integration.proxy_root.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# S3 Bucket for deployment assets
resource "aws_s3_bucket" "deployment" {
  bucket        = "vulnshop-deployment-${random_string.suffix.result}"
  force_destroy = true

  tags = {
    Name        = "vulnshop-deployment-${random_string.suffix.result}"
    Environment = var.environment
    Project     = "VulnShop"
  }
}

resource "aws_s3_bucket_public_access_block" "deployment" {
  bucket = aws_s3_bucket.deployment.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
} 
