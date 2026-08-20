# Architecture Overview

## 🏗️ System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Internet (0.0.0.0/0)                           │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │
                            ┌───────▼────────┐
                            │  Internet      │
                            │   Gateway      │
                            └───────┬────────┘
                                    │
┌───────────────────────────────────┼─────────────────────────────────────────┐
│  VPC: 10.0.0.0/16                 │                                         │
│                                   │                                         │
│  ┌────────────────────────────────▼──────────────────────────────────┐      │
│  │  PUBLIC SUBNETS (Web Tier)                                        │      │
│  │  10.0.1.0/24 (AZ-a) | 10.0.2.0/24 (AZ-b)                          │      │
│  ├───────────────────────────────────────────────────────────────────┤      │
│  │                                                                   │      │
│  │  ┌────────────────────┐      ┌──────────────────────────────────┐ │      │
│  │  │  Bastion Host(Opt) │      │  Application Load Balancer       │ │      │
│  │  │  EC2 (t2.micro)    │      │  (Internet-facing)               │ │      │
│  │  │  • SSH Access      │      │  • HTTP/HTTPS Listener           │ │      │
│  │  │  • Public IP       │      │  • Health Checks                 │ │      │
│  │  └────────────────────┘      │  • Target Group: Frontend:3000   │ │      │
│  │                              └────────────┬─────────────────────┘ │      │
│  │  ┌──────────────────┐           ┌─────────▼────────┐              │      │
│  │  │  NAT Gateway 1   │           │  NAT Gateway 2   │              │      │
│  │  │  (AZ-a)          │           │  (AZ-b)          │              │      │
│  │  │  • Elastic IP    │           │  • Elastic IP    │              │      │
│  │  └────────┬─────────┘           └────────┬─────────┘              │      │
│  └───────────┼────────────────────────┼──────────────────────────────┘      │
│              │                        │                                     │
│              │                        │                                     │
│  ┌───────────▼────────────────────────▼───────────────────────────┐         │
│  │  FRONTEND PRIVATE SUBNETS (App Tier - Frontend)                │         │
│  │  10.0.11.0/24 (AZ-a) | 10.0.12.0/24 (AZ-b)                     │         │
│  ├────────────────────────────────────────────────────────────────┤         │
│  │                                                                │         │
│  │  ┌──────────────────────────────────────────────────────┐      │         │
│  │  │  Frontend Auto Scaling Group                         │      │         │
│  │  │  • EC2 Instances: 2-4 (t3.micro)                     │      │         │
│  │  │  • Docker: Node.js Frontend (Port 3000)              │      │         │
│  │  │  • Target: ALB Target Group                          │      │         │
│  │  │  • Health Check: ELB                                 │      │         │
│  │  │  • Scaling Policy: CPU 70%                           │      │         │
│  │  │  • Communicates with: Backend API (Port 8080)        │      │         │
│  │  └─────────────────┬────────────────────────────────────┘      │         │
│  └────────────────────┼───────────────────────────────────────────┘         │
│                       │                                                     │
│                       │                                                     │
│  ┌────────────────────▼─────────────────────────────────────┐               │
│  │  BACKEND PRIVATE SUBNETS (App Tier - Backend)            |               │
│  │  10.0.21.0/24 (AZ-a) | 10.0.22.0/24 (AZ-b)               |               │
│  ├──────────────────────────────────────────────────────────┤               │
│  │                                                          │               │
│  │  ┌──────────────────────────────────────────────────┐    │               │
│  │  │  Backend Auto Scaling Group                      │    │               │
│  │  │  • EC2 Instances: 2-6 (t3.micro)                 │    │               │
│  │  │  • Docker: Go Backend API (Port 8080)            │    │               │
│  │  │  • Health Check: EC2                             │    │               │
│  │  │  • Scaling Policy: CPU 70%                       │    │               │
│  │  │  • Retrieves DB creds from Secrets Manager       │    │               │
│  │  │  • Connects to: PostgreSQL RDS (Port 5432)       │    │               │
│  │  └──────────────────┬───────────────────────────────┘    │               │
│  └─────────────────────┼────────────────────────────────────┘               │
│                        │                                                    │
│                        │                                                    │
│  ┌─────────────────────▼─────────────────────────────────┐                  │
│  │  DATABASE ISOLATED SUBNETS (Data Tier)                │                  │
│  │  10.0.31.0/24 (AZ-a) | 10.0.32.0/24 (AZ-b)            │                  │
│  ├───────────────────────────────────────────────────────┤                  │
│  │                                                       │                  │
│  │  ┌──────────────────────────────────────────────┐     │                  │
│  │  │  RDS PostgreSQL 15                           │     │                  │
│  │  │  • Instance: db.t3.micro                     │     │                  │
│  │  │  • Multi-AZ: Optional (Dev: Single)          │     │                  │
│  │  │  • Storage: 20GB gp3 (Encrypted)             │     │                  │
│  │  │  • Backup: 7 days retention                  │     │                  │
│  │  │  • Database: goalsdb                         │     │                  │
│  │  │  • No Internet Access                        │     │                  │
│  │  │  • Access: Backend SG only                   │     │                  │
│  │  └──────────────────────────────────────────────┘     │                  │
│  └───────────────────────────────────────────────────────┘                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  Supporting Services (Outside VPC)                              │
├─────────────────────────────────────────────────────────────────┤
│  • ECR: goal-tracker-frontend, goal-tracker-backend             │
│  • Secrets Manager: Database credentials                        │
│  • CloudWatch: Logs & Metrics                                   │
│  • IAM: EC2 instance roles (ECR, SSM, Secrets, CloudWatch)      │
└─────────────────────────────────────────────────────────────────┘
```

## 🔐 Security Groups & Network Flow

```
┌────────────┐       ┌────────────┐       ┌────────────┐       ┌───────────────┐
│ Internet   │────▶ │   ALB SG   │────▶ │ Frontend SG│────▶  │ Backend SG    │
│ (0.0.0.0/0)│       │  80, 443   │       │   3000     │       │   8080        │
└────────────┘       └────────────┘       └────────────┘       └───────────────┘

                                                                           │
                                                                           │
                                                                           ▼
                                                                  ┌────────────┐
                                                                  │   RDS SG   │
                                                                  │   5432     │
                                                                  └────────────┘

