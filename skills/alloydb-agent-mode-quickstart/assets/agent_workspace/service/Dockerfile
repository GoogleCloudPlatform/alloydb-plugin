# The router is a plain Python MCP server: it talks to the PostgreSQL sidecar
# directly (psycopg), one connection per call as the calling session's role.
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
ENV PORT=8080
CMD ["python", "server.py"]
