terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project    = "hermes"
      managed-by = "terraform"
      repo       = "iolalog/hermes-aws"
    }
  }
}

data "aws_caller_identity" "current" {}

# ── Networking (minimal public VPC) ───────────────────────────────────────────

resource "aws_vpc" "hermes" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = { Name = "hermes" }
}

resource "aws_subnet" "hermes" {
  vpc_id                  = aws_vpc.hermes.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = { Name = "hermes-public" }
}

resource "aws_internet_gateway" "hermes" {
  vpc_id = aws_vpc.hermes.id

  tags = { Name = "hermes-igw" }
}

resource "aws_route_table" "hermes" {
  vpc_id = aws_vpc.hermes.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hermes.id
  }

  tags = { Name = "hermes-rt" }
}

resource "aws_route_table_association" "hermes" {
  subnet_id      = aws_subnet.hermes.id
  route_table_id = aws_route_table.hermes.id
}

# ── Security group: no inbound, all outbound ──────────────────────────────────
# All connections are outbound (SSM, Slack Socket Mode, OpenRouter, Anthropic, GitHub)
# Port 22 intentionally absent — access via SSM Session Manager only

resource "aws_security_group" "hermes" {
  name        = "hermes-sg"
  description = "Hermes: no inbound, all outbound"
  vpc_id      = aws_vpc.hermes.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "hermes-sg" }
}

# ── AMI: latest Ubuntu 24.04 LTS arm64 (for t4g) ─────────────────────────────

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── EC2 instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "hermes" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t4g.small"
  subnet_id              = aws_subnet.hermes.id
  vpc_security_group_ids = [aws_security_group.hermes.id]
  iam_instance_profile   = aws_iam_instance_profile.hermes.name
  user_data              = templatefile("${path.module}/scripts/bootstrap.sh.tpl", { aws_region = var.aws_region })

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 16
    encrypted   = true
  }

  lifecycle {
    # Bootstrap changes and AMI upgrades require instance replacement or manual intervention.
    # Update user_data/ami in terraform.tfvars and taint the instance to force replacement.
    ignore_changes = [user_data, ami]
  }

  tags = { Name = "hermes" }
}

# ── Elastic IP ────────────────────────────────────────────────────────────────

resource "aws_eip" "hermes" {
  domain = "vpc"

  tags = { Name = "hermes-eip" }
}

resource "aws_eip_association" "hermes" {
  instance_id   = aws_instance.hermes.id
  allocation_id = aws_eip.hermes.id
}

# ── DLM: daily AMI snapshot, retain 7 days ───────────────────────────────────

resource "aws_dlm_lifecycle_policy" "hermes" {
  description        = "Daily AMI snapshot for hermes - retain 7"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    policy_type    = "IMAGE_MANAGEMENT"
    resource_types = ["INSTANCE"]

    schedule {
      name = "Daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["02:00"]
      }

      retain_rule {
        count = 7
      }

      copy_tags = true
    }

    target_tags = { Name = "hermes" }
  }
}
