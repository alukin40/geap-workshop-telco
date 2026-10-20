# Lean image for the Pulse Telco IAM & User Context MCP server.
# Cold start matters for MCP servers: ADK opens a fresh MCP session per tool call and waits 5 s for it.
# python:3.12-slim + mcp/uvicorn starts in ~2 s on Cloud Run with startup CPU boost.
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
ENV PYTHONUNBUFFERED=1
CMD ["python", "server.py"]