SSH Access Flow:
┌────────────┐     ┌────────────┐     ┌────────────┐
│ Your IP    │────▶│ Bastion SG │────▶│ Frontend/  │
│  (x.x.x.x) │     │     22     │     │ Backend SG │
└────────────┘     └────────────┘     │     22     │
                                      └────────────┘
```

## 📊 Data Flow

### Request Flow (User → Database)
```
1. User Request
   └─▶ Internet → ALB (port 80/443)
       
2. ALB to Frontend
   └─▶ ALB → Frontend ASG (port 3000)
       • Load balances across healthy instances
       • Health check: GET / every 30s
       
3. Frontend to Backend
   └─▶ Frontend → Backend ASG (port 8080)
       • Internal service discovery
       • API calls: GET/POST/DELETE /goals
       
4. Backend to Database
   └─▶ Backend → RDS PostgreSQL (port 5432)
       • Credentials from Secrets Manager
       • Connection pooling
       • SSL/TLS encrypted
```

### Response Flow (Database → User)
```
1. Database Query Result
   └─▶ PostgreSQL → Backend (Go API)
       
2. Backend Response
   └─▶ Backend → Frontend (JSON)
       
3. Frontend Rendering
   └─▶ Frontend → ALB (HTML/CSS/JS)
       
4. ALB to User
   └─▶ ALB → User Browser
```

## 🔄 Auto Scaling Behavior

### Frontend ASG
```
┌─────────────────────────────────────────────────────┐
│  Min: 2  │  Desired: 2  │  Max: 4                   │
├─────────────────────────────────────────────────────┤
│  Scaling Trigger: CPU > 70%                         │
│  Scale Out: +1 instance                             │
│  Scale In: -1 instance when CPU < 30%               │
│  Cooldown: 300 seconds                              │
└─────────────────────────────────────────────────────┘
```

### Backend ASG
```
┌─────────────────────────────────────────────────────┐
│  Min: 2  │  Desired: 2  │  Max: 6                   │
├─────────────────────────────────────────────────────┤
│  Scaling Trigger: CPU > 70%                         │
│  Scale Out: +1 instance                             │
│  Scale In: -1 instance when CPU < 30%               │
│  Cooldown: 300 seconds                              │
└─────────────────────────────────────────────────────┘
```

## 🔒 IAM Roles & Permissions

```
┌─────────────────────────────────────────────────────┐
│  EC2 Instance Role                                  │
├─────────────────────────────────────────────────────┤
│  • AmazonEC2ContainerRegistryReadOnly               │
│    └─▶ Pull Docker images from ECR                 │
│                                                     │
│  • AmazonSSMManagedInstanceCore                     │
│    └─▶ Session Manager access (no SSH keys)        │
│                                                     │
│  • CloudWatchAgentServerPolicy                      │
│    └─▶ Send logs and metrics to CloudWatch         │
│                                                     │
│  • Custom Secrets Manager Policy                    │
│    └─▶ Read database credentials                   │
└─────────────────────────────────────────────────────┘
```

## 📦 Container Deployment Flow

```
1. Build Phase (Local)
   └─▶ docker build -t frontend:latest .
       docker build -t backend:latest .

