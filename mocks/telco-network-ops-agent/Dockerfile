# Lean image for the Pulse Telco Network Operations (NOC) A2A agent (python:3.12-slim + ADK).
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY agent.py .
ENV PYTHONUNBUFFERED=1
CMD ["python", "agent.py"]
