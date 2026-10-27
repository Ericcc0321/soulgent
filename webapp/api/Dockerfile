# api container: the Python API server (standard library HTTP server + pywebpush).
FROM python:3.12-alpine
WORKDIR /app
# pywebpush and its dependencies all have ready wheels on musllinux (http-ece is a pure-Python source package), so no build tools are needed
COPY api/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY api/ /app/
RUN adduser -D -u 10001 app && mkdir -p /state && chown app /state
USER app
ENV SNAPSHOT=/data/snapshot.json \
    PROJECTS=/projects \
    STATE=/state/state.json
EXPOSE 8080
CMD ["python", "-u", "server.py"]