2. Push to ECR
   └─▶ docker push <account-id>.dkr.ecr.region.amazonaws.com/frontend:latest
       docker push <account-id>.dkr.ecr.region.amazonaws.com/backend:latest

3. Instance Launch (User Data)
   └─▶ EC2 starts → User data script runs
       │
       ├─▶ Install Docker & AWS CLI
       ├─▶ Login to ECR
       ├─▶ Pull image from ECR
       ├─▶ Get secrets (backend only)
       └─▶ Run container with environment variables

4. Health Checks
   └─▶ ALB health check → Frontend:3000/
       Container health check → Restart if unhealthy
```

## 💾 Database Architecture

```
┌─────────────────────────────────────────────────────┐
│  RDS PostgreSQL 15                                  │
├─────────────────────────────────────────────────────┤
│  Engine: postgres 15.5                              │
│  Instance: db.t3.micro                              │
│  Storage: 20GB gp3 (Encrypted)                      │
│  Multi-AZ: Optional (Dev: Disabled)                 │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │  Database: goalsdb                          │    │
│  │  ┌─────────────────────────────────────┐    │    │
│  │  │  Table: goals                       │    │    │
│  │  │  ├─ id: SERIAL PRIMARY KEY          │    │    │
│  │  │  └─ goal_name: VARCHAR(255) NOT NULL│    │    │
│  │  └─────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────┘    │
│                                                     │
│  Backups:                                           │
│  • Automated: Daily at 03:00 UTC                    │
│  • Retention: 7 days                                │
│  • Manual snapshots: Available                      │
│                                                     │
│  Monitoring:                                        │
│  • CloudWatch Logs: postgresql, upgrade             │
│  • Performance Insights: Optional                   │
│  • Enhanced Monitoring: Optional (60s)              │
└─────────────────────────────────────────────────────┘
```

## 🌐 DNS & Service Discovery

Currently using internal communication via private IPs within the same VPC.

For production, consider:
- **AWS Cloud Map**: Service discovery
- **Route53 Private Hosted Zone**: Internal DNS
- **Application Mesh**: Advanced service mesh

## 📈 Monitoring & Observability

```
┌─────────────────────────────────────────────────────┐
│  CloudWatch Logs                                    │
├─────────────────────────────────────────────────────┤
│  /aws/ec2/dev-goal-tracker/frontend                 │
│  /aws/ec2/dev-goal-tracker/backend                  │
│  /aws/rds/instance/dev-goal-tracker-postgres/       │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│  CloudWatch Metrics                                 │
├─────────────────────────────────────────────────────┤
│  • EC2: CPU, Memory, Disk, Network                  │
│  • ASG: Instance count, scaling activities          │
│  • ALB: Request count, latency, 4xx/5xx errors      │
│  • RDS: CPU, connections, read/write IOPS           │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│  CloudWatch Alarms                                  │
├─────────────────────────────────────────────────────┤
│  • Frontend/Backend High CPU (>80%)                 │
│  • Unhealthy ALB targets                            │
│  • RDS high CPU or low free storage                 │
│  • ASG scaling events                               │
└─────────────────────────────────────────────────────┘
```

## 🔐 Secrets Management

```
AWS Secrets Manager: dev-goal-tracker-db-credentials
┌─────────────────────────────────────────────────────┐
│  {                                                  │
│    "username": "postgres",                          │
│    "password": "<auto-generated-32-char>",          │
│    "engine": "postgres",                            │
│    "host": "dev-goal-tracker-postgres.xxx.rds...",  │
│    "port": 5432,                                    │
│    "dbname": "goalsdb"                              │
│  }                                                  │
└─────────────────────────────────────────────────────┘

Access Pattern:
Backend User Data → AWS CLI → Secrets Manager API → Parse JSON → Docker ENV
```

---

This architecture implements AWS Well-Architected Framework principles:
- ✅ **Operational Excellence**: Infrastructure as Code, automated deployments
- ✅ **Security**: Defense in depth, encryption, least privilege
- ✅ **Reliability**: Multi-AZ, auto-scaling, health checks
- ✅ **Performance Efficiency**: Right-sized instances, auto-scaling
- ✅ **Cost Optimization**: Single NAT (dev), auto-scaling, gp3 storage
