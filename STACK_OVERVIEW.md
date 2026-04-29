# Navigator — Infrastructure Overview

## What Is This?

**Navigator** is an AI-powered resource-finder application, likely built to help people find shelter and social services. It is deployed entirely on AWS using **Infrastructure as Code (IaC)** via the **AWS CDK** (Cloud Development Kit) written in Python.

The entire infrastructure is defined in code — meaning you can recreate the whole cloud environment by running a single command.

---

## Big Picture: What Gets Deployed

Three AWS CloudFormation stacks, deployed **twice** (once for staging, once for production):

| Stack | Purpose |
|---|---|
| `Navigator-{Env}-Database` | PostgreSQL database in a private network |
| `Navigator-{Env}-Mcp` | AI embedding server + MCP (Model Context Protocol) server |
| `Navigator-{Env}-Agent` | Claude-powered chat API, exposed to the internet |

Total: **6 stacks** in AWS account `746669221991`, region `us-east-1`.

---

## Architecture: How the Pieces Connect

```
User (browser)
    │  HTTPS
    ▼
CloudFront CDN          ← terminates SSL/TLS
    │  HTTP
    ▼
Application Load Balancer (ALB)   ← internet-facing, port 80
    │
    ▼
shelter-chat-api  (ECS Fargate, port 3000)
    │  calls Claude Haiku via Anthropic API
    │  reads/writes PostgreSQL directly
    │  calls MCP server over private DNS
    ▼
MCP Server  (ECS Fargate, port 8001)
    │  registered at: mcp.navigator-{env}.internal
    │  reads PostgreSQL (pgvector table: service_snapshots)
    │
    ├──► Ollama sidecar  (same Fargate task, port 11434)
    │        runs nomic-embed-text embedding model
    │
    └──► RDS PostgreSQL 16  (private isolated subnet, port 5432)
             stores shelter/service data + vector embeddings
```

All communication between the Agent, MCP server, and database happens **inside the VPC** — it never touches the public internet.

---

## Stack 1: DatabaseStack

**File:** `shelter_infra/database_stack.py`

**What it creates:**
- A **VPC** (Virtual Private Cloud) — a private network on AWS
  - 2 availability zones
  - No NAT gateway (cost saving)
  - Public subnets (for services that need internet)
  - Private isolated subnets (for the database — no internet access at all)
- A **Security Group** that only allows PostgreSQL (port 5432) from within the VPC
- An **RDS PostgreSQL 16** database instance
  - Database name: `shelter`
  - Credentials auto-generated and stored in **AWS Secrets Manager**
  - Storage encrypted at rest
  - 7-day automated backups
- Two CloudFormation outputs: `DbEndpoint` (address to connect to) and `DbSecretArn` (where the credentials live)

**Staging vs Prod differences:**

| Setting | Staging | Production |
|---|---|---|
| Instance size | `t3.micro` | `t3.medium` |
| Deletion protection | Off | On |
| If stack is deleted | Database is destroyed | Database is retained |

**Why this matters:** Every other stack shares this VPC and database. The VPC is passed as a parameter into the MCP and Agent stacks — they all live in the same network.

---

## Stack 2: McpStack

**File:** `shelter_infra/mcp_stack.py`

**What it creates:**
- A **Private DNS Namespace**: `navigator-{env}.internal`
  - This allows services to find each other by name instead of IP address
- An **ECS Cluster** named `navigator-{env}`
- A **Fargate Task** with two containers running side-by-side:

### Container 1: Ollama (embedding model)
- Built from `docker/ollama/Dockerfile`
- Runs the `nomic-embed-text` model — a lightweight AI model that converts text into vectors (numbers)
- The model is pre-baked into the Docker image at build time so it starts fast
- Listens on port `11434`, only accessible within the task

### Container 2: MCP Server
- Built from the sibling repo `shelter-mcp-server`
- Listens on port `8001`
- Implements the **Model Context Protocol** — a standard way for AI agents to access external tools and data
- Connects to Ollama at `localhost:11434` to generate embeddings
- Connects to PostgreSQL (`service_snapshots` table) to do vector similarity search
- DB credentials injected securely from Secrets Manager at runtime
- **Depends on Ollama starting first** (container dependency)

**Service Discovery:** The MCP service registers itself in Cloud Map as `mcp.navigator-{env}.internal:8001`. The Agent stack uses this DNS name to call it — no hardcoded IPs.

**Auto-scaling:** Scales from 1 to 4 tasks when CPU or memory exceeds 70%.

---

## Stack 3: AgentStack

**File:** `shelter_infra/agent_stack.py`

**What it creates:**
- An **ECS Cluster** named `navigator-{env}-agent`
- A **Fargate Task** running the `shelter-chat-api` container:
  - 1 vCPU, 2 GB memory
  - Port 3000
  - Calls the Anthropic API using Claude Haiku for three roles:
    - **Classifier** — understands what kind of request the user is making
    - **Intake** — extracts structured information from user messages
    - **Formatter** — formats the final response back to the user
  - Calls MCP server at `http://mcp.navigator-{env}.internal:8001/mcp`
  - Reads/writes the PostgreSQL database directly
  - Auth via **Auth0** (`navigator-api` audience)
  - CORS allows `localhost:5173` (local dev) + the frontend CloudFront domain

- An **Application Load Balancer (ALB)**
  - Internet-facing on port 80
  - Health check hits `/health` endpoint on the container

- A **CloudFront Distribution**
  - Sits in front of the ALB
  - Redirects all HTTP to HTTPS (so users always get a secure connection)
  - Caching is **disabled** — every request goes through to the API
  - All HTTP methods allowed (GET, POST, PUT, DELETE, etc.)
  - Output: `AgentUrl` — the public HTTPS endpoint for the API

