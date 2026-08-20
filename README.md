# Goal Tracker 3-Tier Architecture

This project deploys a scalable 3-tier web application (Frontend, Backend, Database) on AWS using Terraform. The infrastructure is containerized using Docker and deployed on EC2 Auto Scaling Groups with a Public ALB for frontend and Private ALB for backend.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Features](#features)
- [Technology Stack](#technology-stack)
- [Infrastructure Diagram](#infrastructure-diagram)
- [Deployment](#deployment)
- [Monitoring](#monitoring)
- [Security](#security)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## Architecture Overview

The solution follows a 3-tier architecture pattern with:

- **Tier 1: Presentation Layer** - Public subnets with ALB and EC2 Auto Scaling Group (Frontend)
- **Tier 2: Application Layer** - Private subnets with ALB and EC2 Auto Scaling Group (Backend)
- **Tier 3: Data Layer** - Private subnets with RDS PostgreSQL Multi-AZ (Database)

All infrastructure is managed using Terraform and deployed via CI/CD pipelines.

## Features

### 🟢 High Availability
- ✅ Multi-AZ deployments for frontend and backend
- ✅ RDS Multi-AZ with synchronous replication (optional)
- ✅ Cross-region replication for backups
- ✅ Health checks on all layers

### 🟢 Scalability
- ✅ Auto Scaling Groups with minimum/maximum/desired settings
- ✅ CPU-based scaling policies (70% threshold)
- ✅ Horizontal scaling for frontend and backend
- ✅ Read replicas (optional for PostgreSQL)

### 🟢 Security
- ✅ VPC with private and public subnets
- ✅ Security Groups controlling traffic between tiers
- ✅ RDS encryption at rest and in transit
- ✅ Secrets Manager for database credentials
- ✅ No public access to backend or database
- ✅ Bastion host for secure access

### 🟢 Monitoring
- ✅ CloudWatch metrics and alarms
- ✅ ELB health checks (request count, HTTP 5xx)
- ✅ RDS alarms (CPU, storage, replica lag)
- ✅ Centralized logging via CloudWatch Logs

### 🟢 CI/CD Integration
- ✅ Terraform modules for each tier
- ✅ Docker images stored in ECR
- ✅ Docker Hub integration for public images
- ✅ Secrets Manager for dynamic credentials

## Technology Stack

### 🎨 Frontend (Tier 1)
- **Framework**: React (not specified, but common for modern frontends)
- **Container**: Docker (Node.js-based)
- **Deployment**: EC2 Auto Scaling Group, Public ALB
- **Ports**: 3000 (container), 80 (ALB)

### ⚙️ Backend (Tier 2)
- **Runtime**: Node.js
- **Container**: Docker
- **Deployment**: EC2 Auto Scaling Group, Private ALB
- **Ports**: 8080 (container), 8080 (ALB)

### 🗄️ Database (Tier 3)
- **Engine**: PostgreSQL
- **Service**: RDS Multi-AZ
- **Instance**: db.t3.micro (default for dev)
- **Storage**: 20GB gp3
- **Port**: 5432

### 🛠️ Infrastructure
- **IaC**: Terraform
- **Container Registry**: ECR (for production), Docker Hub (for demo)
- **Secrets Management**: AWS Secrets Manager
- **Monitoring**: AWS CloudWatch
- **Networking**: VPC, Subnets, Route Tables, Security Groups, NAT Gateway

### 🛡️ Security Features
- **IAM Roles**: Instance profiles for EC2 instances
- **SSM**: Session Manager for secure access (no SSH keys)
- **Encryption**: RDS encryption, EBS encryption
- **Access Control**: Security Groups, NACLs

## Infrastructure Diagram

```mermaid
graph TD
    %% ==========================================================
    %% User and Internet
    %% ==========================================================
    User(["User / Internet"]) -->|HTTPS:80| ALB_Pub["Public ALB (Frontend)"];
    User -->|HTTPS:443| ALB_Pub;

    %% ==========================================================
    %% Public Subnet (Frontend Layer)
    %% ==========================================================
    subgraph "VPC (10.0.0.0/16)"
        subgraph "Public Subnet (AZ-a)"
            NAT_a["NAT Gateway (AZ-a)"];
            ASG_Frontend_a["ASG: Frontend (2-4 instances)"];
            ASG_Frontend_a --> ALB_Pub;
        end

        subgraph "Public Subnet (AZ-b)"
            NAT_b["NAT Gateway (AZ-b)"];
            ASG_Frontend_b["ASG: Frontend (2-4 instances)"];
            ASG_Frontend_b --> ALB_Pub;
        end
    end

    %% Internet Gateway Route
    IGW["Internet Gateway"];
    IGW -->|Egress| NAT_a;
    IGW -->|Egress| NAT_b;

    %% ==========================================================
    %% Private Subnet (Application Layer)
    %% ==========================================================
    subgraph "Private Subnet (AZ-a)"
        ASG_Backend_a["ASG: Backend (2-6 instances)"];
        ALB_Priv_a["Private ALB (Backend)"];
        ALB_Priv_a --> ASG_Backend_a;
    end

    subgraph "Private Subnet (AZ-b)"
        ASG_Backend_b["ASG: Backend (2-6 instances)"];
        ALB_Priv_b["Private ALB (Backend)"];
        ALB_Priv_b --> ASG_Backend_b;
    end

    %% Routing to Private Subnets
    NAT_a -->|Private| ALB_Priv_a;
    NAT_b -->|Private| ALB_Priv_b;

    %% ==========================================================
    %% Private Subnet (Data Layer)
    %% ==========================================================
    subgraph "Private Subnet (AZ-a)"
        RDS_a["RDS PostgreSQL (db.t3.micro)"];
    end

    subgraph "Private Subnet (AZ-b)"
        RDS_b["RDS PostgreSQL (db.t3.micro)"];
    end

    %% Routing to Data Subnets
    ASG_Backend_a -->|DB:5432| RDS_a;
    ASG_Backend_b -->|DB:5432| RDS_b;

    %% ==========================================================
    %%Bastion Host
    %% ==========================================================
    subgraph "Public Subnet (AZ-a)"
        BASTION["Bastion Host (t2.micro)"];
    end

    IGW -->|SSH:22| BASTION;
    
    %% ==========================================================
    %% Monitoring and Security
    %% ==========================================================
    subgraph "Monitoring & Security"
        CW["CloudWatch (Metrics, Alarms, Logs)"];
        ACM["AWS Certificate Manager"];
        SM["Secrets Manager"];
        ECR["Elastic Container Registry"];
    end

    ALB_Pub -.->|TLS Cert| ACM;
    ASG_Frontend_a -.->|Pull Image| ECR;
    ASG_Backend_a -.->|Pull Image| ECR;
    ASG_Backend_a -.->|DB Credentials| SM;
    ASG_Frontend_a -.->|DB Credentials| SM;
    RDS_a -.->|Backups| S3["S3: Terraform State & Logs"];
    BASTION -.->|Logs & Metrics| CW;
    ASG_Frontend_a -.->|Logs & Metrics| CW;
    ASG_Backend_a -.->|Logs & Metrics| CW;
    ALB_Pub -.->|Logs| CW;
    ALB_Priv_a -.->|Logs| CW;

    %% ==========================================================
    %% Styling
    %% ==========================================================
    classDef tier1 fill:#e1f5fe,stroke:#01579b,stroke-width:2px;
    classDef tier2 fill:#fff3e0,stroke:#e