**Security Groups:**
- ALB SG: accepts traffic from anywhere on port 80
- Agent SG: only accepts traffic from the ALB on port 3000
- This means the Fargate container is never directly reachable from the internet

**Secrets injected at runtime from AWS Secrets Manager:**
- `ANTHROPIC_API_KEY` — stored as `navigator/{env}/anthropic-api-key` (must be pre-created manually)
- `DB_USER`, `DB_PASSWORD` — from the auto-generated RDS secret

**Auto-scaling:** Scales from 1 to 4 tasks at 70% CPU or memory.

---

## Docker: Ollama Container

**File:** `docker/ollama/Dockerfile`

```dockerfile
FROM ollama/ollama:latest
RUN ollama serve & sleep 15 && ollama pull nomic-embed-text && pkill ollama
EXPOSE 11434
ENTRYPOINT ["ollama", "serve"]
```

This is a 4-line Dockerfile that does something clever: during the **Docker build**, it starts Ollama, downloads the `nomic-embed-text` model, then shuts down. The model is baked into the image. When the container starts in production, the model is already there — no download delay.

---

## Operational Script: Database Restore

**File:** `scripts/restore_db.sh`

**Usage:** `./scripts/restore_db.sh staging` or `./scripts/restore_db.sh prod`

This script restores the database from an S3 backup. Here is exactly what it does:

1. **Reads CloudFormation outputs** to find the DB hostname and the secret ARN
2. **Fetches DB credentials** from Secrets Manager (username + password)
3. **Generates a presigned S3 URL** (valid 1 hour) for the backup file `shelter_tech_dump.sql` in bucket `navigator-db-backups-746669221991`
4. **Creates a temporary security group** and temporarily adds it to the DB's security group as an allowed source
5. **Creates a temporary IAM role** with ECS task execution permissions
6. **Spins up a temporary ECS Fargate task** using the `postgres:16-alpine` image that runs: `wget presigned_url | psql` — streams the backup directly into the database
7. **Waits for the task to complete**, checks the exit code
8. **Cleans up everything** — the temp security group, IAM role, ECS cluster, and task definition — whether the restore succeeded or failed (via `trap cleanup EXIT`)

The cleverness here: credentials are fetched outside the container and passed as environment variables, so the container doesn't need AWS credentials or the AWS CLI. The presigned URL handles S3 authentication.

---

## Deployment Model

```
app.py
  ├── Navigator-Staging-Database
  ├── Navigator-Staging-Mcp       (depends on Staging Database)
  ├── Navigator-Staging-Agent     (depends on Staging Mcp)
  ├── Navigator-Prod-Database
  ├── Navigator-Prod-Mcp          (depends on Prod Database)
  └── Navigator-Prod-Agent        (depends on Prod Mcp)
```

**Deploy all stacks:** `cdk deploy --all`  
**Deploy one stack:** `cdk deploy Navigator-Staging-Agent`

The VPC created in DatabaseStack is **shared** across all three stacks in the same environment. MCP and Agent both live in it.

---

## Key Technologies Summary

| Technology | Role | Why |
|---|---|---|
| **AWS CDK (Python)** | Infrastructure as Code | Define cloud resources in Python, not YAML/JSON |
| **ECS Fargate** | Run containers without managing servers | Serverless containers, auto-scaling |
| **RDS PostgreSQL 16** | Relational database + vector store | Stores shelter data; pgvector extension for semantic search |
| **Ollama** | Local embedding model server | Converts text to vectors for semantic search |
| **nomic-embed-text** | Embedding model | Lightweight, fast, runs on CPU |
| **MCP (Model Context Protocol)** | Standard AI tool interface | Lets the Claude agent call structured tools (search, lookup) |
| **Anthropic Claude Haiku** | LLM for classification, intake, formatting | Fast and cheap for high-throughput classification tasks |
| **AWS Secrets Manager** | Credential storage | Secrets never in code or environment files |
| **Cloud Map (private DNS)** | Service discovery | Services find each other by name, not IP |
| **Application Load Balancer** | HTTP routing + health checks | Routes traffic, enables zero-downtime deployments |
| **CloudFront** | CDN + HTTPS | Provides HTTPS without SSL certs on the ALB |
| **Auth0** | User authentication | JWT-based auth for the API |

---

## What a Request Looks Like End-to-End

1. User types a message in the frontend app (e.g., *"I need a shelter near downtown with pet-friendly options"*)
2. Request hits **CloudFront** over HTTPS → forwarded to **ALB** → routed to **shelter-chat-api**
3. The **Classifier** (Claude Haiku) identifies the intent: shelter search with filters
4. The **Intake** model (Claude Haiku) extracts structured fields: location, filters, constraints
5. The API calls the **MCP Server** with a structured tool call (e.g., `search_services`)
6. MCP Server uses **Ollama** to convert the query into a vector embedding
7. MCP Server runs a **pgvector similarity search** against `service_snapshots` in PostgreSQL
8. Results are returned to the API
9. The **Formatter** (Claude Haiku) shapes the results into a human-readable response
10. Response returned to the user

---

## Cost Considerations

- **No NAT gateway** — saves ~$32/month per environment (Fargate tasks get public IPs instead)
- **Staging uses t3.micro** — minimal DB cost for testing
- **Fargate scales to 1 at minimum** — no idle EC2 costs
- **CloudFront with caching disabled** — all requests hit the origin, so this is purely for HTTPS, not performance
